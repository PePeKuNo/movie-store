# A small, fully deterministic pseudo random generator (xoshiro256**).
#
# We deliberately do not use Ruby's Random class: its algorithm is an
# implementation detail that could change between Ruby versions, which would
# break the "same seed => same data forever" requirement. This generator is
# self contained, very fast, and has a fixed, documented algorithm.
#
# It also mimics the parts of Ruby's Random interface that Faker relies on
# (rand, rand(n), rand(range)), so it can be plugged straight into
# Faker::Config.random.
class SeededRng
  MASK = 0xFFFF_FFFF_FFFF_FFFF
  TWO_POW_53 = 9_007_199_254_740_992.0
  GOLDEN_RATIO = 0x9E37_79B9_7F4A_7C15

  def initialize(seed)
    state = seed.to_i & MASK
    @s = Array.new(4) do
      state = (state + GOLDEN_RATIO) & MASK
      z = state
      z = ((z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9) & MASK
      z = ((z ^ (z >> 27)) * 0x94D0_49BB_1331_11EB) & MASK
      z ^ (z >> 31)
    end
  end

  # Next raw 64 bit unsigned integer.
  def next_u64
    result = (rotl((@s[1] * 5) & MASK, 7) * 9) & MASK
    t = (@s[1] << 17) & MASK

    @s[2] ^= @s[0]
    @s[3] ^= @s[1]
    @s[1] ^= @s[2]
    @s[0] ^= @s[3]
    @s[2] ^= t
    @s[3] = rotl(@s[3], 45)

    result
  end

  # Uniform float in [0, 1)
  def float
    (next_u64 >> 11).fdiv(TWO_POW_53)
  end

  # Ruby Random#rand compatible entry point.
  def rand(*args)
    case args.size
    when 0 then float
    when 1
      arg = args.first
      case arg
      when Range  then random_range(arg)
      when Float  then float * arg
      when Numeric then (float * arg).floor
      else raise ArgumentError, "unsupported rand(#{arg.class})"
      end
    when 2 then random_range(args.first..args.last)
    else raise ArgumentError, "wrong number of arguments (given #{args.size}, expected 0..2)"
    end
  end

  def random_range(range)
    min = range.begin
    max = range.end
    if min.is_a?(Integer) && max.is_a?(Integer)
      span = max - min + (range.exclude_end? ? 0 : 1)
      return min if span <= 0

      min + (float * span).floor
    else
      span = max.to_f - min.to_f
      range.exclude_end? ? min + float * (span * (1 - 1e-12)) : min + float * span
    end
  end

  # True with probability +p+ (used for fractional likes/reviews averages).
  def chance(p)
    float < p
  end

  def shuffle(array)
    result = array.dup
    (result.size - 1).downto(1) do |i|
      j = (float * (i + 1)).floor
      result[i], result[j] = result[j], result[i]
    end
    result
  end

  def sample(array)
    return nil if array.nil? || array.empty?

    array[(float * array.size).floor]
  end

  private

  def rotl(x, k)
    ((x << k) | (x >> (64 - k))) & MASK
  end
end
