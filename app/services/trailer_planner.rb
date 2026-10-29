# Builds a deterministic, self describing "trailer plan".
#
# The plan is pure data: which stock clips to use, how they are graded, how
# the camera moves, which transitions connect them, which typographic cards
# are animated on top and which music / sound effects are mixed in.
#
# Exactly the same (seed, region, page, index) always yields the exact same
# plan, so the rendered movie is reproducible forever. The plan itself is
# generated on the server; the browser only plays back what the server
# produced (see TrailerRenderer).
class TrailerPlanner
  FPS = 30
  WIDTH = 1280
  HEIGHT = 720

  # Curated cinematic transitions (xfade). Not a region specific value.
  TRANSITIONS = %w[
    fade fadeblack fadewhite dissolve wipeleft slideleft circleopen zoomin
    smoothleft smoothup diagtl revealleft coverleft fadegrays pixelize
    squeezeh vertopen hlslice
  ].freeze

  # Color grading presets (eq / colorbalance filter arguments).
  #
  # Deliberately restrained: these are colour *styles*, not heavy effects.
  # Contrast stays within ~1.0-1.2, saturation within ~0.1-1.2 and brightness
  # within a few percent, so the footage keeps a natural, photographic look.
  GRADES = [
    { name: "cool_teal",  eq: "contrast=1.10:saturation=0.96:brightness=-0.01:gamma=1.02", balance: "rs=-0.05:bs=0.08:gm=-0.02" },
    { name: "warm_gold",  eq: "contrast=1.07:saturation=1.12:brightness=0.01:gamma=1.00", balance: "rs=0.08:gs=0.02:bs=-0.07" },
    { name: "noir",       eq: "contrast=1.16:saturation=0.12:brightness=-0.02:gamma=0.99", balance: "rs=0.00:gs=0.00:bs=0.00" },
    { name: "bleach",     eq: "contrast=1.14:saturation=0.55:brightness=0.02:gamma=1.03", balance: "rm=0.03:bm=-0.02" },
    { name: "deep_teal",  eq: "contrast=1.12:saturation=1.06:brightness=-0.01:gamma=1.01", balance: "rs=-0.09:gs=0.02:bs=0.12:rh=-0.04" },
    { name: "night_blue", eq: "contrast=1.08:saturation=0.88:brightness=-0.03:gamma=1.08", balance: "bs=0.13:gm=-0.03:rm=-0.04" },
    { name: "amber",      eq: "contrast=1.06:saturation=1.18:brightness=0.02:gamma=1.00", balance: "rs=0.11:gm=0.05:bs=-0.10" },
    { name: "faded_70s",  eq: "contrast=0.98:saturation=0.92:brightness=0.03:gamma=1.05", balance: "rh=0.05:bh=-0.06:rm=0.02" },
    { name: "cold_stock", eq: "contrast=1.12:saturation=0.84:brightness=-0.01:gamma=1.02", balance: "rs=-0.08:gs=-0.02:bs=0.07" },
    { name: "high_noir",  eq: "contrast=1.22:saturation=0.14:brightness=0.01:gamma=0.97", balance: "gs=-0.02" }
  ].freeze

  # The build-up into the title: a low boom, a braam or a reverse cymbal.
  # All three are deterministic picks; the reverse cymbal (white noise) is
  # the quietest of them because it is the one most likely to read as a
  # hiss once the mix is normalised.
  SWELLS = %w[revcym boom braam].freeze
  SWELL_GAIN = { "revcym" => 0.30, "boom" => 0.42, "braam" => 0.34 }.freeze

  # Typographic animations. Every style gets random parameters (direction,
  # timing, distance, weight), so 10 styles x parameters x fonts x palettes
  # already give thousands of different title cards.
  CARD_STYLES = %w[
    zoom_punch slide_up slide_left rotate_settle pan sway bob
    flash_pop rise_fade drop_in scale_out split_reveal truck
  ].freeze

  # Text colours (not region specific).
  PALETTES = [
    [ "#FFFFFF", "#E9C46A" ],
    [ "#FDF6E3", "#E76F51" ],
    [ "#FFFFFF", "#7FD1E0" ],
    [ "#F4E4C1", "#C1440E" ],
    [ "#FFFFFF", "#B8F2E6" ],
    [ "#FFE9C7", "#FF3C38" ],
    [ "#EDEDED", "#F0A202" ],
    [ "#FFFFFF", "#A8DADC" ]
  ].freeze

  TITLE_KEY_STYLE = "title"

  def self.plan(seed:, region:, page:, index:, title:, cast:, year:, genre:)
    new(seed: seed, region: region, page: page, index: index, title: title,
        cast: cast, year: year, genre: genre).plan
  end

  def initialize(seed:, region:, page:, index:, title:, cast:, year:, genre:)
    @seed = seed
    @region = region
    @page = page
    @index = index
    @title = title
    @cast = cast
    @year = year
    @genre = genre
    @rng = SeededRng.new(SeedMix.mix(seed, region.tag, page, index, "trailer"))
    @content = SeededRng.new(SeedMix.mix(seed, region.tag, page, index, "content"))
  end

  def plan
    shots = build_shots
    transitions = build_transitions(shots)
    total = total_duration(shots, transitions)
    cards = build_cards(total, shots, transitions)
    audio = build_audio(total, cards)

    {
      "version" => 1,
      "fps" => FPS,
      "width" => WIDTH,
      "height" => HEIGHT,
      "duration" => total.round(3),
      "shots" => shots,
      "transitions" => transitions,
      "cards" => cards,
      "audio" => audio,
      "poster_at" => poster_time(cards).round(3),
      "poster_card" => title_card(cards)&.fetch("id")
    }
  end

  private

  # ---------------------------------------------------------------- shots --

  def build_shots
    clips = MediaLibrary.clips
    raise "media library has no clips" if clips.empty?

    clip_count = [ [ clips.size, 4 ].min, 3 ].max
    chosen_ids = @rng.shuffle(clips.map { |clip| clip.fetch("id") }).first(clip_count)

    shot_count = @rng.rand(4..5)
    shots = []

    shot_count.times do |i|
      clip_id = chosen_ids[i % chosen_ids.size]
      clip = clips.find { |entry| entry.fetch("id") == clip_id }
      clip_duration = clip.fetch("duration").to_f

      # transition lengths eat into the timeline
      duration = (1.75 + @rng.float * 0.85).round(3)
      # The renderer plays `duration` seconds of source footage starting at
      # `source_start` (the shot filter trims at 1:1, tpad only covers the
      # xfade overlap), so the chosen window must fit inside the clip with a
      # little margin. Seeking at or past EOF yields zero frames, which makes
      # ffmpeg spin forever on the infinite PNG input of the poster command.
      source_length = [ duration * (0.9 + @rng.float * 0.45), clip_duration ].min
      source_length = [ [ source_length, 1.2 ].max, duration ].max
      source_length = [ source_length, clip_duration ].min
      speed = (duration / source_length).round(4)
      max_start = [ clip_duration - duration - 0.05, 0 ].max
      source_start = (@rng.float * max_start).round(3)

      shots << {
        "id" => i,
        "clip" => clip_id,
        "source_start" => source_start,
        "source_length" => source_length.round(3),
        "duration" => duration,
        "speed" => speed,
        "zoom" => zoom_animation,
        "pan" => pan_animation,
        "grade" => grade_for(i),
        "grain" => (2 + @rng.rand(5)),
        "vignette" => (4.4 + @rng.float * 1.6).round(4),
        "shake" => @rng.float < 0.3
      }
    end

    shots
  end

  def zoom_animation
    mode = @rng.rand(4)
    from = (1.0 + @rng.float * 0.06).round(4)
    to = case mode
    when 0 then (from + 0.06 + @rng.float * 0.10).round(4) # slow push in
    when 1 then (from + 0.04 + @rng.float * 0.08).round(4)
    when 2 then [ from - 0.04, 1.0 ].max.round(4)             # pull out
    else (from + 0.03 + @rng.float * 0.16).round(4)         # bigger push
    end
    { "from" => from, "to" => [ to, 1.0 ].max }
  end

  def pan_animation
    axis = @rng.rand(4)
    drift = 0.12 + @rng.float * 0.5
    start_point = 0.2 + @rng.float * 0.6
    stop_point = (start_point + (axis.even? ? drift : -drift)).clamp(0.0, 1.0)
    { "from" => start_point.round(4), "to" => stop_point.round(4), "axis" => axis.even? ? "x" : "y" }
  end

  def grade_for(index)
    base = GRADES[(@rng.rand(GRADES.size) + index) % GRADES.size]
    {
      "name" => base[:name],
      "eq" => base[:eq],
      "balance" => base[:balance],
      "hue" => @rng.rand(-10..10),
      "lift" => ((@rng.float - 0.5) * 0.05).round(4)
    }
  end

  def build_transitions(shots)
    count = shots.size - 1
    Array.new(count) do |i|
      {
        "type" => TRANSITIONS[@rng.rand(TRANSITIONS.size)],
        "duration" => (0.30 + @rng.float * 0.30).round(3),
        # a flash / black cut is inserted before the title reveal sometimes
        "cut" => i == count - 1 && @rng.float < 0.55
      }
    end
  end

  def total_duration(shots, transitions)
    raw = shots.sum { |shot| shot.fetch("duration").to_f } -
          transitions.sum { |transition| transition.fetch("duration").to_f }
    raw = raw.clamp(6.4, 9.6)
    raw
  end

  # ---------------------------------------------------------------- cards --

  def build_cards(total, shots, transitions)
    cards = []
    fonts = MediaLibrary.display_fonts
    fonts = MediaLibrary.fonts if fonts.empty?
    palette = PALETTES[@rng.rand(PALETTES.size)]

    # 1. opening tagline
    cards << card(
      role: "tagline",
      text: Faker::MovieStore.tagline,
      start: (0.45 + @rng.float * 0.45).round(3),
      duration: (1.30 + @rng.float * 0.55).round(3),
      fonts: fonts,
      palette: palette,
      size_range: [ 46, 66 ],
      position: :center
    )

    # 2. cast card
    actor = @cast[@rng.rand(@cast.size)]
    cards << card(
      role: "credit",
      text: "#{Faker::MovieStore.credit_role} #{actor}",
      start: (transitions.first ? transitions.first.fetch("duration") + 1.55 : 2.4).round(3),
      duration: (1.45 + @rng.float * 0.55).round(3),
      fonts: fonts,
      palette: [ palette[1], palette[0] ],
      size_range: [ 34, 52 ],
      position: :center
    )

    # 3. the title, always at the end - this frame is the freeze frame
    title_duration = (2.30 + @rng.float * 0.60).round(3)
    title_start = [ total - title_duration - 0.12, 0.0 ].max.round(3)
    title = card(
      role: TITLE_KEY_STYLE,
      text: @title.to_s.upcase,
      start: title_start,
      duration: title_duration,
      fonts: fonts,
      palette: [ palette[0], palette[1] ],
      size_range: [ 82, 124 ],
      position: @rng.float < 0.25 ? :upper : :center,
      uppercase: true
    )
    cards << title

    # 4. studio / meta line under the title
    cards << card(
      role: "studio",
      text: "#{Faker::MovieStore.studio} \u00b7 #{@year} \u00b7 #{@genre}",
      start: (title_start + 0.55).round(3),
      duration: [ total - title_start - 0.55, 1.6 ].min.round(3),
      fonts: fonts,
      palette: [ palette[1], palette[0] ],
      size_range: [ 20, 30 ],
      position: :lower,
      uppercase: false
    )

    cards.select { |entry| entry.fetch("start") + entry.fetch("duration") <= total + 0.01 }
  end

  def card(role:, text:, start:, duration:, fonts:, palette:, size_range:, position:, uppercase: false)
    font = fonts[@rng.rand(fonts.size)]
    style = CARD_STYLES[@rng.rand(CARD_STYLES.size)]
    size = size_range[0] + @rng.rand(size_range[1] - size_range[0] + 1)

    {
      "id" => "#{role}-#{@cards_serial = (@cards_serial || 0) + 1}",
      "role" => role,
      "text" => text.to_s.strip,
      "start" => start.to_f.clamp(0.0, 120.0).round(3),
      "duration" => duration.to_f.round(3),
      "style" => style,
      "font" => font.fetch("file"),
      "font_family" => font.fetch("family"),
      "weight" => font.fetch("weight").to_i,
      "size" => size,
      "color" => palette[0],
      "accent" => palette[1],
      "position" => position,
      "uppercase" => uppercase || role == TITLE_KEY_STYLE,
      "tracking" => @rng.float < 0.45,
      "glow" => @rng.float < 0.35,
      "shadow" => @rng.float < 0.7,
      "delay" => (0.06 + @rng.float * 0.22).round(3)
    }
  end

  def title_card(cards)
    cards.find { |entry| entry.fetch("role") == TITLE_KEY_STYLE }
  end

  def poster_time(cards)
    title = title_card(cards)
    return 1.0 unless title

    [ title.fetch("start") + title.fetch("duration") * 0.42, 0.1 ].max
  end

  # ---------------------------------------------------------------- audio --

  def build_audio(total, cards)
    music = MediaLibrary.music
    title = title_card(cards)

    events = []
    # The build-up into the title comes in three flavours (reverse cymbal,
    # low boom, braam), so consecutive trailers do not all rustle the same
    # way; the noise based one is deliberately the quietest of the three.
    swell = SWELLS[@rng.rand(SWELLS.size)]
    events << {
      "type" => swell,
      "at" => [ title ? title.fetch("start") - 1.4 : 1.0, 0.0 ].max.round(3),
      "gain" => SWELL_GAIN.fetch(swell)
    }
    events << { "type" => "impact", "at" => title ? title.fetch("start") : 1.0, "gain" => 0.6 } if title
    events << { "type" => "whoosh", "at" => 0.35, "gain" => 0.30 }
    events << { "type" => "whoosh", "at" => [ total - 1.0, 1.0 ].max.round(3), "gain" => 0.26 }

    {
      "music" => music.empty? ? nil : File.basename(music[@rng.rand(music.size)]),
      "music_offset" => (@rng.float * 25).round(3),
      # Kept low enough that music + sfx never fight each other; the final
      # limiter (see TrailerRenderer#audio_sanitize) does the rest.
      "music_gain" => (0.24 + @rng.float * 0.10).round(3),
      "events" => events
    }
  end
end
