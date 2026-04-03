module Featureflip
  module Models
    Segment = Struct.new(:key, :version, :conditions, :condition_logic, keyword_init: true)
  end
end
