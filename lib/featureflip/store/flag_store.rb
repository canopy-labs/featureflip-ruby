module Featureflip
  module Store
    class FlagStore
      def initialize
        @flags = {}
        @segments = {}
        @mutex = Mutex.new
      end

      def init(flags, segments)
        @mutex.synchronize do
          @flags.clear
          @segments.clear
          flags.each { |f| @flags[f.key] = f }
          segments.each { |s| @segments[s.key] = s }
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
      def upsert(flag)
        @mutex.synchronize do
          existing = @flags[flag.key]
          return if existing && existing.version > flag.version
          @flags[flag.key] = flag
        end
      end

      def remove_flag(key)
        @mutex.synchronize { @flags.delete(key) }
      end
    end
  end
end
