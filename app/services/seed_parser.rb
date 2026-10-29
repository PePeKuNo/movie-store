# Parses the user supplied seed into an unsigned 64 bit integer.
# Accepts decimal ("58933423"), hexadecimal ("0x1f4a..." or "1f4a...") and
# any other text (which is folded into a 64 bit hash so that random words
# work as seeds too).
class SeedParser
  MASK = 0xFFFF_FFFF_FFFF_FFFF
  DECIMAL = /\A[0-9]+\z/
  HEXADECIMAL = /\A(?:0x)?[0-9a-fA-F]+\z/

  def self.parse(value)
    text = value.to_s.strip
    return 0 if text.empty?

    integer =
      if text.match?(DECIMAL)
        text.to_i
      elsif text.start_with?("0x", "0X") || text.match?(/\A[0-9a-fA-F]{12,}\z/)
        text.sub(/\A0x/i, "").to_i(16)
      elsif text.match?(HEXADECIMAL)
        text.to_i
      else
        text.each_byte.reduce(0) { |hash, byte| ((hash ^ byte) * 0x0000_0100_0000_01B3) & MASK }
      end

    integer & MASK
  end

  # A random seed that is always at least 48 bits wide.
  def self.random
    bytes = Random.new.bytes(8).bytes
    bytes[7] = (bytes[7] & 0x00FF) | 0x01 # keep bit 48+ set => >= 48 bits
    bytes.reverse.reduce(0) { |value, byte| (value << 8) | byte } & MASK
  end
end
