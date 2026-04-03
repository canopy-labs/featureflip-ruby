require "digest/md5"

module Featureflip
  module Evaluation
    module Bucketing
      def self.compute_bucket(salt, value)
        input = "#{salt}:#{value}"
        hash_bytes = Digest::MD5.digest(input)
        hash_int = hash_bytes[0, 4].unpack1("V")
        hash_int % 100
      end
    end
  end
end
