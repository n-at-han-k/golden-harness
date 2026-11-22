#!/usr/bin/env ruby
#
# Copyright (C) by Klaas Freitag <freitag@owncloud.com>
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

require_relative "gui/connectionvalidator"

require_relative "gui/fetchserversettings"
require_relative "gui/networkinformation"
require_relative "libsync/account"
require_relative "libsync/creds/abstractcredentials"
require_relative "libsync/networkjobs"
require_relative "libsync/networkjobs/checkserverjobfactory"
require_relative "libsync/networkjobs/jsonjob"

require "qjsonobject"
require "qloggingcategory"
require "qnetworkproxyfactory"
require "qnetworkreply"
require "qtconcurrent/qtconcurrentrun"

include std::chrono_literals
include Qt::Literals::StringLiterals

module OCC
  class ConnectionValidator
    def initialize(account, parent)
      super(parent)
      @account = account
      timer = QTimer.new(this)
      timer.set_single_shot(true)
      timer.set_interval(60)

      connect(timer, QTimer.timeout, this) do
        Log.warn("sync.connectionvalidator") { "ConnectionValidator for #{@account.display_name_with_host} timed out after #{@duration}" }
        @errors.append("timeout")
        report_result(:timeout)
      end

      timer.start
    end

    def fetch_settings_timeout
      return min(20, OCC::AbstractNetworkJob.http_timeout)
    end

    def set_clear_cookies(clear_cookies)
      @clear_cookies = clear_cookies
    end

    def check_server(mode)
      @mode = mode
      Log.debug("sync.connectionvalidator") { "Checking server and authentication" }
      check_server_factory = CheckServerJobFactory.create_from_account(@account, @clear_cookies, this)
      check_server_job = check_server_factory.start_job(@account.url, this)

      connect(check_server_job.reply.manager, AccessManager.ssl_errors, this) do |reply, errors|
        ssl_errors(errors)
      end

      connect(check_server_job, CoreJob.finished, this) do
        if check_server_job.success
          result = check_server_job.result.value < CheckServerJobResult >
            @account.access_manager.set_cookie_jar(check_server_job.reply.manager.cookie_jar)

          slot_status_found(result.server_url, result.status_object)
        else
          case check_server_job.reply.error
          when :operation_canceled_error, :timeout_error
            Log.warn("sync.connectionvalidator") { "#{check_server_job}" }
            @errors.append("timeout")
            report_result(:timeout)

            return
          when :ssl_handshake_failed_error
            if NetworkInformation.instance.is_behind_captive_portal
              report_result(:captive_portal)
            else
              report_result(:ssl_error)
            end

            return
          when :too_many_redirects_error
            report_result(:status_not_found)

            return
          end

          @account.credentials.check_credentials(check_server_job.reply)
          @errors.append(check_server_job.error_message)
          report_result(:status_not_found)
        end
      end
    end

    def slot_status_found(url, info)
      Log.info("sync.connectionvalidator") { "** Application: OpenCloud found:  #{url}  with version  #{info.value("productversion").to_string}" }

      if @account.url != url
        if Utility.url_equal(@account.url, url)
          Log.info("sync.connectionvalidator") { "status.php was redirected to #{url.to_string} updating the account url" }
          @account.set_url(url)
        else
          Log.info("sync.connectionvalidator") { "status.php was redirected to #{url.to_string} asking user to accept and abort for now" }
          @account.request_url_update(url)
          report_result(:status_not_found)

          return
        end
      end

      creds = @account.credentials

      if !creds.ready
        report_result(:credentials_not_ready)

        return
      end

      if @mode != :validate_server
        user_job = JsonJob.new(@account, @account.url, "graph/v1.0/me", "GET", nil)
        user_job.set_authentication_job(true)
        user_job.set_timeout(fetch_settings_timeout)

        connect(user_job, JsonApiJob.finished_signal, this) do
          if user_job.timed_out
            report_result(:timeout)
          elsif user_job.http_status_code == 200
            report_result(:connected)
          elsif user_job.http_status_code == 401
            report_result(:credentials_wrong)
          elsif user_job.http_status_code == 503
            report_result(:service_unavailable)
          elsif user_job.reply.error == :ssl_handshake_failed_error
            if NetworkInformation.instance.is_behind_captive_portal
              report_result(:captive_portal)
            else
              report_result(:ssl_error)
            end
          else
            report_result(:undefined)
          end
        end

        user_job.start

        return
      else
        report_result(:connected)
      end
    end

    def report_result(status)
      if !@finished
        @finished = true
        Log.debug("sync.connectionvalidator") { "#{status} #{@duration}" }
        connection_result(status, @errors)
        delete_later
      end
    end
  end
end
