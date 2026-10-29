require "yaml"

# Reads config/regions.yml - the list of supported language/regions.
# Everything region specific (labels, Faker locale, movie word banks) is
# loaded from external files, never from Ruby source code.
class RegionRegistry
  Region = Struct.new(:tag, :label, :faker_locale, :default, keyword_init: true) do
    def to_h
      { "tag" => tag, "label" => label }
    end
  end

  FILE = Rails.root.join("config", "regions.yml")

  class << self
    def all
      @all ||= load_file
    end

    def find(tag)
      all.find { |region| region.tag == tag.to_s } || default
    end

    def default
      all.find(&:default) || all.first
    end

    def tags
      all.map(&:tag)
    end

    # Reload is only used by the test/dev console.
    def reload!
      @all = nil
      all
    end

    private

    def load_file
      raw = YAML.safe_load_file(FILE, aliases: true)
      Array(raw["regions"]).map do |entry|
        Region.new(
          tag: entry.fetch("tag"),
          label: entry.fetch("label"),
          faker_locale: entry.fetch("faker_locale"),
          default: entry["default"] ? true : false
        )
      end
    end
  end
end
