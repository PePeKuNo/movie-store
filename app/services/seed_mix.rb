# Deterministic seed arithmetic.
#
# Every generated value in the application is derived from
# (user seed, region, page, record index, stream name) using only integer
# operations, so the same inputs always produce the same output on any
# machine, on any date, in any order. Nothing here depends on Ruby's
# Random implementation or on Wall-clock time.
class SeedMix
  MASK = 0xFFFF_FFFF_FFFF_FFFF
  GOLDEN_RATIO = 0x9E37_79B9_7F4A_7C15
  FNV_OFFSET = 0xCBF2_9CE4_8422_2325
  FNV_PRIME = 0x0000_0100_0000_01B3

  class << self
    # Combines a base seed with an arbitrary list of parts (strings or integers)
    # into a new 64 bit seed. Order sensitive on purpose.
    def mix(base_seed, *parts)
      acc = base_seed.to_i & MASK
      parts.each do |part|
        value = part.is_a?(String) ? fnv1a(part) : (part.to_i & MASK)
        acc = splitmix64(acc ^ value)
      end
      acc
    end

    # splitmix64 finalizer - a strong avalanche mix for a single 64 bit word.
    def splitmix64(z)
      z = (z + GOLDEN_RATIO) & MASK
      z ^= z >> 30
      z = (z * 0xBF58_476D_1CE4_E5B9) & MASK
      z ^= z >> 27
      z = (z * 0x94D0_49BB_1331_11EB) & MASK
      z ^ (z >> 31)
    end

    # FNV-1a, used to fold region codes / stream names into the seed.
    def fnv1a(string)
      string.to_s.each_byte.reduce(FNV_OFFSET) do |hash, byte|
        ((hash ^ byte) * FNV_PRIME) & MASK
      end
    end
  end
end
