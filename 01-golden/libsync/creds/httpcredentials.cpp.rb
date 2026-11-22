#!/usr/bin/env ruby
#
# Copyright (C) by Klaas Freitag <freitag@kde.org>
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

require_relative "creds/httpcredentials"

require_relative "accessmanager"
require_relative "account"
require_relative "configfile"
require_relative "creds/credentialmanager"
require_relative "syncengine"

require "qauthenticator"
require "qloggingcategory"
require "qnetworkinformation"
require "qnetworkreply"
require "qtimer"

require "chrono"

require_relative "httpcredentials.moc"

include std::chrono_literals

module OCC
  class HttpCredentials
    TOKEN_REFRESH_MAX_RETRIES = 3
    TOKEN_REFRESH_DEFAULT_TIMEOUT_ONE_ERROR = 30

    HttpCredentialsAccessManager = Struct.new(
      :_cred,
      keyword_init: true
    )
    def initialize(access_token)
      @access_token = access_token
      @ready = true
    end

    def refresh_token_key_c
      return "http/oauthtoken"
    end

    def create_am
      am = HttpCredentialsAccessManager.new(this)
      connect(am, QNetworkAccessManager.authentication_required, this, HttpCredentials.slot_authentication)

      return am
    end

    def ready
      return @ready
    end

    def fetch_from_keychain
      @was_fetched = true

      if @ready
        fetched
      else
        fetch_from_keychain_helper
      end
    end

    def fetch_from_keychain_helper
      job = @account.credential_manager.get(refresh_token_key_c)

      connect(job, CredentialJob.finished, this) do
        handle_error = lambda do
          Log.warn("sync.credentials.http") { "Could not retrieve client password from keychain #{job.error_string}" }

          if job.error != :entry_not_found
            @fetch_error_string = job.error_string
          else
            @fetch_error_string = ""
          end

          @access_token.clear
          @ready = false
          fetched
        end

        if job.error != :no_error
          handle_error.call

          return
        end

        data = job.data.to_string

        if !data.is_empty
          @access_token = data
          @ready = true
          QTimer.single_shot(0, this) { fetched }
        else
          handle_error.call
        end
      end
    end

    def check_credentials(reply)
      if reply.error == :authentication_required_error
        slot_authentication(reply, nil)
      end
    end

    def slot_authentication(reply, _authenticator)
      Log.debug("sync.credentials.http") { "#{__method__} #{reply}" }

      if !@ready
        return
      end

      Log.warn("sync.credentials.http") { "Stop request: Authentication failed for  #{reply.url.to_string} #{reply.request.raw_header("Original-Request-ID")}" }
    end

    def invalidate_token
      Log.warn("sync.credentials.http") { "Invalidating the credentials" }

      if !@access_token.is_empty
        @previous_password = @access_token
      end

      @access_token = ""
      @ready = false
      @account.clear_cookie_jar

      if !@refresh_token.is_empty
        return
      end

      @account.credential_manager.clear("http")
      QTimer.single_shot(0, @account, Account.clear_am_cache)
    end

    def forget_sensitive_data
      @refresh_token.clear
      invalidate_token
      @previous_password.clear
    end

    def persist
      if !@refresh_token.is_empty
        @account.credential_manager.set(refresh_token_key_c, @refresh_token)
      end
    end
  end
end
