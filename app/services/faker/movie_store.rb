module Faker
  # Extends Faker with the vocabulary of the movie showcase.
  #
  # All word banks are external locale data living in
  # config/locales/movies/<faker-locale>.yml under the `faker.movie_store`
  # namespace - the way Faker documents extending it. Adding a new language
  # therefore only requires a new YAML file plus an entry in
  # config/regions.yml.
  class MovieStore < Faker::Base
    # Any unknown method (adjective, noun, place, ...) resolves to
    # faker.movie_store.<method> in the currently configured locale.
    flexible :movie_store

    class << self
      # Templates that contain #{...} placeholders.
      # Faker's own #parse drops any literal text that appears before the
      # first placeholder, so we expand templates ourselves - still using
      # Faker's word banks and Faker's sample/fetch machinery.
      def title
        expand("movie_store.title_pattern")
      end

      def review
        expand("movie_store.review_sentence")
      end

      def synopsis
        expand("movie_store.synopsis")
      end

      # Picks a random template and substitutes every #{key} with a value
      # coming from the same locale dataset.
      def expand(key, depth = 0)
        template = fetch(key)
        return template unless template.is_a?(::String)
        return template.gsub(/#\{\w+\}/, "") if depth > 6

        substitute(template, depth)
      end

      def substitute(template, depth)
        template.gsub(/#\{([A-Za-z_][A-Za-z0-9_]*)\}/) do
          name = Regexp.last_match(1)
          value =
            if respond_to?(name)
              public_send(name)
            else
              expand("movie_store.#{name}", depth + 1)
            end
          value = sample(value) if value.is_a?(Array)
          # nested templates may themselves contain placeholders
          value.is_a?(::String) && value.include?("#") ? substitute(value, depth + 1) : value
        end
      end

      # Plain word banks.
      def genre
        fetch("movie_store.genre")
      end

      def tagline
        fetch("movie_store.tagline")
      end

      def credit_role
        fetch("movie_store.credit_role")
      end

      def rating
        fetch("movie_store.rating")
      end

      def review_source
        fetch("movie_store.review_source")
      end

      def studio
        fetch("movie_store.studio")
      end

      def suffix
        fetch("movie_store.suffix")
      end

      def season_word
        fetch("movie_store.season_word")
      end

      def words(key)
        fetch("movie_store.#{key}")
      end
    end
  end
end
