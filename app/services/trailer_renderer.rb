require "digest"
require "etc"
require "fileutils"
require "open3"
require "pathname"

# Turns a TrailerPlan into an actual movie file with ffmpeg.
#
#   * 4..5 shots taken from the bundled stock footage library
#   * per shot: random grade (eq / colorbalance / hue), film grain, vignette,
#     a slow ken-burns camera move and a speed change
#   * shots are joined with randomly chosen xfade transitions
#   * typographic title cards are rendered as transparent PNGs (drawtext with
#     glow + shadow) and animated on top of the video: punch-in, slide,
#     typewriter wipe, rotation, split reveal, ...
#   * a music bed plus whooshes / risers / impacts are mixed in
#
# Everything is derived from the plan, which is derived from the seed, so the
# same seed always produces the same choices and therefore the same movie.
class TrailerRenderer
  BASE_W = 1280
  BASE_H = 720
  PNG_SCALE = 1
  PNG_W = BASE_W * PNG_SCALE
  PNG_H = BASE_H * PNG_SCALE
  FPS = 30

  QUALITIES = {
    "hd" => [ 1280, 720 ],
    "sd" => [ 854, 480 ],
    "ld" => [ 640, 360 ]
  }.freeze

  CACHE_ROOT = Rails.root.join("tmp", "trailer_cache")

  # Concurrency budget, split by job kind:
  #   * posters are a single frame (~0.4 s) but twenty arrive at once with a
  #     page, so they get their own slots and always run first;
  #   * videos take ~10 s each and are CPU heavy, so they stay capped.
  # Neither kind can starve the other, and neither ever holds an HTTP worker
  # thread while ffmpeg runs - requests only enqueue and poll.
  POSTER_PARALLEL = Integer(ENV.fetch("MS_POSTER_PARALLEL", "4"))
  VIDEO_PARALLEL = Integer(ENV.fetch("MS_VIDEO_PARALLEL", "3"))

  # Threads x264 may use per render. Left alone, every concurrent render asks
  # for all logical cores: three renders then fight over 12 threads each and a
  # 9 s job crawls to ~70 s (measured). Splitting the cores between the slots
  # keeps the machine busy without the thrash - see MS_VIDEO_THREADS.
  VIDEO_THREADS = Integer(
    ENV.fetch("MS_VIDEO_THREADS") { [ Etc.nprocessors / VIDEO_PARALLEL, 1 ].max }
  )

  # The same frame is kept in three widths: the table thumbnail is 62 CSS px
  # wide, cards and the detail panel never exceed 640 CSS px, and the full
  # 1280 px frame stays available for anything larger. Serving 75..127 KB
  # frames for 62 px thumbnails cost ~2 MB per page.
  POSTER_WIDTHS = [ 160, 640 ].freeze

  # Hard ceiling for a single ffmpeg invocation. A render that would otherwise
  # spin forever (bad seek, unreadable input, ...) is killed and reported as an
  # error instead of pinning a worker thread for the rest of the process life.
  FFMPEG_TIMEOUT = Integer(ENV.fetch("MS_FFMPEG_TIMEOUT", "120"))

  class RenderError < StandardError; end

  @mutex = Mutex.new
  @active = {}          # job => :poster | :video
  @poster_queue = []
  @video_queue = []
  @poster_active = 0
  @video_active = 0
  @locks = {}

  class << self
    # Short, stable identifier of a plan.
    def key_for(plan)
      Digest::SHA256.hexdigest(plan.to_json)[0, 20]
    end

    def video_path(plan, quality = "hd")
      CACHE_ROOT.join("#{key_for(plan)}_#{quality}.mp4")
    end

    def poster_path(plan, width = nil)
      width = width.to_i
      return CACHE_ROOT.join("#{key_for(plan)}_poster.jpg") unless POSTER_WIDTHS.include?(width)

      CACHE_ROOT.join("#{key_for(plan)}_poster_#{width}.jpg")
    end

    # A downscaled poster for +width+, derived from the full frame when only
    # the full frame exists yet (cache entries from an earlier deploy). When
    # neither is on disk the caller should queue a poster render instead.
    def poster_variant(plan, width)
      width = width.to_i
      return poster_path(plan) unless POSTER_WIDTHS.include?(width)

      path = poster_path(plan, width)
      return path if path.exist? && path.size.positive?

      with_key_lock(key_for(plan)) do
        return path if path.exist? && path.size.positive?

        FileUtils.mkdir_p(CACHE_ROOT)
        new(plan).derive_poster_variant(width)
      end
    rescue StandardError => e
      Rails.logger.error("[trailer] poster variant failed: #{e.class}: #{e.message}")
      nil
    end

    # Fast, synchronous: a single frame with the title card on it.
    def poster(plan)
      path = poster_path(plan)
      return path if path.exist? && path.size.positive?

      # Concurrent requests for the same poster share one render instead of
      # racing each other and duplicating the ffmpeg work.
      with_key_lock(key_for(plan)) do
        return path if path.exist? && path.size.positive?

        FileUtils.mkdir_p(CACHE_ROOT)
        new(plan).render_poster
      end
      path
    end

    # Non-blocking poster: returns "ready" when the frame is already on disk,
    # otherwise queues a background render. The caller decides how long (if at
    # all) it is willing to wait for it.
    def request_poster(plan)
      path = poster_path(plan)
      return { "state" => "ready" } if path.exist? && path.size.positive?

      job = "#{key_for(plan)}:poster"
      @mutex.synchronize do
        return { "state" => "running" } if @active[job]
        return { "state" => "pending" } if @poster_queue.any? { |queued| queued.first == job }

        @poster_queue << [ job, plan ]
        pump_queue
        @active[job] ? { "state" => "running" } : { "state" => "pending" }
      end
    end

    # Starts background poster renders for a whole page, so the frames are
    # (mostly) on disk by the time the browser asks for the first <img>.
    def warm_posters(plans)
      plans.each do |plan|
        path = poster_path(plan)
        next if path.exist? && path.size.positive?

        request_poster(plan)
      end
      nil
    end

    # Starts a background render when needed. Returns the current state.
    def request_video(plan, quality = "hd")
      path = video_path(plan, quality)
      return { "state" => "ready" } if path.exist? && path.size.positive?

      job = "#{key_for(plan)}:#{quality}"
      @mutex.synchronize do
        return { "state" => "running" } if @active[job]
        return { "state" => "pending" } if @video_queue.any? { |queued| queued.first == job }

        @video_queue << [ job, plan, quality ]
        pump_queue
        @active[job] ? { "state" => "running" } : { "state" => "pending" }
      end
    end

    def video_state(plan, quality = "hd")
      path = video_path(plan, quality)
      return "ready" if path.exist? && path.size.positive?

      job = "#{key_for(plan)}:#{quality}"
      @mutex.synchronize do
        if @active[job]
          "running"
        elsif @video_queue.any? { |queued| queued.first == job }
          "pending"
        else
          "missing"
        end
      end
    end

    # Renders a missing video synchronously. The HTTP layer never calls it
    # (the exporter waits on the queue instead); it exists for scripts and
    # debugging that want a file right now.
    def render_blocking!(plan, quality = "hd")
      path = video_path(plan, quality)
      return path if path.exist? && path.size.positive?

      with_key_lock("#{key_for(plan)}:#{quality}") do
        return path if path.exist? && path.size.positive?

        FileUtils.mkdir_p(CACHE_ROOT)
        new(plan, quality).render_video
      end
      path
    end

    def stats
      @mutex.synchronize do
        {
          "active" => @active.size,
          "queued" => @poster_queue.size + @video_queue.size,
          "posters" => @poster_active,
          "videos" => @video_active
        }
      end
    end

    private

    # Serialises renders that write the same cache entry.
    def with_key_lock(key)
      lock = @mutex.synchronize { @locks[key] ||= Mutex.new }
      lock.synchronize { yield }
    end

    # Fills the free slots, posters first. Must be called with @mutex held.
    #
    # A job that cannot get a thread (transient resource exhaustion) is put
    # back at the head of its queue and the pump stops for this round: the
    # next request will try again, and nothing is ever dropped silently.
    def pump_queue
      while @poster_active < POSTER_PARALLEL && !@poster_queue.empty?
        job, plan = @poster_queue.shift
        next if @active[job]
        next if start_poster_job(job, plan)

        @poster_queue.unshift([ job, plan ])
        break
      end

      while @video_active < VIDEO_PARALLEL && !@video_queue.empty?
        job, plan, quality = @video_queue.shift
        next if @active[job]
        next if start_video_job(job, plan, quality)

        @video_queue.unshift([ job, plan, quality ])
        break
      end
    end

    # Returns false when the thread could not be created (job stays queued).
    def start_poster_job(job, plan)
      @active[job] = :poster
      @poster_active += 1
      Thread.new do
        begin
          FileUtils.mkdir_p(CACHE_ROOT)
          with_key_lock(key_for(plan)) do
            path = poster_path(plan)
            new(plan).render_poster unless path.exist? && path.size.positive?
          end
        rescue StandardError => e
          Rails.logger.error("[trailer] poster failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(6)&.join("\n")}")
        ensure
          @mutex.synchronize do
            @active.delete(job)
            @poster_active -= 1
            pump_queue
          end
        end
      end
      true
    rescue ThreadError => e
      @active.delete(job)
      @poster_active -= 1
      Rails.logger.error("[trailer] poster thread not started: #{e.message}")
      false
    end

    def start_video_job(job, plan, quality)
      @active[job] = :video
      @video_active += 1
      Thread.new do
        begin
          FileUtils.mkdir_p(CACHE_ROOT)
          new(plan, quality).render_video
        rescue StandardError => e
          Rails.logger.error("[trailer] render failed: #{e.class}: #{e.message}\n#{e.backtrace&.first(6)&.join("\n")}")
        ensure
          @mutex.synchronize do
            @active.delete(job)
            @video_active -= 1
            pump_queue
          end
        end
      end
      true
    rescue ThreadError => e
      @active.delete(job)
      @video_active -= 1
      Rails.logger.error("[trailer] video thread not started: #{e.message}")
      false
    end
  end

  # -------------------------------------------------------------- instance --

  def initialize(plan, quality = "hd")
    @plan = plan
    @quality = QUALITIES.key?(quality) ? quality : "hd"
    @out_w, @out_h = QUALITIES[@quality]
    @key = self.class.key_for(plan)
  end

  attr_reader :plan, :key

  def render_video
    out = self.class.video_path(plan, @quality)
    return out if out.exist? && out.size.positive?

    ensure_card_pngs
    inputs, lines = build_graph
    # Measure the mix first, then correct it with one constant factor: a
    # per-frame normaliser would swell the quiet passages (and the hiss in
    # them) every time the music ducks.
    gain = static_gain(measure_mix(inputs, lines))
    lines << "[#{@audio_label}]#{audio_sanitize(gain)}[aout]"
    graph = lines.join(";")
    # ffmpeg writes into a temporary file first: a request that arrives while
    # the render is still running must never see a half-written movie, and the
    # status endpoint only reports "ready" once the final path exists.
    tmp = staging_path(out)
    cmd = [
      ffmpeg, "-y", "-hide_banner", "-loglevel", "error",
      "-filter_complex_threads", VIDEO_THREADS.to_s,
      *inputs,
      "-filter_complex", graph,
      "-map", "[vout]", "-map", "[aout]",
      "-threads", VIDEO_THREADS.to_s,
      "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
      "-pix_fmt", "yuv420p", "-r", FPS.to_s,
      "-c:a", "aac", "-b:a", "160k", "-ar", "44100",
      "-movflags", "+faststart",
      "-t", plan.fetch("duration").to_s,
      tmp.to_s
    ]
    run!(cmd, tmp)
    publish(tmp, out)
    out
  end

  def render_poster
    out = self.class.poster_path(plan)
    card = plan.fetch("cards").find { |c| c.fetch("id") == plan["poster_card"] }
    card ||= plan.fetch("cards").last

    ensure_card_pngs([ card ].compact)
    shot, offset = shot_at(plan.fetch("poster_at"))
    clip_id = shot.fetch("clip")
    clip = MediaLibrary.clip_path(clip_id)
    clip_duration = MediaLibrary.clips.find { |entry| entry.fetch("id") == clip_id }.fetch("duration").to_f
    # A shot consumes source footage at 1:1, so the frame `offset` seconds into
    # the shot lives at source_start + offset. Clamp hard: a seek at or past EOF
    # gives ffmpeg zero frames and it then spins forever on the `-loop 1` PNG.
    limit = [ clip_duration - 0.05, 0.0 ].max
    seek = [ [ shot.fetch("source_start") + offset, 0.0 ].max, limit ].min

    graph = +"[0:v]#{shot_filter(shot, pan: false)}"
    # A light touch only: the poster should look like a graded film still,
    # not an underexposed one.
    graph << ",eq=brightness=-0.04:contrast=1.03"
    graph << ",format=yuv420p[bg]"

    if card
      graph << ";[1:v]scale=#{BASE_W}:#{BASE_H},format=rgba[tx]"
      graph << ";[bg][tx]overlay=0:0:shortest=1[vout]"
    else
      graph.sub!(/\[bg\]\z/, "[vout]")
    end

    # One decode, one grade, three files: the full frame plus the two widths
    # the UI actually displays (62 px table thumb, <=640 px cards).
    jobs = [ { label: "[sp0]", dest: out, q: "2" } ]
    POSTER_WIDTHS.each_with_index do |width, index|
      jobs << { label: "[sw#{index}]", dest: self.class.poster_path(plan, width), q: width <= 160 ? "7" : "5" }
    end
    count = jobs.size
    graph << ";[vout]split=#{count}#{(0...count).map { |i| "[sp#{i}]" }.join}"
    POSTER_WIDTHS.each_with_index do |width, index|
      graph << ";[sp#{index + 1}]scale=#{width}:-2:flags=bicubic[sw#{index}]"
    end

    cmd = [
      ffmpeg, "-y", "-hide_banner", "-loglevel", "error",
      "-ss", format("%.3f", seek), "-i", clip.to_s
    ]
    cmd += [ "-loop", "1", "-i", png_path(card).to_s ] if card
    cmd += [ "-filter_complex", graph ]

    pairs = jobs.map do |job|
      tmp = staging_path(job.fetch(:dest))
      cmd += [ "-map", job.fetch(:label), "-frames:v", "1", "-q:v", job.fetch(:q), tmp.to_s ]
      [ tmp, job.fetch(:dest) ]
    end

    begin
      run!(cmd, pairs.first.first)
    rescue StandardError
      pairs.each { |tmp, _dest| FileUtils.rm_f(tmp) }
      raise
    end
    pairs.each { |tmp, dest| publish(tmp, dest) }
    out
  end

  # Scales an already rendered frame down to +width+ px. Used for cache
  # entries written before the width variants existed, so a page of old
  # posters needs no full re-render.
  def derive_poster_variant(width)
    full = self.class.poster_path(plan)
    dest = self.class.poster_path(plan, width)
    return dest if dest.exist? && dest.size.positive?
    return nil unless full.exist? && full.size.positive?

    tmp = staging_path(dest)
    quality = width <= 160 ? "7" : "5"
    begin
      run!([
        ffmpeg, "-y", "-hide_banner", "-loglevel", "error",
        "-i", full.to_s,
        "-vf", "scale=#{width}:-2:flags=bicubic",
        "-frames:v", "1", "-q:v", quality, tmp.to_s
      ], tmp)
    rescue StandardError
      FileUtils.rm_f(tmp)
      raise
    end
    publish(tmp, dest)
    dest
  end

  # A sibling of the final file with a distinct suffix; same directory so the
  # final move is a rename on the same volume. The extension is preserved so
  # ffmpeg still picks the right container.
  def staging_path(out)
    out.dirname.join(
      "#{out.basename('.*')}.part-#{Process.pid}-#{SecureRandom.hex(4)}#{out.extname}"
    )
  end

  # Atomically replaces the destination with a finished file.
  def publish(tmp, out)
    File.rename(tmp.to_s, out.to_s)
  rescue Errno::EACCES, Errno::EEXIST, Errno::ENOENT
    FileUtils.mv(tmp.to_s, out.to_s, force: true)
  ensure
    FileUtils.rm_f(tmp.to_s) if tmp.to_s != out.to_s
  end

  private

  # ------------------------------------------------------------- card PNGs --

  def ensure_card_pngs(cards = plan.fetch("cards"))
    FileUtils.mkdir_p(CACHE_ROOT)
    cards.compact.each { |card| render_card_png(card) }
  end

  def png_path(card)
    CACHE_ROOT.join("#{@key}_#{card.fetch('id')}.png")
  end

  def render_card_png(card)
    path = png_path(card)
    return path if path.exist? && path.size.positive?

    text = card.fetch("text").to_s
    text = text.upcase if card["uppercase"]
    text = add_tracking(text) if card["tracking"]

    text_file = CACHE_ROOT.join("#{@key}_#{card.fetch('id')}.txt")
    File.write(text_file, text, encoding: "UTF-8")

    size = fitted_size(text, card)
    font = MediaLibrary.font_path(card.fetch("font")).to_s.gsub("\\", "/")
    font_rel = relative_to_cache(font)
    text_rel = text_file.basename.to_s

    x = "(w-text_w)/2"
    # the planner stores positions as symbols (:upper/:center/:lower)
    y = case card["position"].to_s
    when "upper" then "(h-text_h)/2-h*0.22"
    when "lower" then "(h-text_h)/2+h*0.32"
    else "(h-text_h)/2"
    end

    filters = []
    if card["glow"]
      halo = +"drawtext=fontfile='#{font_rel}':textfile='#{text_rel}':expansion=none"
      halo << ":fontsize=#{size * PNG_SCALE}:fontcolor=#{card['accent']}@0.9"
      halo << ":x=#{x}:y=#{y}"
      filters << halo
      # heavy blur so the accent copy reads as a glow, not as a second copy
      # of the text (the canvas is 2x, so the radius has to be large)
      filters << "boxblur=13:2"
    end

    main = +"drawtext=fontfile='#{font_rel}':textfile='#{text_rel}':expansion=none"
    main << ":fontsize=#{size * PNG_SCALE}:fontcolor=#{card['color']}"
    main << ":x=#{x}:y=#{y}"
    main << ":shadowx=0:shadowy=8:shadowcolor=black@0.72" if card["shadow"]
    main << ":borderw=#{card['glow'] ? 3 : 2}:bordercolor=#{card['accent']}@0.55"
    filters << main

    cmd = [
      ffmpeg, "-y", "-hide_banner", "-loglevel", "error",
      "-f", "lavfi", "-i", "nullsrc=s=#{PNG_W}x#{PNG_H}:rate=1,format=rgba",
      "-vf", filters.join(","),
      "-frames:v", "1", path.to_s
    ]
    run!(cmd, path, chdir: CACHE_ROOT.to_s)
    text_file.delete if text_file.exist?
    path
  end

  # Keeps long titles inside the canvas (drawtext neither wraps nor fits).
  def fitted_size(text, card)
    chars = text.length
    return card.fetch("size") if chars.zero?

    factor = card["tracking"] ? 0.70 : 0.62
    max_width = PNG_W - 140
    fit = (max_width / (chars * factor.to_f)).floor
    [ [ card.fetch("size"), fit ].min, 26 ].max
  end

  def add_tracking(text)
    text.chars.join("\u2009")
  end

  def relative_to_cache(path)
    Pathname.new(path).relative_path_from(Pathname.new(CACHE_ROOT.to_s)).to_s.gsub("\\", "/")
  end

  # ---------------------------------------------------------------- graphs ---

  def build_graph
    duration = plan.fetch("duration").to_f
    shots = plan.fetch("shots")
    cards = plan.fetch("cards")
    transitions = plan.fetch("transitions")

    inputs = []
    graph = []

    shots.each do |shot|
      inputs += [ "-ss", format("%.3f", shot.fetch("source_start")), "-i", MediaLibrary.clip_path(shot.fetch("clip")).to_s ]
    end

    cards.each do |card|
      # a single decoded frame, repeated by the `loop` filter (re-decoding
      # the PNG for every frame with `-loop 1` is by far the slowest part)
      inputs += [ "-i", png_path(card).to_s ]
    end

    audio = plan.fetch("audio")
    music_path = audio["music"] ? Rails.root.join("public", "media", "music", audio.fetch("music")) : nil
    music_path = nil unless music_path&.exist?

    # Everything added from here on is audio: the loudness probe (see
    # measure_mix) reuses just this tail of the graph, so it never has to
    # decode or filter a single video frame.
    @video_inputs = inputs.count("-i")
    @audio_argv_start = inputs.size

    inputs += [ "-ss", format("%.3f", audio.fetch("music_offset")), "-t", (duration + 1.0).to_s, "-i", music_path.to_s ] if music_path

    events = audio.fetch("events").select { |event| sfx_path(event["type"]) }
    events.each do |event|
      inputs += [ "-t", "3.5", "-i", sfx_path(event.fetch("type")).to_s ]
    end

    # 1. one graded, moving chain per shot
    shots.each_with_index do |shot, index|
      graph << "[#{index}:v]#{shot_filter(shot)}[s#{index}]"
    end

    # 2. join the shots with xfade transitions
    if shots.size == 1
      graph << "[s0]null[vjoin]"
    else
      current = "[s0]"
      cursor = 0.0
      shots.each_with_index do |shot, index|
        cursor += shot.fetch("duration").to_f
        break if index == shots.size - 1

        transition = transitions[index]
        length = transition.fetch("cut") ? 0.12 : transition.fetch("duration").to_f
        cursor -= length
        label = index == shots.size - 2 ? "[vjoin]" : "[x#{index}]"
        graph << "#{current}[s#{index + 1}]xfade=transition=#{transition.fetch('type')}:duration=#{fmt(length)}:offset=#{fmt(cursor)}#{label}"
        current = label
      end
    end

    # 3. the animated typographic cards
    card_chains(graph, cards)

    current = "[vjoin]"
    cards.each_with_index do |card, index|
      start_t = card.fetch("start").to_f
      end_t = start_t + card.fetch("duration").to_f
      label = index == cards.size - 1 ? "[composited]" : "[o#{index}]"
      graph << "#{current}[c#{index}]overlay=#{overlay_expr(card)}:eval=frame:enable='between(t,#{fmt(start_t)},#{fmt(end_t)})'#{label}"
      current = label
    end
    current = "[vjoin]" if cards.empty?

    # 4. output size
    if [ @out_w, @out_h ] == [ BASE_W, BASE_H ]
      graph << "#{current}format=yuv420p[vout]"
    else
      graph << "#{current}scale=#{@out_w}:#{@out_h},format=yuv420p[vout]"
    end

    # 5. music + sound effects (leaves the chain on @audio_label)
    @audio_line_start = graph.size
    build_audio_chain(graph, duration, music_path, events, cards.size)

    [ inputs, graph ]
  end

  def shot_filter(shot, pan: true)
    grade = shot.fetch("grade")
    d = fmt(shot.fetch("duration"))
    z0 = fmt(shot.dig("zoom", "from"))
    z1 = fmt(shot.dig("zoom", "to"))

    chain = []
    # the bundled clips are already 1280x720; normalise the geometry and do
    # every filter at the final size (much cheaper, same visual result)
    chain << "scale=#{BASE_W}:#{BASE_H}:force_original_aspect_ratio=increase"
    chain << "crop=#{BASE_W}:#{BASE_H}"
    chain << "fps=#{FPS}"
    chain << "trim=duration=#{d}"
    chain << "setpts=PTS-STARTPTS"
    chain << "tpad=stop_mode=clone:stop_duration=0.12"
    chain << "eq=#{grade.fetch('eq')}"
    chain << "colorbalance=#{grade.fetch('balance')}"
    chain << "hue=h=#{grade.fetch('hue')}"

    if pan
      # Ken Burns move. crop evaluates its w/h at configuration time, where
      # the frame timestamp is not available, so the move is done with
      # zoompan, which evaluates its expressions per output frame.
      frames = [ (shot.fetch("duration").to_f * FPS).round, 2 ].max
      move = shot.fetch("pan")
      p0 = fmt(move.fetch("from"))
      p1 = fmt(move.fetch("to"))
      zoom = "(#{z0}+(#{z1}-#{z0})*on/#{frames})"
      progress = "(#{p0}+(#{p1}-#{p0})*on/#{frames})"
      if move.fetch("axis") == "x"
        x = "(iw-iw/(#{zoom}))*min(max(#{progress},0),1)"
        y = "(ih-ih/(#{zoom}))*0.5"
      else
        x = "(iw-iw/(#{zoom}))*0.5"
        y = "(ih-ih/(#{zoom}))*min(max(#{progress},0),1)"
      end
      chain << "zoompan=z='#{zoom}':x='#{x}':y='#{y}':d=1:s=#{BASE_W}x#{BASE_H}:fps=#{FPS}"
    end

    # grain and vignette on top of the camera move
    chain << "vignette=a=PI/#{fmt(shot.fetch('vignette'))}"
    chain << "noise=alls=#{shot.fetch('grain')}:allf=t+u"
    chain << "format=yuv420p"
    chain.join(",")
  end

  def card_chains(graph, cards)
    cards.each_with_index do |card, index|
      start_t = card.fetch("start").to_f
      dur = card.fetch("duration").to_f
      transform = card_transform(card, dur)
      chain = [ "loop=loop=-1:size=1", "fps=#{FPS}", "format=rgba" ]
      chain << transform[:filter] if transform[:filter]
      chain << "scale=#{BASE_W}:#{BASE_H}" unless transform[:final_size]
      chain << card_rotate_expr(card, start_t) if card.fetch("style") == "rotate_settle"
      in_dur = card["style"] == "flash_pop" ? 0.06 : 0.32
      chain << "fade=t=in:st=#{fmt(start_t)}:d=#{fmt(in_dur)}:alpha=1"
      chain << "fade=t=out:st=#{fmt([ start_t + dur - 0.34, start_t ].max)}:d=0.34:alpha=1"
      graph << "[#{cards.size + index}:v]#{chain.join(',')}[c#{index}]"
    end
  end

  # Card animation. Like the shots, the animated sizing is done with
  # zoompan (per output frame) because crop's w/h are evaluated once, at
  # filter configuration time, when no frame timestamp exists yet. The
  # `pan` style only animates crop's x, which is evaluated per frame.
  ZOOM_CARD_STYLES = {
    "zoom_punch"   => { from: 1.30, to: 1.00, over: 0.55, fy: 0.42 },
    "flash_pop"    => { from: 1.16, to: 1.00, over: 0.35, fy: 0.45 },
    "split_reveal" => { from: 1.45, to: 1.00, over: 0.50, fy: 0.45 },
    "scale_out"    => { from: 1.00, to: 1.13, over: 99.0, fy: 0.45 }
  }.freeze

  def card_transform(card, dur)
    style = card.fetch("style")
    frames = [ (dur * FPS).round, 2 ].max
    preset = ZOOM_CARD_STYLES[style]

    if preset
      over_frames = [ (preset[:over] * FPS).round, 1 ].max
      p = "(min(max(on/#{over_frames},0),1))"
      zoom = "(#{fmt(preset[:from])}+(#{fmt(preset[:to])}-#{fmt(preset[:from])})*#{p})"
      x = "(iw-iw/(#{zoom}))*0.5"
      y = "(ih-ih/(#{zoom}))*#{fmt(preset[:fy])}"
      { filter: "zoompan=z='#{zoom}':x='#{x}':y='#{y}':d=1:s=#{BASE_W}x#{BASE_H}:fps=#{FPS}", final_size: true }
    elsif style == "pan"
      # slow horizontal travel across a zoomed in title
      zoom = fmt(1.55)
      p = "(min(max(on/#{frames},0),1))"
      x = "(iw-iw/(#{zoom}))*#{p}"
      y = "(ih-ih/(#{zoom}))*0.5"
      { filter: "zoompan=z='#{zoom}':x='#{x}':y='#{y}':d=1:s=#{BASE_W}x#{BASE_H}:fps=#{FPS}", final_size: true }
    else
      { filter: nil, final_size: PNG_W == BASE_W && PNG_H == BASE_H }
    end
  end

  def card_rotate_expr(card, start_t)
    local = "(t-#{fmt(start_t)})"
    "rotate=a='(6.5*(1-min(max(#{local}/0.7,0),1)))*PI/180':ow=iw:oh=ih:fillcolor=none"
  end

  def overlay_expr(card)
    start_t = card.fetch("start").to_f
    local = "(t-#{fmt(start_t)})"

    case card.fetch("style")
    when "slide_up"
      p = "(min(max(#{local}/0.45,0),1))"
      "x='0':y='#{fmt(BASE_H * 0.10)}*(1-#{p})'"
    when "drop_in"
      p = "(min(max(#{local}/0.5,0),1))"
      ease = "(1-pow(1-#{p},3))"
      "x='0':y='-(1-#{ease})*#{fmt(BASE_H * 0.16)}'"
    when "rise_fade"
      p = "(min(max(#{local}/#{fmt(card.fetch('duration'))},0),1))"
      "x='0':y='#{fmt(BASE_H * 0.06)}*(1-#{p})'"
    when "slide_left"
      p = "(min(max(#{local}/0.45,0),1))"
      "x='#{fmt(BASE_W * 0.14)}*(1-#{p})':y='0'"
    when "sway"
      # a slow drift back and forth across the frame
      p = "(min(max(#{local}/#{fmt(card.fetch('duration'))},0),1))"
      "x='#{fmt(BASE_W * 0.035)}*(1-2*#{p})':y='0'"
    when "bob"
      p = "(min(max(#{local}/#{fmt(card.fetch('duration'))},0),1))"
      "x='0':y='#{fmt(BASE_H * 0.03)}*(1-2*#{p})'"
    when "truck"
      # enters from the left, keeps sliding after it lands
      p = "(min(max(#{local}/0.5,0),1))"
      rest = "(max(#{local}-0.5,0)*#{fmt(BASE_W * 0.012)})"
      "x='-(1-#{p})*#{fmt(BASE_W * 0.18)}+#{rest}':y='0'"
    else
      "x='0':y='0'"
    end
  end

  # ------------------------------------------------------------------ audio --

  def build_audio_chain(graph, duration, music_path, events, card_count)
    audio = plan.fetch("audio")
    base = plan.fetch("shots").size + card_count
    streams = []

    if music_path
      graph << "[#{base}:a]atrim=0:#{fmt(duration)},asetpts=PTS-STARTPTS,volume=#{fmt(audio.fetch('music_gain'))}," \
               "afade=t=in:st=0:d=0.4,afade=t=out:st=#{fmt([ duration - 0.9, 0 ].max)}:d=0.9[mus]"
      streams << "[mus]"
    end

    events.each_with_index do |event, i|
      index = base + (music_path ? 1 : 0) + i
      ms = (event.fetch("at").to_f * 1000).round
      tone = SFX_TONE[event.fetch("type")]
      graph << "[#{index}:a]atrim=0:2.5,asetpts=PTS-STARTPTS,volume=#{fmt(event.fetch('gain', 0.5))}#{tone}," \
               "adelay=#{ms}:all=1[sfx#{i}]"
      streams << "[sfx#{i}]"
    end

    # The chain ends on a label, not on the final shaping: the render first
    # measures this mix in a separate audio-only pass and only then applies
    # the (static) gain and the limiter.
    if streams.size > 1
      graph << "#{streams.join}amix=inputs=#{streams.size}:duration=first:normalize=0[mix]"
      @audio_label = "mix"
    elsif streams.size == 1
      @audio_label = streams.first[/\[([^\]]+)\]/, 1]
    else
      graph << "anullsrc=r=44100:cl=stereo[mix]"
      @audio_label = "mix"
    end
  end

  # Noise based effects (reverse cymbal, whooshes) are exactly what a
  # listener describes as a rustling / hissing sound, and normalisation makes
  # them louder than they were recorded: a gentle low-pass over their top end
  # keeps the mix clean without changing their rhythm or weight.
  SFX_TONE = {
    "revcym" => ",lowpass=f=6500",
    "whoosh" => ",lowpass=f=8000",
    "whoosh_rev" => ",lowpass=f=8000"
  }.freeze

  TARGET_LUFS = -16.0
  TARGET_TP = -1.5
  # The brickwall limiter may have to absorb this much of the loudest
  # transients; everything else is reached with plain, constant gain.
  LIMITER_ALLOWANCE = 3.0

  # Final shaping of the mix.
  #
  # The loudness of the mix is corrected with ONE constant gain factor, taken
  # from a measurement pass - not by loudnorm's own normaliser, whose dynamic
  # (per frame) gain pumped the quiet passages up and made the noise floors
  # and cymbal swells swell with them. A static factor cannot breathe: quiet
  # stays proportionally quiet.
  def audio_sanitize(gain)
    chain = "highpass=f=28,treble=g=-3:f=9000:width_type=o:w=1"
    chain +=
      if gain
        ",volume=#{fmt(gain)}"
      else
        ",loudnorm=I=-16:TP=-1.5:LRA=11" # probe failed: fall back to the old behaviour
      end
    # Real headroom, so the AAC encode never clips to 0 dBFS: 0.80 is a bit
    # below the -1.5 dBTP target, because the encoder overshoots peaks.
    "#{chain},alimiter=level=0:limit=0.80"
  end

  # dB of constant gain that reaches TARGET_LUFS without pushing peaks past
  # what the limiter should handle. nil when the probe failed.
  def static_gain(measured)
    return nil if measured.nil?

    wanted = TARGET_LUFS - measured.fetch("i")
    headroom = TARGET_TP - measured.fetch("tp") + LIMITER_ALLOWANCE
    db = [ wanted, headroom ].min.clamp(-24.0, 18.0)
    10 ** (db / 20.0)
  end

  # Loudness probe of the mix: loudnorm's JSON output reports the integrated
  # loudness and the true peak, which is all the static gain needs.
  #
  # Only the audio tail of the graph is replayed (see build_graph): mapping
  # nothing for the video output makes ffmpeg abort with "unconnected
  # output", and decoding the video again here would double the render time.
  def measure_mix(inputs, lines)
    return nil if @audio_label.nil?

    argv = inputs[@audio_argv_start..] || []
    argv = [ "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo" ] if argv.empty?
    video_inputs = @video_inputs.to_i
    audio_lines = (lines[@audio_line_start..] || []).map do |line|
      line.gsub(/\[(\d+):a\]/) { "[#{Regexp.last_match(1).to_i - video_inputs}:a]" }
    end

    chain = "[#{@audio_label}]loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json[ameas]"
    text = run_capture!([
      ffmpeg, "-hide_banner", "-loglevel", "info", "-nostats",
      *argv,
      "-filter_complex", (audio_lines + [ chain ]).join(";"),
      "-map", "[ameas]", "-f", "null", "-"
    ])
    blob = text[/\{[^{}]*"input_i"[^{}]*\}/m]
    raise RenderError, "loudnorm printed no measurements" if blob.nil?

    data = JSON.parse(blob)
    { "i" => data.fetch("input_i").to_f, "tp" => data.fetch("input_tp").to_f }
  rescue StandardError => e
    Rails.logger.warn("[trailer] loudness probe failed: #{e.class}: #{e.message}")
    nil
  end

  def sfx_path(type)
    MediaLibrary.sfx[type.to_s]
  end

  # --------------------------------------------------------------- helpers ---

  # Which shot is on screen at +time+ and how far into it we are.
  def shot_at(time)
    cursor = 0.0
    shots = plan.fetch("shots")
    transitions = plan.fetch("transitions")
    shots.each_with_index do |shot, index|
      length = shot.fetch("duration").to_f
      return [ shot, time - cursor ] if time < cursor + length

      cursor += length
      cursor -= transitions[index].fetch("duration").to_f if transitions[index]
    end
    [ shots.last, 0.0 ]
  end

  def ffmpeg
    FfmpegLocator.ffmpeg || raise(RenderError, "ffmpeg was not found on this machine")
  end

  def fmt(value)
    format("%.4f", value.to_f).sub(/0+\z/, "").sub(/\.\z/, ".0")
  end

  # Runs ffmpeg without writing a file (loudness probes) and returns its
  # stderr, where loudnorm prints its measurements. Guarded by the same hard
  # timeout as run!.
  def run_capture!(cmd)
    if ENV["MS_LOG_CMD"]
      File.write(Rails.root.join("tmp", "last_ffmpeg_cmd.txt"), cmd.map { |a| a.include?(" ") ? a.inspect : a }.join(" "))
    end

    status = nil
    stderr_text = +""
    timed_out = false

    Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thr|
      stdin.close
      out_reader = Thread.new { stdout.read.to_s }
      err_reader = Thread.new { stderr.read.to_s }

      unless wait_thr.join(self.class::FFMPEG_TIMEOUT)
        timed_out = true
        begin
          Process.kill("KILL", wait_thr.pid)
        rescue StandardError # already gone
          nil
        end
        wait_thr.join(10)
      end

      status = wait_thr.value unless timed_out
      stderr_text = err_reader.value.to_s
      out_reader.value
    end

    if timed_out
      raise RenderError, "ffmpeg probe did not finish within #{self.class::FFMPEG_TIMEOUT}s and was killed"
    end

    raise RenderError,
          "ffmpeg probe exited with #{status&.exitstatus}: #{stderr_text.lines.last(3).join(' ').strip[0, 300]}" unless status&.success?

    stderr_text
  end

  def run!(cmd, output, chdir: nil)
    opts = {}
    opts[:chdir] = chdir if chdir
    # development aid: dump the exact ffmpeg invocation for inspection
    if ENV["MS_LOG_CMD"]
      File.write(Rails.root.join("tmp", "last_ffmpeg_cmd.txt"), cmd.map { |a| a.include?(" ") ? a.inspect : a }.join(" "))
    end

    status = nil
    stderr_text = +""
    timed_out = false

    Open3.popen3(*cmd, **opts) do |stdin, stdout, stderr, wait_thr|
      stdin.close
      # drain both pipes so a chatty child can never block on a full buffer
      out_reader = Thread.new { stdout.read.to_s }
      err_reader = Thread.new { stderr.read.to_s }

      unless wait_thr.join(self.class::FFMPEG_TIMEOUT)
        timed_out = true
        begin
          Process.kill("KILL", wait_thr.pid)
        rescue StandardError # already gone
          nil
        end
        wait_thr.join(10)
      end

      status = wait_thr.value unless timed_out
      stderr_text = err_reader.value.to_s
      out_reader.value
    end

    if timed_out
      FileUtils.rm_f(output)
      raise RenderError, "ffmpeg did not finish within #{self.class::FFMPEG_TIMEOUT}s and was killed"
    end

    return if status.success? && File.exist?(output) && File.size(output).positive?

    # never leave a half-written file behind - it would be served as "ready"
    FileUtils.rm_f(output)
    raise RenderError, "ffmpeg failed (#{status.exitstatus}): #{stderr_text}"
  end
end
