module Featureflip
  module Store
    class FlagStore
      def initialize
        @flags = {}
        @segments = {}
        @mutex = Mutex.new
        # The first snapshot establishes the baseline and reports nothing: a cold
        # start is not a change (the cross-SDK on_update contract).
        @has_snapshot = false
      end

      # Replace the store with a full snapshot (initial fetch, poll tick, SSE
      # `sync`, SSE segment refetch). Returns the changed flag keys, computed
      # under the same lock as the replace so a concurrent writer can never make
      # the reported change and the stored state disagree.
      def init(flags, segments)
        @mutex.synchronize do
          changed = @has_snapshot ? UpdateDiff.diff_snapshot(@flags, @segments, flags, segments) : []
          @flags = flags.to_h { |f| [f.key, f] }
          @segments = segments.to_h { |s| [s.key, s] }
          @has_snapshot = true
          changed
        end
      end

      def get_flag(key)
        @mutex.synchronize { @flags[key] }
      end

      def get_segment(key)
        @mutex.synchronize { @segments[key] }
      end

      def all_flags
        @mutex.synchronize { @flags.values }
      end

      def all_flags_map
        @mutex.synchronize { @flags.dup }
      end

      # Apply a single flag delta (SSE `flag.created` / `flag.updated`).
      #
      # Rejects only a *strictly older* config. Equal versions must be applied:
      # the wire version is second-granular, so two edits to one flag inside the
      # same wall-clock second carry an identical version, and treating equal as
      # stale discarded the second edit outright. With streaming on there is no
      # polling snapshot to correct it, so the store evaluated against the
      # pre-edit config until an SSE `sync` or reconnect.
      #
      # Re-applying an identical config is harmless; dropping a real one is not.
      #
      # Returns the changed keys: none when the delta is rejected or is an
      # identical redelivery (reconnects and duplicate events re-send the same
      # config, and reporting those would make on_update noisy).
      def upsert(flag)
        @mutex.synchronize do
          existing = @flags[flag.key]
          return [] if existing && existing.version > flag.version

          @flags[flag.key] = flag
          return [] if existing == flag

          with_prerequisite_dependents(flag.key)
        end
      end

      # Returns the deleted key plus its dependents, or [] if it was absent.
      def remove_flag(key)
        @mutex.synchronize do
          return [] if @flags.delete(key).nil?

          with_prerequisite_dependents(key)
        end
      end

      private

      # Caller holds @mutex. Reads the post-mutation store, so a deleted flag's
      # dependents, which still carry the dangling prerequisite row, are reached.
      def with_prerequisite_dependents(key)
        UpdateDiff.add_prerequisite_dependents(@flags.values, Set[key]).to_a.sort
      end
    end
  end
end
