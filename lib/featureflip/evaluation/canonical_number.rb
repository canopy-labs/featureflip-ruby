module Featureflip
  module Evaluation
    # Canonical spelling of a floating-point rollout bucket value (#4236): the same
    # text as ECMAScript Number::toString and the Evaluation API's
    # BucketValueFormatter.CanonicalNumber, so every SDK hashes one number to one
    # bucket. Used only on the bucket path; condition evaluation is unaffected.
    module CanonicalNumber
      # A BigDecimal with no fractional part keeps its exact integer digits (like the
      # engine's raw integer text); anything else goes through Float (#4236).
      def self.format_big_decimal(d)
        return format(d.to_f) unless d.finite?
        return d.to_i.to_s if d.frac.zero?

        format(d.to_f)
      end

      def self.format(x)
        return "NaN" if x.nan?
        return (x.positive? ? "Infinity" : "-Infinity") if x.infinite?
        return "0" if x.zero?
        return "-" + format(-x) if x.negative?

        # Float#to_s is the shortest round-trip form (e.g. "0.1", "100.25", "1.0e+21").
        # Kernel.format("%.{p}e", ...) with the first round-tripping p is NOT always
        # shortest: for 2**-44 the nearest 16-digit decimal does not round-trip but a
        # neighbour does, so the loop yields 17 digits where ECMAScript yields 16.
        mantissa, exp10 = x.to_s.split("e")
        int_part, frac_part = mantissa.split(".")
        frac_part ||= ""
        all_digits = int_part + frac_part
        lead = all_digits.length - all_digits.sub(/\A0+/, "").length
        lead = all_digits.length - 1 if lead >= all_digits.length
        exp = exp10.to_i + int_part.length - 1 - lead
        digits = all_digits[lead..].sub(/0+\z/, "")
        digits = "0" if digits.empty?
        k = digits.length
        n = exp + 1

        if k <= n && n <= 21
          digits + "0" * (n - k)
        elsif n.positive? && n <= 21
          "#{digits[0, n]}.#{digits[n..]}"
        elsif n > -6 && n <= 0
          "0." + "0" * -n + digits
        else
          e = n - 1
          head = k > 1 ? "#{digits[0]}.#{digits[1..]}" : digits
          "#{head}e#{e >= 0 ? '+' : '-'}#{e.abs}"
        end
      end
    end
  end
end
