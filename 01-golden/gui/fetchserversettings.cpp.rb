#!/usr/bin/env ruby
#
# Copyright (C) by Hannah von Reth <hannah.vonreth@owncloud.com>
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

require_relative "fetchserversettings"

require_relative "gui/accountstate"
require_relative "gui/connectionvalidator"
require_relative "gui/networkinformation"

require_relative "libsync/account"
require_relative "libsync/networkjobs/jsonjob"

require "qimagereader"

include std::chrono_literals
include Qt::Literals::StringLiterals
include OCC

class FetchServerSettingsJob
  def initialize(account, parent)
    super(parent)
    @account = account
  end

  def fetch_settings_timeout
    return min(20, AbstractNetworkJob.http_timeout)
  end

  def start
    job = JsonApiJob.new(@account, "ocs/v2.php/cloud/capabilities", nil, nil, this)
    job.set_timeout(fetch_settings_timeout)

    connect(job, JsonApiJob.finished_signal, this) do
      caps = job.data.value("ocs").to_object.value("data").to_object.value("capabilities").to_object
      Log.info("sync.fetchserversettings") { "Server capabilities #{caps}" }

      if job.ocs_success
        reply = job.reply

        if reply
          @account.set_http2_supported(reply.attribute(:http2_was_used_attribute).to_bool)
        end

        @account.set_capabilities([@account.url, caps.to_variant_map])
        run_async_updates
      end

      finished_signal
    end

    job.start
  end

  def run_async_updates
    account = @account

    (lambda do
      user_job = JsonJob.new(account, account.url, "graph/v1.0/me", "GET", nil)
      user_job.set_timeout(fetch_settings_timeout)

      connect(user_job, JsonApiJob.finished_signal, account.data) do
        if user_job.http_status_code == 200
          account.set_dav_display_name(user_job.data.value("displayName").to_string)
        end
      end

      user_job.start

      if account.capabilities.app_providers.enabled
        json_job = JsonJob.new(account, account.capabilities.app_providers.apps_url, nil, "GET", nil)
        connect(json_job, JsonJob.finished_signal, account.data) { account.set_app_provider(AppProvider.new(json_job.data)) }
        json_job.start
      end

      avatar_job = SimpleNetworkJob.new(account, account.url, "graph/v1.0/me/photo/$value", "GET", nil)

      connect(avatar_job, SimpleNetworkJob.finished_signal, account.data) do
        if avatar_job.http_status_code == 200
          reader = QImageReader.new(avatar_job.reply)
          image = reader.read

          if !image.is_null
            account.set_avatar(QPixmap.from_image(image))
          else
            Log.warn("sync.fetchserversettings") { "Failed to read avatar image: #{reader.error_string}" }
          end
        end
      end

      avatar_job.start
    end).call
  end
end
