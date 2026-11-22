#!/usr/bin/env ruby

require_relative "libsync/networkjobs/getfilejob"

require_relative "libsync/owncloudpropagator_p"

include OCC

class GETFileJob
  def initialize(account, url, path, device, headers, expected_etag_for_resume, resume_start, parent)
    super(account, url, path, parent)
    @device = device
    @headers = headers
    @expected_etag_for_resume = expected_etag_for_resume
    @expected_content_length = -1
    @content_length = -1
    @resume_start = resume_start

    connect(this, GETFileJob.network_error, this) do
      if timed_out
        Log.warn("sync.networkjob.get") { "#{this} timeout" }
        @error_string = "Connection Timeout"
        @error_status = :fatal_error
      end
    end

    set_priority(:low_priority)
  end

  def start
    if @resume_start > 0
      @headers["Range"] = "bytes=" + QByteArray.number(@resume_start) + "-"
      @headers["Accept-Ranges"] = "bytes"
      Log.debug("sync.networkjob.get") { "Retry with range  #{@headers["Range"]}" }
    end

    req = QNetworkRequest.new
    it = @headers.cbegin

    while it != @headers.cend
      req.set_raw_header(it.key, it.value)
      it += 1
    end

    if @bandwidth_manager
      req.set_attribute(:http2_allowed_attribute, false)
    end

    send_request("GET", req)
    Log.debug("sync.networkjob.get") { "#{@bandwidth_manager} #{@bandwidth_choked} #{@bandwidth_limited}" }

    if @bandwidth_manager
      @bandwidth_manager.register_download_job(this)
    end

    AbstractNetworkJob.start
  end

  def finished
    if @bandwidth_manager
      @bandwidth_manager.unregister_download_job(this)
    end

    if reply.bytes_available && @http_ok
      slot_ready_read

      unless !reply.bytes_available
        raise
      end
    end

    @device.close
  end

  def new_reply_hook(reply)
    if @bandwidth_manager
      reply.set_read_buffer_size(16 * 1024)
    end

    connect(reply, QNetworkReply.meta_data_changed, this, GETFileJob.slot_meta_data_changed)
    connect(reply, QNetworkReply.finished, this, GETFileJob.slot_ready_read)
    connect(reply, QNetworkReply.download_progress, this, GETFileJob.download_progress)
  end

  def slot_meta_data_changed
    if @bandwidth_manager
      reply.set_read_buffer_size(16 * 1024)
    end

    http_status = reply.attribute(:http_status_code_attribute).to_int

    if (
      http_status == 301 ||
      http_status == 302 ||
      http_status == 303 ||
      http_status == 307 ||
      http_status == 308 ||
      http_status == 401
    )
      disconnect(reply, QNetworkReply.finished, this, GETFileJob.slot_ready_read)
      disconnect(reply, QNetworkReply.ready_read, this, GETFileJob.slot_ready_read)

      return
    end

    if http_status / 100 != 2
      if @bandwidth_manager
        reply.set_read_buffer_size(0)
      end

      return
    end

    if reply.error != :no_error
      return
    end

    @etag = get_etag_from_reply(reply)

    if @etag.is_empty
      Log.warn("sync.networkjob.get") { "No E-Tag reply by server, considering it invalid" }
      @error_string = "No E-Tag received from server, check Proxy/Gateway"
      @error_status = :normal_error
      abort

      return
    elsif (
      !@expected_etag_for_resume.is_empty &&
      @expected_etag_for_resume != @etag
    )
      Log.warn("sync.networkjob.get") { "We received a different E-Tag for resuming! #{@expected_etag_for_resume} vs #{@etag}" }
      @error_string = "We received a different E-Tag for resuming. Retrying next time."
      @error_status = :normal_error
      abort

      return
    end

    ok = false
    @content_length = reply.header(:content_length_header).to_long_long(ok)

    if (
      ok &&
      @expected_content_length != -1 &&
      @content_length != @expected_content_length
    )
      Log.warn("sync.networkjob.get") { "We received a different content length than expected! #{@expected_content_length} vs #{@content_length}" }
      @error_string = "We received an unexpected download Content-Length."
      @error_status = :normal_error
      abort

      return
    end

    start = 0
    ranges = QString.from_utf8(reply.raw_header("Content-Range"))

    if !ranges.is_empty
      rx = QRegularExpression.new("bytes (\\d+)-")
      match = rx.match(ranges)

      if match.has_match
        start = match.captured(1).to_long_long
      end
    end

    if start != @resume_start
      Log.warn("sync.networkjob.get") { "Wrong content-range:  #{ranges}  while expecting start was #{@resume_start}" }

      if ranges.is_empty
        @device.close

        if !@device.open(:write_only)
          @error_string = @device.error_string
          @error_status = :normal_error
          abort

          return
        end

        @resume_start = 0
      else
        @error_string = "Server returned wrong content-range"
        @error_status = :normal_error
        abort

        return
      end
    end

    last_modified = reply.header(:last_modified_header)

    if !last_modified.is_null
      @last_modified = Utility.q_date_time_to_time_t(last_modified.to_date_time)
    end

    @http_ok = true
    connect(reply, QIODevice.ready_read, this, GETFileJob.slot_ready_read)
  end

  def set_bandwidth_manager(bwm)
    @bandwidth_manager = bwm
  end

  def set_choked(c)
    if c != @bandwidth_choked
      @bandwidth_choked = c
      QMetaObject.invoke_method(this, GETFileJob.slot_ready_read, :queued_connection)
    end
  end

  def set_bandwidth_limited(b)
    if @bandwidth_limited != b
      @bandwidth_limited = b
      QMetaObject.invoke_method(this, GETFileJob.slot_ready_read, :queued_connection)
    end
  end

  def give_bandwidth_quota(q)
    @bandwidth_quota = q
    Log.debug("sync.networkjob.get") { "Got #{q} bytes" }
    QMetaObject.invoke_method(this, GETFileJob.slot_ready_read, :queued_connection)
  end

  def current_download_position
    if @device && @device.pos > 0 && @device.pos > @resume_start
      return @device.pos
    end

    return @resume_start
  end

  def slot_ready_read
    unless reply
      raise
    end

    if !@http_ok
      return
    end

    buffer_size = min(1024 * 8, reply.bytes_available)
    buffer = QByteArray.new(buffer_size, :uninitialized)

    while reply.bytes_available > 0
      if @bandwidth_choked
        Log.warn("sync.networkjob.get") { "Download choked" }

        break
      end

      to_read = buffer_size

      if @bandwidth_limited
        to_read = min(buffer_size, @bandwidth_quota)

        if to_read == 0
          Log.warn("sync.networkjob.get") { "Out of bandwidth quota" }

          break
        end

        @bandwidth_quota -= to_read
      end

      read = reply.read(buffer.data, to_read)

      if read < 0
        @error_string = network_reply_error_string(reply)
        @error_status = :normal_error
        Log.warn("sync.networkjob.get") { "Error while reading from device:  #{@error_string}" }
        abort

        return
      end

      written = @device.write(buffer.const_data, read)

      if written != read
        @error_string = @device.error_string
        @error_status = :normal_error
        Log.warn("sync.networkjob.get") { "Error while writing to file #{written} #{read} #{@error_string}" }
        abort

        return
      end
    end
  end

  def finalize
    if @bandwidth_manager
      @bandwidth_manager.unregister_download_job(this)
    end
  end

  def error_string
    if !@error_string.is_empty
      return @error_string
    end

    return AbstractNetworkJob.error_string
  end
end
