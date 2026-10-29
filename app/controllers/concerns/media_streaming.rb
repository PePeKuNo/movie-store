# Sends a local file while honouring HTTP Range requests so that the browser
# can seek inside the trailer <video>. Files here are 1-3 MB, so buffering is
# cheaper than a streaming stack.
module MediaStreaming
  extend ActiveSupport::Concern

  private

  def send_media(path, type, filename: nil, cache: true, cache_control: nil)
    raise ActionController::MissingFile, path unless File.exist?(path)

    payload = File.binread(path)
    total = payload.bytesize

    response.headers["Accept-Ranges"] = "bytes"
    response.headers["Content-Disposition"] = "inline"
    response.headers["Cache-Control"] =
      if cache_control then cache_control
      elsif cache then "public, max-age=86400"
      else "no-store"
      end
    response.headers["Content-Disposition"] = %(inline; filename="#{filename}") if filename

    range = request.headers["HTTP_RANGE"].to_s
    if range =~ /\Abytes=(\d*)-(\d*)\z/
      first = Regexp.last_match(1).empty? ? total - Regexp.last_match(2).to_i : Regexp.last_match(1).to_i
      last = Regexp.last_match(2).empty? ? total - 1 : Regexp.last_match(2).to_i
      first = 0 if first.negative?
      last = total - 1 if last >= total

      if first > last || first >= total
        response.headers["Content-Range"] = "bytes */#{total}"
        head :requested_range_not_satisfiable and return
      end

      response.headers["Content-Range"] = "bytes #{first}-#{last}/#{total}"
      response.headers["Content-Length"] = (last - first + 1).to_s
      render body: payload[first..last], content_type: type, status: :partial_content
    else
      response.headers["Content-Length"] = total.to_s
      render body: payload, content_type: type, status: :ok
    end
  end
end
