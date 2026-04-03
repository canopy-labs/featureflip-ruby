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

      def upsert(flag)
        @mutex.synchronize do
          existing = @flags[flag.key]
          return if existing && existing.version >= flag.version
          @flags[flag.key] = flag
        end
      end

      def remove_flag(key)
        @mutex.synchronize { @flags.delete(key) }
      end
    end
  end
end
