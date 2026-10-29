module Api
  class TrailersController < BaseController
    include MediaStreaming

    # A single poster frame renders in ~0.2 s. The endpoint waits for at most
    # this long so a warm (or just-rendered) poster still answers in one
    # request; after that it fails fast with Retry-After instead of pinning a
    # worker thread while twenty images are being rendered.
    POSTER_WAIT = 0.8

    # Freeze frame of the trailer with the movie title rendered onto it.
    #
    # `w` selects a downscaled variant (160 = table thumb, 640 = cards and the
    # detail panel); without it the full 1280 px frame is served.
    def poster
      plan = trailer_plan
      width = variant_width
      path = TrailerRenderer.poster_path(plan, width)
      full = TrailerRenderer.poster_path(plan)

      unless ready?(path) || (width && ready?(full))
        TrailerRenderer.request_poster(plan)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + POSTER_WAIT
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          break if ready?(full) || ready?(path)

          sleep 0.05
        end
      end

      # The full frame landed: scale it down once, then the variant is a
      # plain cached file like any other.
      path = TrailerRenderer.poster_variant(plan, width) if width && !ready?(path) && ready?(full)

      if ready?(path)
        # The URL is keyed by the trailer plan, so the bytes behind it never
        # change: the browser can keep the frame for a week.
        send_media(path, "image/jpeg", filename: "poster.jpg",
                   cache_control: "public, max-age=604800, immutable")
      else
        response.set_header("Retry-After", "1")
        head :service_unavailable
      end
    end

    # The rendered trailer itself. Rendering happens in the background; the
    # first request answers 202 and the client polls this endpoint.
    def video
      state = TrailerRenderer.request_video(trailer_plan, quality)

      if state["state"] == "ready"
        path = TrailerRenderer.video_path(trailer_plan, quality)
        send_media(path, "video/mp4", filename: "trailer.mp4")
      else
        render json: { "state" => state["state"], "render" => TrailerRenderer.stats }
      end
    end

    def status
      render json: {
        "state" => TrailerRenderer.video_state(trailer_plan, quality),
        "render" => TrailerRenderer.stats
      }
    end

    # Debug helper: the whole plan as JSON (handy when tuning trailers).
    def plan
      render json: trailer_plan
    end

    private

    # nil = full 1280 px frame; 160 / 640 = a downscaled variant.
    def variant_width
      width = params[:w].to_i
      TrailerRenderer::POSTER_WIDTHS.include?(width) ? width : nil
    end

    def ready?(path)
      path && path.exist? && path.size.positive?
    end
  end
end
