require "zip"

module Api
  # Optional requirement: a ZIP archive holding one video file per movie of
  # the current table page, named after the movie title.
  #
  # The missing trailers are rendered by the shared background queue (the
  # same one the browser uses), and this request only waits for them, so an
  # export never hogs a worker thread running ffmpeg - and because the queue
  # works on several trailers at once, a whole page arrives in about half the
  # time a serial render would take.
  class ExportController < BaseController
    INVALID_FILENAME = /[\\\/:\*\?"<>\|\x00-\x1F]/.freeze

    # Upper bound on how long we are willing to wait for the queue. A page of
    # twenty trailers takes ~3.5 min on an 8 core laptop; if anything goes
    # wrong we still return a (smaller) archive instead of hanging forever.
    EXPORT_TIMEOUT = Integer(ENV.fetch("MS_EXPORT_TIMEOUT", "360"))

    # How many trailers of the requested page are already on disk. The client
    # polls this while the download request is working, so the export button
    # can show a real counter instead of minutes of silence (which looked like
    # a dead button).
    def progress
      gen = generator
      gen.page(current_page)
      plans = gen.last_plans || []

      plans.each { |plan| TrailerRenderer.request_video(plan, "ld") }
      ready = plans.count { |plan| finished_video(plan) }

      render json: {
        "page" => current_page,
        "ready" => ready,
        "total" => plans.size,
        "render" => TrailerRenderer.stats
      }
    end

    def index
      gen = generator
      movies = gen.page(current_page)
      paths = render_page(gen.last_plans || [])

      buffer = Zip::OutputStream.write_buffer do |zip|
        used = Hash.new(0)
        movies.each_with_index do |movie, index|
          path = paths[index]
          next unless path

          name = unique_name(movie.fetch("title"), used, current_page, index)
          zip.put_next_entry(name)
          zip.write(File.binread(path))
        end
      end

      buffer.rewind
      filename = "trailers-page-#{current_page}-#{current_region.tag}.zip"
      send_data buffer.read,
                 type: "application/zip",
                 disposition: "attachment",
                 filename: filename
    end

    private

    # Returns one path per plan (nil when a trailer could not be produced).
    def render_page(plans)
      paths = Array.new(plans.size)
      deadline = monotonic + EXPORT_TIMEOUT

      loop do
        missing = []

        plans.each_with_index do |plan, index|
          path = finished_video(plan)
          path ? paths[index] = path : missing << plan
        end
        break if missing.empty?

        if monotonic >= deadline
          Rails.logger.warn("[export] gave up with #{missing.size} trailers still rendering")
          break
        end

        missing.each { |plan| TrailerRenderer.request_video(plan, "ld") }
        sleep 0.4
      end

      paths
    end

    # Reuse an already rendered trailer (any quality); nil while it is still
    # on disk queue.
    def finished_video(plan)
      %w[hd sd ld].each do |candidate|
        path = TrailerRenderer.video_path(plan, candidate)
        return path if path.exist? && path.size.positive?
      end
      nil
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def unique_name(title, used, _page, index)
      base = title.to_s.gsub(INVALID_FILENAME, "_").strip.gsub(/[ ]+\z/, "")
      base = "movie" if base.empty?
      base = base[0, 80]
      used[base] += 1
      suffix = used[base] > 1 ? " (#{used[base]})" : ""
      format("%02d - %s%s.mp4", index + 1, base, suffix)
    end
  end
end
