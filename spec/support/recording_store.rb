require "timeout"

module SpecSupport
  # Records writes; can hold a put on a gate and fail on demand.
  class RecordingStore
    attr_reader :texts, :gets, :entries
    attr_accessor :value, :get_error, :put_error, :get_delay

    def initialize(value = nil)
      @value = value
      @texts = []
      @gets = 0
    @entries = 0
      @mutex = Mutex.new
      @gate = nil
      @entered = Queue.new
    end

    def hold_puts!
      @gate = Queue.new
    end

    def release_put
      @gate << :go
    end

    def wait_for_put_entry
      Timeout.timeout(3) { @entered.pop }
    end

    def get
      @mutex.synchronize { @gets += 1 }
      sleep(get_delay) if get_delay
      raise get_error if get_error

      @value
    end

    def put(text)
      @mutex.synchronize { @entries += 1 }
      @entered << :in
      @gate&.pop
      raise put_error if put_error

      @mutex.synchronize { @texts << text }
      @value = text
    end

    def count
      @mutex.synchronize { @texts.size }
    end
  end
end
