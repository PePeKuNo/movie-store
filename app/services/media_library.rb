require "json"

# Read-only catalogue of the bundled media used to compose trailers:
#   public/media/clips/  - pre-rendered stock footage (real video, not gradients)
#   public/media/music/  - royalty free music beds
#   public/media/sfx/    - whooshes / impacts / risers
#   public/fonts/        - open fonts used for the typographic animations
class MediaLibrary
  ROOT = Rails.root.join("public", "media")
  FONTS_ROOT = Rails.root.join("public", "fonts")

  class << self
    def clips
      @clips ||= load_clips
    end

    def music
      @music ||= Dir.glob(ROOT.join("music", "music_*.mp3").to_s).sort.select do |path|
        File.size(path).positive?
      end
    end

    def sfx
      @sfx ||= Dir.glob(ROOT.join("sfx", "*.wav").to_s).sort.map do |path|
        [ File.basename(path, ".wav"), path ]
      end.to_h
    end

    def fonts
      @fonts ||= begin
        manifest = FONTS_ROOT.join("manifest.json")
        if manifest.exist?
          JSON.parse(read_json(manifest))
        else
          Dir.glob(FONTS_ROOT.join("*.ttf").to_s).sort.map do |path|
            { "file" => File.basename(path), "family" => File.basename(path, ".ttf"), "weight" => 400, "style" => "normal" }
          end
        end
      end
    end

    # Fonts that should be used for the big typographic title cards.
    def display_fonts
      @display_fonts ||= fonts.select do |font|
        %w[Condensed Narrow Russo Oranienbaum Yeseva Serif].any? do |needle|
          font["file"].include?(needle)
        end
      end
    end

    def clip_path(id)
      ROOT.join("clips", "#{id}.mp4")
    end

    def font_path(file)
      FONTS_ROOT.join(file)
    end

    def ready?
      clips.size >= 8 && music.any?
    end

    def reload!
      @clips = @music = @sfx = @fonts = @display_fonts = nil
    end

    private

    # Some tools write JSON with a UTF-8 BOM, which JSON.parse rejects.
    def read_json(path)
      File.read(path, mode: "r:bom|utf-8")
    end

    def load_clips
      manifest = ROOT.join("clips", "manifest.json")
      entries =
        if manifest.exist?
          JSON.parse(read_json(manifest))
        else
          Dir.glob(ROOT.join("clips", "clip_*.mp4").to_s).sort.map do |path|
            { "id" => File.basename(path, ".mp4"), "file" => File.basename(path), "duration" => 6.0 }
          end
        end

      entries.select { |entry| clip_path(entry.fetch("id")).exist? }
    end
  end
end
