#!/usr/bin/env ruby
#
# Copyright (C) by Klaas Freitag <freitag@owncloud.com>
# Copyright (C) by Daniel Molkentin <danimo@owncloud.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
# for more details.
#

require "qauthenticator"
require "qnetworkrequest"
require "qxmlstreamreader"

require_relative "common/asserts"
require_relative "networkjobs"
require_relative "account"
require_relative "owncloudpropagator"
require_relative "httplogger"

require_relative "creds/abstractcredentials"

include std::chrono
include std::chrono_literals

module OCC
  class AbstractNetworkJob
    MAX_RETRY_COUNT = 5
    HTTP_TIMEOUT = :default_http_timeout
    def initialize(account, base_url, path, parent)
      super(parent)
      @account = account
      @base_url = base_url
      @path = path

      unless account != parent
        raise
      end

      unless base_url.is_valid
        raise
      end
    end

    def base_url
      return @base_url
    end

    def url
      return Utility.concat_url_path(base_url, path, query)
    end

    def set_query(query)
      @query = query
    end

    def query
      return @query
    end

    def set_timeout(sec)
      @timeout = sec
    end

    def set_force_ignore_credential_failure(ignore)
      @force_ignore_credential_failure = ignore
    end

    def ignore_credential_failure
      return @force_ignore_credential_failure || @is_authentication_job
    end

    def reply
      unless @reply
        raise
      end

      return @reply
    end

    def is_authentication_job
      return @is_authentication_job
    end

    def set_authentication_job(b)
      @is_authentication_job = b
    end

    def needs_retry
      if is_authentication_job
        Log.debug("sync.networkjob") { "Not Retry auth job #{this} #{url}" }

        return false
      end

      if retry_count >= MAX_RETRY_COUNT
        Log.debug("sync.networkjob") { "Not Retry too many retries #{retry_count} #{this} #{url}" }

        return false
      end

      reply = this.reply

      if reply
        if !reply.attribute(:redirection_target_attribute).is_null
          return true
        end

        case reply.error
        when :authentication_required_error
          return true
        when :content_re_send_error
          if @reply.attribute(:http2_was_used_attribute).to_bool
            return true
          end
        end
      end

      return false
    end

    def send_request(verb, req, request_body)
      @verb = verb
      @request = req
      @request.set_decompressed_safety_check_threshold(-1)
      @request.set_attribute(:cache_save_control_attribute, @store_in_cache)

      if @cache_load_control.has_value
        @request.set_attribute(:cache_load_control_attribute, @cache_load_control.value)
      end

      if request_body
        @request_body = request_body.release
        @request_body.set_parent(this)
      end

      unless @request.url.is_empty || @request.url == url
        raise
      end

      unless (
        @request.transfer_timeout == 0 ||
        @request.transfer_timeout == @timeout.count
      )
        raise
      end

      @request.set_url(url)
      @request.set_priority(@priority)
      @request.set_transfer_timeout(@timeout)

      if !is_authentication_job && @account.job_queue.enqueue(this)
        return
      end

      reply = @account.send_raw_request(verb, @request.url, @request, @request_body)
      adopt_request(reply)
    end

    def adopt_request(reply)
      std::swap(@reply, reply)

      if reply
        reply.disconnect
        reply.abort
        reply.delete_later
      end

      @request = @reply.request
      connect(@reply, QNetworkReply.finished, this, AbstractNetworkJob.slot_finished)
      new_reply_hook(@reply)
    end

    def slot_finished
      @finished = true
      @account.credentials.check_credentials(@reply)

      if @reply.error != :no_error
        if @account.job_queue.retry(this)
          Log.debug("sync.networkjob") { "Queued: #{this} for retry" }

          return
        end

        if @reply.error == :operation_canceled_error && !@aborted
          @timedout = true
        end

        network_error(@reply)
      end

      @response_timestamp = @reply.raw_header("Date")

      if (
        !reply.attribute(:redirection_target_attribute).is_null &&
        !(
          is_authentication_job ||
          reply.request.has_raw_header("OC-Connection-Validator")
        )
      )
        @account.unknown_connection_state

        Log.warn("sync.networkjob") {
          "#{this} Unsupported redirect on #{@reply.url.to_string} to" \
            "#{reply.attribute(:redirection_target_attribute).to_string}"
        }

        network_error(@reply)

        if @account.job_queue.retry(this)
          Log.warn("sync.networkjob") { "Retry Nr: #{@retry_count} #{@reply.url}" }

          return
        else
          Log.warn("sync.networkjob") { "Don't retry: #{@reply.url}" }
        end
      end

      about_to_finish_signal(AbstractNetworkJob.q_private_signal)
      finished
      finished_signal(AbstractNetworkJob.q_private_signal)
      Log.debug("sync.networkjob") { "Network job finished #{this}" }
      delete_later
    end

    def response_timestamp
      return @response_timestamp
    end

    def response_q_time_stamp
      return Utility.parse_rfc1123_date(QString.from_utf8(response_timestamp))
    end

    def request_id
      if @reply
        return @reply.request.raw_header("X-Request-ID")
      else
        return ""
      end
    end

    def error_string
      if @timedout
        return "Connection timed out"
      elsif !reply
        return "Unknown error: network reply was deleted"
      elsif reply.has_raw_header("OC-ErrorString")
        return QString.from_utf8(reply.raw_header("OC-ErrorString"))
      else
        return network_reply_error_string(reply)
      end
    end

    def error_string_parsing_body(body)
      base = error_string

      if base.is_empty || !reply
        return ""
      end

      reply_body = reply.read_all

      if body
        body = reply_body
      end

      extra = extract_error_message(reply_body)

      if !extra.is_empty && !reply.has_raw_header("OC-ErrorString")
        return "#{base} (#{extra})"
      end

      return base
    end

    def finalize
      if !@finished && !@aborted && !@timedout
        Log.error("sync.networkjob") { "Deleting running job #{request_id}" }
      end

      if @reply
        if @request_body
          @request_body.set_parent(@reply)
        end

        @reply.disconnect(this)
        @reply.abort
        @reply.delete_later
        @reply.clear
      end
    end

    def start
      Log.info("sync.networkjob") { "Created #{this} for #{parent}" }
    end

    def reply_status_string
      unless reply
        raise
      end

      if reply.error == :no_error
        return "OK"
      else
        return "#{Utility.enum_to_string(reply.error)}, #{error_string}"
      end
    end

    def extract_error_message(_error_response)
      reader = QXmlStreamReader.new(error_response)
      reader.read_next_start_element

      if reader.name != "error"
        return ""
      end

      exception = ""

      while !reader.at_end && !reader.has_error
        reader.read_next_start_element

        if reader.name == "message"
          message = reader.read_element_text

          if !message.is_empty
            return message
          end
        elsif reader.name == "exception"
          exception = reader.read_element_text
        end
      end

      return exception
    end

    def error_message(base_error, body)
      msg = base_error
      extra = extract_error_message(body)

      if !extra.is_empty
        msg += " (#{extra})"
      end

      return msg
    end

    def network_reply_error_string(reply)
      base = reply.error_string
      http_status = reply.attribute(:http_status_code_attribute).to_int
      http_reason = reply.attribute(:http_reason_phrase_attribute).to_string

      if (
        http_reason.is_empty ||
        http_status == 0 ||
        !base.contains(http_reason)
      )
        return base
      end

      return AbstractNetworkJob.tr("Server replied \"%1 %2\" to \"%3 %4\"").arg(
        QString.number(http_status),
        http_reason,
        QString.from_latin1(HttpLogger.request_verb(reply)),
        reply.request.url.to_display_string
      )
    end

    def retry
      unless !@verb.is_empty
        raise
      end

      @retry_count += 1
      Log.info("sync.networkjob") { "Restarting #{this} for the #{@retry_count} time" }

      if @request_body
        if !@request_body.is_sequential
          unless @request_body.is_open
            raise
          end

          @request_body.seek(0)
        else
          Log.warn("sync.networkjob") { "Can't resend request, body not suitable #{this}" }
          abort

          return
        end
      end

      send_request(@verb, @request)
    end

    def abort
      if @reply
        @aborted = true
        @reply.abort
      else
        delete_later
      end
    end

    def set_priority(priority)
      @priority = priority
    end

    def priority
      return @priority
    end

    def http_status_code
      return reply.attribute(:http_status_code_attribute).to_int
    end

    def set_store_in_cache(store_in_cache)
      @store_in_cache = store_in_cache
    end

    def set_cache_load_control(cache_load_control)
      @cache_load_control = cache_load_control
    end

    def body
      return @request_body
    end
  end
end

class AbstractNetworkJob
  def to_s(debug)
    saver = QDebugStateSaver.new(debug)
    debug.set_auto_insert_spaces(false)
    debug << job.meta_object.class_name << "(" << job.account.data << ", " << job.url.to_display_string << ", " << job.verb
    reply = job.reply

    if reply
      debug << ", Original-Request-ID: " << reply.request.raw_header("Original-Request-ID") << ", X-Request-ID: " << reply.request.raw_header("X-Request-ID")
      error_string = reply.raw_header("OC-ErrorString")

      if !error_string.is_empty
        debug << ", Error:" << error_string
      end

      if reply.error != :no_error
        debug << ", NetworkError: " << reply.error_string
      end
    end

    if job.timedout
      debug << ", timedout"
    end

    debug << ")"

    return debug.maybe_space
  end
end
