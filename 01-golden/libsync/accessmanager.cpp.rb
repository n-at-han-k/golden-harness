#!/usr/bin/env ruby
#
# Copyright (C) by Krzesimir Nowak <krzesimir@endocode.com>
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
require "qnetworkcookie"
require "quuid"

require_relative "accessmanager"
require_relative "common/utility"
require_relative "cookiejar"
require_relative "httplogger"

require "algorithm"

module OCC
  class AccessManager
    def initialize(parent)
      super(parent)
      set_cookie_jar(CookieJar.new)

      connect(this, AccessManager.ssl_errors, this) do |reply, errors|
        filtered = errors

        filtered.erase(std::remove_if(filtered.begin, filtered.end, lambda do |e|
          return !@custom_trusted_ca_certificates.contains(e.certificate)
        end), filtered.end)

        reply.ignore_ssl_errors(filtered)
      end
    end

    def generate_request_id
      return QUuid.create_uuid.to_byte_array(:without_braces)
    end

    def create_request(op, _request, outgoing_data)
      new_request = QNetworkRequest.new(request)
      new_request.set_raw_header("User-Agent", Utility.user_agent_string)
      new_request.set_raw_header("Accept", "*/*")
      new_request.set_raw_header("Accept-Language", QLocale.new.name.to_utf8)

      if new_request.attribute(:redirect_policy_attribute).is_null
        new_request.set_attribute(:redirect_policy_attribute, :manual_redirect_policy)
      end

      verb = new_request.attribute(:custom_verb_attribute).to_byte_array

      if verb == "PROPFIND"
        new_request.set_header(:content_type_header, "text/xml; charset=utf-8")
      end

      request_id = generate_request_id
      new_request.set_raw_header("X-Request-ID", request_id)
      original_id_key = "Original-Request-ID"

      if !new_request.has_raw_header(original_id_key)
        new_request.set_raw_header(original_id_key, request_id)
      end

      use_http2 = lambda do
        if !q_environment_variable_is_set("OPENCLOUD_USE_HTTP2")
          return WITH_HTTP2
        end

        return q_environment_variable_int_value("OPENCLOUD_USE_HTTP2") == 1
      end

      use_http2.call

      if new_request.attribute(:http2_allowed_attribute).to_bool
        new_request.set_attribute(:http2_allowed_attribute, use_http2)
      end

      new_request.set_attribute(:http_pipelining_allowed_attribute, true)
      ssl_configuration = new_request.ssl_configuration
      ssl_configuration.set_ssl_option(:ssl_option_disable_session_tickets, false)
      ssl_configuration.set_ssl_option(:ssl_option_disable_session_sharing, false)
      ssl_configuration.set_ssl_option(:ssl_option_disable_session_persistence, false)

      if !@custom_trusted_ca_certificates.is_empty
        ssl_configuration.add_ca_certificates([@custom_trusted_ca_certificates.begin, @custom_trusted_ca_certificates.end])
      end

      new_request.set_ssl_configuration(ssl_configuration)
      reply = QNetworkAccessManager.create_request(op, new_request, outgoing_data)
      HttpLogger.log_request(reply, op, outgoing_data)

      return reply
    end

    def custom_trusted_ca_certificates
      return @custom_trusted_ca_certificates
    end

    def set_custom_trusted_ca_certificates(certificates)
      @custom_trusted_ca_certificates = certificates
      clear_connection_cache
    end

    def add_custom_trusted_ca_certificates(certificates)
      @custom_trusted_ca_certificates.unite([certificates.begin, certificates.end])
      clear_connection_cache
    end

    def open_cloud_cookie_jar
      jar = qobject_cast < CookieJar > (cookie_jar)

      unless jar
        raise
      end

      return jar
    end

    def filter_ssl_errors(errors)
      filtered = errors

      filtered.erase(std::remove_if(filtered.begin, filtered.end, lambda do |e|
        return (
          e.certificate.is_null ||
          @custom_trusted_ca_certificates.contains(e.certificate)
        )
      end), filtered.end)

      return filtered
    end
  end
end
