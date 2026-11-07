require "digest"
require "json"
require "logger"
require "securerandom"

module Featureflip
  # Where the client's flag data came from at startup.
  #
  # source: Snapshot::SOURCE_LIVE ("live") after a successful fetch from the
  #   Evaluation API, Snapshot::SOURCE_SNAPSHOT ("snapshot") when started from the
  #   snapshot store, Snapshot::SOURCE_NONE ("none") when there is no data yet
  #   (caller defaults are served).
  # reason: "snapshot" for a snapshot start, "snapshot-expired" or
  #   "snapshot-invalid" when a stored snapshot was ignored. nil once the client is
  #   live, or when nothing was stored.
  # snapshot_age_seconds: age of the snapshot that was used or rejected as
  #   expired, in whole seconds.
  StartupInfo = Struct.new(:source, :reason, :snapshot_age_seconds) do
    def initialize(source, reason = nil, snapshot_age_seconds = nil)
      super
      freeze
    end
  end

  # Opaque text store for the last good flag snapshot (a duck type, not a base
  # class). Implement two methods:
  #
  #   get       -> the String last stored, or nil if nothing is stored
  #   put(text) -> store the String, replacing any previous value
  #
  # Both may be called from a background thread. A store that raises is handled: a
  # failing get is a miss and a failing put is a dropped write, each with a logged
  # warning. The SDK owns the stored text end to end (envelope, environment check,
  # age check and every startup reason), so one store instance may safely be given
  # to several SDK keys.
  #
  # Everything on Snapshot except the constants is internal (@api private): the
  # public surface is the store contract above, FileSnapshotStore, StartupInfo and
  # Config#snapshot_store.
  module Snapshot
    # StartupInfo#source values.
    SOURCE_LIVE = "live".freeze
    SOURCE_SNAPSHOT = "snapshot".freeze
    SOURCE_NONE = "none".freeze

    # StartupInfo#reason values.
    REASON_SNAPSHOT = "snapshot".freeze
    REASON_EXPIRED = "snapshot-expired".freeze
    REASON_INVALID = "snapshot-invalid".freeze

    # How far in the future a stored fetchedAt may be (clock skew between the writer
    # and the reader) and still be accepted, with its age clamped to 0.
    FUTURE_FETCHED_AT_TOLERANCE_MS = 60_000

    # While live, an unchanged state is rewritten (refreshing fetchedAt) at most
    # this often. Changed content is never throttled.
    REFRESH_INTERVAL_SECONDS = 300.0

    # Stored text failed a check. +why+ names the check, never the contents or key.
    class InvalidError < StandardError
      attr_reader :why

      def initialize(why)
        super(why)
        @why = why
      end
    end

    Decoded = Struct.new(:flags, :segments, :fetched_at_ms, keyword_init: true)

    NullConfig = Struct.new(:logger, :base_url)
    private_constant :NullConfig

    # Identify the (base URL, SDK key) pair without storing the key.
    def self.compute_key_hash(base_url, sdk_key)
      Digest::SHA256.hexdigest("#{base_url.to_s.sub(%r{/+\z}, "")}\n#{sdk_key}")
    end

    # The stored text, from an already serialized +data+.
    def self.encode_envelope(key_hash, fetched_at_ms, data_text)
      "{\"v\":1,\"keyHash\":#{JSON.generate(key_hash)},\"fetchedAt\":#{Integer(fetched_at_ms)},\"data\":#{data_text}}"
    end

    # Parse and check stored text. Age is not checked here.
    # Raises InvalidError for any failed check, in the pinned order.
    def self.decode_envelope(text, key_hash, now_ms)
      raise InvalidError, "store returned a non-string value" unless text.is_a?(String)

      begin
        env = JSON.parse(text)
      rescue StandardError
        raise InvalidError, text.empty? ? "empty text" : "not valid JSON"
      end
      raise InvalidError, "not a snapshot envelope" unless env.is_a?(Hash)

      version = env["v"]
      unless version.is_a?(Numeric) && version == 1
        raise InvalidError, "unsupported envelope version"
      end
      raise InvalidError, "written for a different SDK key or base URL" unless env["keyHash"] == key_hash

      fetched_at = positive_integer(env["fetchedAt"])
      raise InvalidError, "fetchedAt is not a positive integer" if fetched_at.nil?
      raise InvalidError, "fetchedAt is in the future" if fetched_at > now_ms + FUTURE_FETCHED_AT_TOLERANCE_MS

      data = env["data"]
      raise InvalidError, "missing data" unless data.is_a?(Hash)

      begin
        raise ArgumentError, "flags and segments must be arrays" unless data["flags"].is_a?(Array) && data["segments"].is_a?(Array)

        flags, segments = payload_parser.parse_flags_response(data)
      rescue StandardError
        raise InvalidError, "data failed payload validation"
      end
      Decoded.new(flags: flags, segments: segments, fetched_at_ms: fetched_at)
    end

    def self.positive_integer(value)
      case value
      when Integer then value.positive? ? value : nil
      when Float then value.finite? && value == value.floor && value.positive? ? value.to_i : nil
      end
    end

    # The SDK's own live-payload parser (so the same wholesale-discard validation
    # and unevaluable-entity drops apply), with logging off.
    def self.payload_parser
      Http::Client.new(nil, NullConfig.new(nil, ""))
    end

    # --- Serialization (in-memory state back to the /v1/sdk/flags wire shape) ---
    #
    # The models hold the wire spelling already (Boolean/Fixed/Rollout, And/Or, ...;
    # an unknown value is kept verbatim), so this only renames fields. Flags and
    # segments are sorted by key and the property order is fixed: the unchanged-state
    # comparison relies on a deterministic text.

    def self.serialize_flags_payload(flags, segments)
      JSON.generate(
        "flags" => flags.sort_by { |f| f.key.to_s }.map { |f| wire_flag(f) },
        "segments" => segments.sort_by { |s| s.key.to_s }.map { |s| wire_segment(s) }
      )
    end

    def self.wire_condition(c)
      { "attribute" => c.attribute, "operator" => c.operator, "values" => c.values, "negate" => c.negate }
    end

    def self.wire_group(g)
      { "operator" => g.operator, "conditions" => g.conditions.map { |c| wire_condition(c) } }
    end

    def self.wire_serve(s)
      out = { "type" => s.type }
      out["variation"] = s.variation unless s.variation.nil?
      out["bucketBy"] = s.bucket_by unless s.bucket_by.nil?
      out["salt"] = s.salt unless s.salt.nil?
      unless s.variations.nil?
        out["variations"] = s.variations.map { |v| { "key" => v.key, "weight" => v.weight } }
      end
      out
    end

    def self.wire_rule(r)
      out = {
        "id" => r.id,
        "priority" => r.priority,
        "conditionGroups" => r.condition_groups.map { |g| wire_group(g) },
        "serve" => wire_serve(r.serve)
      }
      out["segmentKey"] = r.segment_key unless r.segment_key.nil?
      out
    end

    def self.wire_flag(f)
      {
        "key" => f.key,
        "version" => f.version,
        "type" => f.type,
        "enabled" => f.enabled,
        "variations" => f.variations.map { |v| { "key" => v.key, "value" => v.value } },
        "rules" => f.rules.map { |r| wire_rule(r) },
        "fallthrough" => wire_serve(f.fallthrough),
        "offVariation" => f.off_variation,
        "prerequisites" => f.prerequisites.map do |p|
          { "prerequisiteFlagKey" => p.prerequisite_flag_key, "expectedVariationKey" => p.expected_variation_key }
        end
      }
    end

    def self.wire_segment(s)
      {
        "key" => s.key,
        "version" => s.version,
        "conditions" => s.conditions.map { |c| wire_condition(c) },
        "conditionLogic" => s.condition_logic
      }
    end

    private_class_method :positive_integer, :payload_parser, :wire_condition, :wire_group,
                         :wire_serve, :wire_rule, :wire_flag, :wire_segment
  end

  # Persist the snapshot text to one file (mode 0600), written atomically.
  #
  # The store is opaque: it neither parses nor checks what it holds, so one instance
  # can be shared by several SDK keys. It never raises: a failure is logged and
  # treated as a miss (get) or a dropped write (put). The parent directory must
  # already exist; it is never created.
  #
  # There is deliberately no fsync before the rename, so a power loss can leave a
  # zero-length or partial file. The SDK reads that as "snapshot-invalid", logs a
  # warning and serves defaults, and the next successful write replaces it.
  #
  # A write runs on a background thread, so a process killed mid-write can leave a
  # "<name>.<pid>.<hex>.tmp" file next to the snapshot. It is never read.
  #
  # Owner-only permissions are POSIX semantics; on Windows the file mode bits are
  # not enforced and the file inherits the directory's access control list.
  class FileSnapshotStore
    def initialize(path, logger: nil)
      @path = path.to_s
      @logger = logger || ::Logger.new($stderr, level: ::Logger::WARN)
    end

    def get
      File.binread(@path).force_encoding(Encoding::UTF_8).scrub
    rescue Errno::ENOENT
      nil
    rescue StandardError => e
      @logger.warn("Featureflip: snapshot file read failed (#{@path}): #{e.class}: #{e.message}")
      nil
    end

    def put(text)
      tmp = "#{@path}.#{Process.pid}.#{SecureRandom.hex(6)}.tmp"
      begin
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
          f.binmode
          f.write(text.to_s.encode(Encoding::UTF_8))
          f.flush
        end
        File.rename(tmp, @path)
      rescue StandardError => e
        @logger.warn("Featureflip: snapshot file write failed (#{@path}): #{e.class}: #{e.message}")
        begin
          File.unlink(tmp)
        rescue StandardError
          # nothing left to clean up
        end
      end
      nil
    end
  end
end
