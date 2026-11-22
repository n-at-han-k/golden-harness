#!/usr/bin/env ruby
#
# Copyright (C) Fabian Müller <fmueller@owncloud.com>
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

require_relative "checkserverjobfactory"

require_relative "common/utility"
require_relative "libsync/accessmanager"
require_relative "libsync/account"
require_relative "libsync/cookiejar"
require_relative "libsync/creds/abstractcredentials"

require "qjsonparseerror"

require_relative "checkserverjobfactory.moc"

module OCC
  class CheckServerJobResult
    CheckServerCoreJob = Struct.new(
      :_redirect_distinct,
      keyword_init: true
    )
    def initialize(status_object, server_url)
      @status_object = status_object
      @server_url = server_url
    end

    def status_object
      return @status_object
    end

    def server_url
      return @server_url
    end
  end

  class CheckServerJobFactory
    def create_from_account(account, clear_cookies, parent)
      nam = account.credentials.create_am
      nam.set_custom_trusted_ca_certificates(account.approved_certs)
      nam.set_parent(parent)

      if !clear_cookies
        account_cookies = account.access_manager.open_cloud_cookie_jar.all_cookies
        nam.open_cloud_cookie_jar.set_all_cookies(account_cookies)
      end

      return CheckServerJobFactory.new(nam)
    end

    def start_job(url, parent)
      req = make_request(Utility.concat_url_path(url, "status.php"))
      req.set_attribute(:redirect_policy_attribute, :no_less_safe_redirect_policy)
      req.set_raw_header("OC-Connection-Validator", "desktop")
      req.set_maximum_redirects_allowed(@max_redirects_allowed)
      job = CheckServerCoreJob.new(nam.get(req), parent)

      QObject.connect(job.reply, QNetworkReply.redirected, job) do
        code = job.reply.attribute(:http_status_code_attribute).to_int

        if code == 302 || code == 307
          job.redirect_distinct = false
        end
      end

      server_url = url

      QObject.connect(job.reply, QNetworkReply.finished, job) do
        target_url = job.reply.url.adjusted(:remove_filename)

        if (
          target_url.scheme == "https" &&
          job.reply.ssl_configuration.session_ticket.is_empty &&
          job.reply.error == :no_error
        )
          Log.warn("sync.checkserverjob") { "No SSL session identifier / session ticket is used, this might impact sync performance negatively." }
        end

        if !Utility.url_equal(server_url, target_url)
          if job.redirect_distinct
            server_url = target_url
          else
            Log.warn("sync.checkserverjob") { "We got a temporary moved server aborting" }
            set_job_error(job, "Illegal redirect by server")

            return
          end
        end

        http_status = job.reply.attribute(:http_status_code_attribute).to_int

        if job.reply.error == :too_many_redirects_error
          Log.warn("sync.checkserverjob") { "error: #{job.reply.error_string}" }
          set_job_error(job, job.reply.error_string)
        elsif http_status != 200 || job.reply.bytes_available == 0
          Log.warn("sync.checkserverjob") { "error: status.php replied #{http_status}" }
          set_job_error(job, "Invalid HTTP status code received for status.php: #{http_status}")
        else
          body = job.reply.peek(4 * 1024)
          error = QJsonParseError.new
          status = QJsonDocument.from_json(body, error)

          if error.error != :no_error || status.is_null
            Log.warn("sync.checkserverjob") { "status.php from server is not valid JSON! #{body} #{job.reply.request.url} #{error.error_string}" }
          end

          Log.info("sync.checkserverjob") { "status.php returns:  #{status}   #{job.reply.error}  Reply:  #{job.reply}" }

          if status.object.contains("installed")
            result = CheckServerJobResult.new(status.object, server_url)
            set_job_result(job, QVariant.from_value(result))
          else
            Log.warn("sync.checkserverjob") { "No proper answer on  #{job.reply.url}" }
            set_job_error(job, "Did not receive expected reply from server")
          end
        end
      end

      return job
    end
  end
end
