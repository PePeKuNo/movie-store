require "open3"

# Finds a usable ffmpeg/ffprobe binary. Works out of the box on Windows
# (winget build), Linux and macOS, and honours FFMPEG_PATH / FFPROBE_PATH.
class FfmpegLocator
  WINDOWS_GLOB = File.join(Dir.home, "AppData", "Local", "Microsoft", "WinGet", "Packages",
                            "Gyan.FFmpeg_*", "**", "bin", "ffmpeg.exe").gsub("\\", "/")
  UNIX_CANDIDATES = %w[/usr/bin/ffmpeg /usr/local/bin/ffmpeg /opt/homebrew/bin/ffmpeg /opt/local/bin/ffmpeg].freeze
  WINDOWS_CANDIDATES = %w[C:/ffmpeg/bin/ffmpeg.exe C:/Program Files/ffmpeg/bin/ffmpeg.exe].freeze

  class << self
    def ffmpeg
      @ffmpeg ||= locate("ffmpeg", ENV["FFMPEG_PATH"], [ WINDOWS_GLOB, *UNIX_CANDIDATES, *WINDOWS_CANDIDATES ])
    end

    def ffprobe
      @ffprobe ||= locate("ffprobe", ENV["FFPROBE_PATH"], [ WINDOWS_GLOB.sub("ffmpeg", "ffprobe"), *UNIX_CANDIDATES.map { |p| p.sub("ffmpeg", "ffprobe") } ])
    end

    def available?
      !ffmpeg.nil? && executable?(ffmpeg)
    end

    def reset!
      @ffmpeg = @ffprobe = nil
    end

    private

    def locate(name, override, patterns)
      return override if override && File.exist?(override)

      if executable?(name)
        return name
      end

      patterns.each do |pattern|
        matches = pattern.include?("*") ? Dir.glob(pattern) : [ pattern ]
        matches.each do |candidate|
          next unless File.exist?(candidate)

          return candidate.gsub("\\", "/") if candidate.downcase.end_with?(".exe") || File.executable?(candidate)
        end
      end

      nil
    end

    def executable?(cmd)
      _stdout, _stderr, status = Open3.capture3(cmd, "-version")
      status.success?
    rescue StandardError
      false
    end
  end
end
