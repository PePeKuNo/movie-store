# Generates one page (batch) of movies entirely on the server.
#
# Every field is derived from an independent, named random stream so that
# parameters stay independent from each other:
#
#   "content"      - title, cast, year, genre, synopsis, series, trailer plan
#   "review-texts" - review bodies, authors and their star ratings
#   "<kind>-dist"  - how the page's like/review totals are spread over records
#
# Changing the "likes" average therefore never touches titles, actors or the
# trailer; changing the seed or the region regenerates everything.
#
# Likes and reviews are integer counts (how many people liked a movie / how
# many reviews it has). The slider is the *average* of the page: the page
# always sums to exactly average * PAGE_SIZE, while individual movies are
# spread around it with a skewed, realistic distribution - a movie sitting at
# an average of 10 does NOT mean every movie has exactly 10 likes.
class MovieGenerator
  PAGE_SIZE = 20
  YEAR_MIN = 1975
  SERIES_PROBABILITY = 0.18

  # Upper bounds for a single record. They are generous enough that they never
  # bind for slider values of 0..10, but keep payloads sane if the averages
  # are ever raised.
  MAX_LIKES = 100
  MAX_REVIEWS = 40

  @faker_lock = Mutex.new

  def self.faker_lock
    @faker_lock
  end

  def initialize(region:, seed:, likes: 0.0, reviews: 0.0)
    @region = region
    @seed = seed
    @likes = likes.to_f
    @reviews = reviews.to_f
  end

  attr_reader :region, :seed

  # Returns PAGE_SIZE ready to serialise movie hashes for +page+ (1 based).
  def page(page_number)
    page_number = [ page_number.to_i, 1 ].max

    # Both averages are distributed over the whole page: the sum is exact
    # (page mean == slider) and the per record values are skewed, so a page
    # never looks like twenty identical numbers.
    likes = spread(page_number, "likes", @likes, MAX_LIKES)
    review_counts = spread(page_number, "reviews", @reviews, MAX_REVIEWS)

    # Titles come from a word bank, so two records of one page can draw the
    # same one; a repeated title reads like a copy/paste bug in the table, so
    # the page keeps track of what it already used (see #unique_title).
    seen_titles = {}

    records = Array.new(PAGE_SIZE) do |index|
      record(page_number, index,
             likes: likes[index],
             review_count: review_counts[index],
             seen_titles: seen_titles)
    end

    # Kept so the controller can warm the poster cache for this page while it
    # serialises the response - the browser will ask for them a moment later.
    @last_plans = records.map { |entry| entry[:plan] }
    records.map { |entry| entry[:movie] }
  end

  # Trailer plans of the most recent #page call (nil before the first one).
  attr_reader :last_plans

  # The trailer plan of a single record (used by the trailer endpoints).
  def plan_for(page_number, index)
    record(page_number, index, likes: 0, review_count: 0)[:plan]
  end

  def movie_for(page_number, index, likes: 0, review_count: 0)
    record(page_number, index, likes: likes, review_count: review_count)[:movie]
  end

  private

  # Splits +average+ * PAGE_SIZE units over PAGE_SIZE records.
  #
  # Units are dealt one by one to a weighted random record (weights are
  # exponential, i.e. a few movies are much more popular than the rest), so
  # the page sum is exact while the individual values look organic. Records
  # that reached +cap+ stop receiving units, which redistributes them.
  def spread(page_number, kind, average, cap)
    rng = SeededRng.new(SeedMix.mix(@seed, @region.tag, page_number, 0, "#{kind}-dist"))
    weights = Array.new(PAGE_SIZE) { 0.5 + (-Math.log(1.0 - rng.float)) }
    values = Array.new(PAGE_SIZE, 0)

    total = (average.to_f * PAGE_SIZE).round.clamp(0, cap * PAGE_SIZE)
    total.times do
      eligible = (0...PAGE_SIZE).select { |i| values[i] < cap }
      break if eligible.empty?

      sum = eligible.sum { |i| weights[i] }
      pick = rng.float * sum
      chosen = eligible.find { |i| (pick -= weights[i]) < 0 } || eligible.last
      values[chosen] += 1
    end
    values
  end

  def record(page_number, index, likes:, review_count:, seen_titles: nil)
    content = stream(page_number, index, "content")
    text_rng = stream(page_number, index, "review-texts")

    with_faker(content) do
      movie = build_movie(content, text_rng, page_number, index, review_count, seen_titles)
      movie["likes"] = likes
      movie["reviewCount"] = review_count

      plan = TrailerPlanner.plan(
        seed: @seed,
        region: @region,
        page: page_number,
        index: index,
        title: movie.fetch("title"),
        cast: movie.fetch("cast"),
        year: movie.fetch("year"),
        genre: movie.fetch("genres").first
      )
      movie["trailer"] = { "key" => TrailerRenderer.key_for(plan), "duration" => plan.fetch("duration") }

      { movie: movie, plan: plan }
    end
  end

  def stream(page_number, index, name)
    SeededRng.new(SeedMix.mix(@seed, @region.tag, page_number, index, name))
  end

  # A title that is still unused on the current page. The word bank is small
  # enough that two records of one page can draw the same phrase, which looks
  # like a copy/paste bug in the table - so the draw is repeated. Every retry
  # consumes the record's own seeded stream, so the output stays deterministic
  # (only records that would actually have collided are affected).
  def unique_title(seen)
    title = Faker::MovieStore.title
    return title if seen.nil?

    attempts = 0
    while seen.key?(title) && attempts < 8
      title = Faker::MovieStore.title
      attempts += 1
    end
    seen[title] = true
    title
  end

  def build_movie(content, text_rng, page_number, index, review_count, seen_titles)
    title = unique_title(seen_titles)
    genres = [ Faker::MovieStore.genre ]
    genres << Faker::MovieStore.genre if content.rand < 0.4
    genres.uniq!

    {
      "index" => (page_number - 1) * PAGE_SIZE + index + 1,
      "title" => title,
      "year" => YEAR_MIN + content.rand(2026 - YEAR_MIN + 1),
      "genres" => genres,
      "cast" => unique_names(content, 3 + content.rand(3)),
      "director" => Faker::Name.name,
      "duration" => 88 + content.rand(78),
      "rating" => Faker::MovieStore.rating,
      "synopsis" => Faker::MovieStore.synopsis,
      "reviews" => build_reviews(text_rng, review_count),
      "series" => content.rand < SERIES_PROBABILITY ? build_series(content) : nil
    }
  end

  # Exactly +count+ reviews, so the payload never carries unused texts. They
  # live on their own random stream: changing how many reviews are shown never
  # shifts the synopsis / cast / series draws of the "content" stream.
  #
  # Each review also carries its own star rating - a review is a person's
  # opinion, not a copy of the movie's like count.
  STAR_WEIGHTS = [ 1, 2, 4, 6, 9 ]

  def build_reviews(rng, count)
    return [] if count <= 0

    with_random(rng) do
      Array.new(count) do
        text = Faker::MovieStore.review
        text = "#{text} #{Faker::MovieStore.review}" if rng.rand < 0.45
        {
          "text" => text,
          "author" => Faker::Name.name,
          "source" => Faker::MovieStore.review_source,
          "stars" => weighted_stars(rng)
        }
      end
    end
  end

  # 1..5 stars, weighted towards the positive end (like real store reviews).
  def weighted_stars(rng)
    total = STAR_WEIGHTS.sum
    pick = rng.float * total
    STAR_WEIGHTS.each_with_index do |weight, i|
      return i + 1 if (pick -= weight) < 0
    end
    STAR_WEIGHTS.size
  end

  def build_series(rng)
    seasons = 2 + rng.rand(4)
    {
      "seasons" => Array.new(seasons) do |i|
        {
          "number" => i + 1,
          "episodes" => 8 + rng.rand(7),
          "sample" => Array.new(3) do |j|
            { "number" => j + 1, "title" => Faker::MovieStore.title }
          end
        }
      end
    }
  end

  def unique_names(rng, count)
    names = []
    attempts = 0
    while names.size < count && attempts < count * 6
      name = Faker::Name.name
      names << name unless names.include?(name)
      attempts += 1
    end
    names.fill(Faker::Name.name) while names.size < count
    names
  end

  # Faker picks its random source and locale globally, so all access to it is
  # serialised and scoped to a single record generation.
  def with_faker(rng)
    self.class.faker_lock.synchronize do
      previous_random = Faker::Config.random
      previous_locale = Faker::Config.locale
      Faker::Config.random = rng
      Faker::Config.locale = @region.faker_locale
      yield
    ensure
      Faker::Config.random = previous_random
      Faker::Config.locale = previous_locale
    end
  end

  # Temporarily swaps only Faker's random source (locale and lock stay as the
  # surrounding +with_faker+ block set them).
  def with_random(rng)
    previous_random = Faker::Config.random
    Faker::Config.random = rng
    yield
  ensure
    Faker::Config.random = previous_random
  end
end
