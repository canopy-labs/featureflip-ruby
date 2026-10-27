require "spec_helper"

RSpec.describe Featureflip::Evaluation::CanonicalNumber do
  {
    1.0 => "1", 1.5 => "1.5", 0.1 => "0.1", 0.30000000000000004 => "0.30000000000000004",
    -0.0 => "0", 0.0 => "0", 100.25 => "100.25", 1e21 => "1e+21", 1.5e21 => "1.5e+21",
    1e20 => "100000000000000000000", 1e-7 => "1e-7", 0.000001 => "0.000001",
    2.5e-7 => "2.5e-7", 123456.789 => "123456.789", -1.5 => "-1.5", -1e-7 => "-1e-7",
    100.0 => "100", Float::NAN => "NaN", Float::INFINITY => "Infinity",
    -Float::INFINITY => "-Infinity", 5e-324 => "5e-324",
    1.7976931348623157e308 => "1.7976931348623157e+308",
    # Shortest digits, not the first %.{p}e that round-trips (#4236).
    2.0**-44 => "5.684341886080802e-14", 2.0**-25 => "2.9802322387695312e-8",
    1234.5e-10 => "1.2345e-7", 123456789012345680000.0 => "123456789012345680000"
  }.each do |input, expected|
    it "spells #{input.inspect} as #{expected}" do
      expect(described_class.format(input)).to eq(expected)
    end
  end

  describe ".format_big_decimal" do
    require "bigdecimal"
    {
      "1.0" => "1", "100" => "100", "1E+2" => "100", "-0" => "0", "-5.00" => "-5",
      "12345678901234567890" => "12345678901234567890",
      # Exact digits stop below 1e21; at and above it the value goes through Float (#4246),
      # so a tiny BigDecimal with a huge exponent never expands to its full digit string.
      "999999999999999999999" => "999999999999999999999",
      "-999999999999999999999" => "-999999999999999999999",
      "1E+21" => "1e+21", "-1E+21" => "-1e+21", "1000000000000000000000" => "1e+21",
      "1E+30" => "1e+30", "1E+400" => "Infinity", "-1E+100000" => "-Infinity",
      "1.5" => "1.5", "0.1" => "0.1", "1E-7" => "1e-7",
      "NaN" => "NaN", "Infinity" => "Infinity", "-Infinity" => "-Infinity"
    }.each do |input, expected|
      it "spells BigDecimal(#{input}) as #{expected}" do
        expect(described_class.format_big_decimal(BigDecimal(input))).to eq(expected)
      end
    end
  end
end
