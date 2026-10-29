module Api
  class MetaController < BaseController
    # Everything the single page application needs to render its toolbar:
    # the list of regions, the allowed ranges, the UI strings of the current
    # language and the state of the media pipeline.
    def index
      render json: {
        "regions" => RegionRegistry.all.map(&:to_h),
        "defaultRegion" => RegionRegistry.default.tag,
        "defaultSeed" => SeedParser.random.to_s,
        "pageSize" => MovieGenerator::PAGE_SIZE,
        "likes" => { "min" => 0, "max" => 10, "step" => 0.1 },
        "reviews" => { "min" => 0, "max" => 10, "step" => 0.1 },
        "seedBits" => 64,
        "ui" => I18n.t("ui", locale: current_region.tag),
        "capabilities" => {
          "ffmpeg" => FfmpegLocator.available?,
          "export" => FfmpegLocator.available?,
          "series" => true
        },
        "media" => {
          "clips" => MediaLibrary.clips.size,
          "music" => MediaLibrary.music.size,
          "fonts" => MediaLibrary.fonts.size,
          "sfx" => MediaLibrary.sfx.size
        },
        "render" => TrailerRenderer.stats
      }
    end
  end
end
