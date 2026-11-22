#!/usr/bin/env ruby
#
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

require_relative "accountstate"
require_relative "account"
require_relative "configfile"
require_relative "fetchserversettings"

require_relative "libsync/creds/abstractcredentials"

require_relative "gui/folderman"
require_relative "gui/networkinformation"

require_relative "logger"

require "qrandomgenerator"
require "qsettings"
require "qtimer"

include std::chrono
include std::chrono_literals

module OCC
  class AccountState
    FETCH_SETTINGS_TIMEOUT = (1 * 3600)
    def initialize(account)
      super()
      @account = account
      @queue_guard = @account.job_queue
      @state = :disconnected
      @connection_status = :undefined
      @waiting_for_new_credentials = false
      q_register_meta_type < AccountState > ("AccountState*")
      connect(account.data, Account.invalid_credentials, this, AccountState.slot_invalid_credentials)
      connect(account.data, Account.credentials_fetched, this, AccountState.slot_credentials_fetched)
      connect(account.data, Account.credentials_asked, this, AccountState.slot_credentials_asked)
      connect(account.data, Account.unknown_connection_state, this) { check_connectivity(true) }

      connect(NetworkInformation.instance, NetworkInformation.reachability_changed, this) do |reachability|
        case reachability
        when :online, :site, :unknown
          if @connection_validator
            @connection_validator.disconnect(this)
            @connection_validator.delete_later
            @connection_validator.clear
          end

          @account.access_manager.clear_connection_cache
          QTimer.single_shot(0, this) { check_connectivity(false) }
        when :disconnected
          if state != :signed_out
            set_state(:disconnected)
          end
        when :local
          nil
        end
      end

      connect(NetworkInformation.instance, NetworkInformation.is_metered_changed, this) do |is_metered|
        if ConfigFile.new.pause_sync_when_metered
          if state == :connected && is_metered
            Log.info("gui.account.state") { "Network switched to a metered connection, setting account state to PausedDueToMetered" }
            set_state(:connecting)
          elsif state == :connecting && !is_metered
            Log.info("gui.account.state") { "Network switched to a NON-metered connection, setting account state to Connected" }
            set_state(:connected)
          end
        end
      end

      connect(NetworkInformation.instance, NetworkInformation.is_behind_captive_portal_changed, this) do |onoff|
        if onoff
          @queue_guard.block
        else
          @account.job_queue.clear
          @queue_guard.unblock
        end

        if @connection_validator
          @connection_validator.disconnect(this)
          @connection_validator.delete_later
          @connection_validator.clear
        end

        QTimer.single_shot(0, this) { check_connectivity(false) }
      end

      if NetworkInformation.instance.is_behind_captive_portal
        @queue_guard.block
      end

      timer = QTimer.new(this)
      timer.set_interval(:default_calling_interval)
      connect(timer, QTimer.timeout, this) { check_connectivity(false) }
      timer.start
      connect(account.credentials, AbstractCredentials.request_logout, this) { set_state(:signed_out) }
    end

    def user_explicitly_signed_out_c
      return "userExplicitlySignedOut"
    end

    def finalize
    end

    def create(account)
      return AccountState.new(account)
    end

    def load_from_settings(account, settings)
      account_state = AccountState.new(account)
      user_explicitly_signed_out = settings.value(user_explicitly_signed_out_c, false).to_bool

      if user_explicitly_signed_out
        account_state.set_state(:signed_out)
      end

      return account_state
    end

    def from_new_account(account)
      return AccountState.new(account)
    end

    def write_to_settings(settings)
      settings.set_value(user_explicitly_signed_out_c, @state == :signed_out)
    end

    def account
      return @account
    end

    def connection_status
      return @connection_status
    end

    def connection_errors
      return @connection_errors
    end

    def state
      return @state
    end

    def set_state(state)
      state_has_changed = state != @state

      if state_has_changed
        old_state = @state
        Log.info("gui.account.state") { "AccountState state change:  #{@state} . #{state}" }
        @state = state

        if @state == :signed_out
          @connection_status = :undefined
          @connection_errors.clear
        elsif old_state == :signed_out && @state == :disconnected
          check_connectivity
        elsif @state == :connected
          if (
            (
              NetworkInformation.instance.is_metered &&
              ConfigFile.new.pause_sync_when_metered
            ) ||
            NetworkInformation.instance.is_behind_captive_portal
          )
            @state = :connecting
          end
        end
      end

      if state == :connected
        QTimer.single_shot(0, this) do
          @queue_guard.unblock

          if (
            !@fetch_server_settings_job &&
            @fetch_capabilities_elapsed_timer.duration > FETCH_SETTINGS_TIMEOUT
          )
            @fetch_server_settings_job = FetchServerSettingsJob.new(account, this)

            connect(@fetch_server_settings_job, FetchServerSettingsJob.finished_signal, this) do
              @fetch_server_settings_job.delete_later
              @fetch_server_settings_job.clear
              @fetch_capabilities_elapsed_timer.reset

              if state_has_changed
                is_connected_changed
              end
            end

            @fetch_server_settings_job.start
          elsif state_has_changed
            is_connected_changed
          end
        end
      elsif state_has_changed
        is_connected_changed
      end

      if state_has_changed
        state_changed(@state)
      end
    end

    def is_signed_out
      return @state == :signed_out
    end

    def sign_out_by_ui
      account.credentials.forget_sensitive_data
      account.clear_cookie_jar
      set_state(:signed_out)
      account.wants_account_saved(account.data)
    end

    def sign_in
      if @state == :signed_out
        @waiting_for_new_credentials = false
        set_state(:disconnected)
        account.wants_account_saved(account.data)
      end
    end

    def is_connected
      return @state == :connected
    end

    def tag_last_successfull_e_tag_request(tp)
      @time_of_last_e_tag_check = tp
    end

    def check_connectivity(block_jobs)
      if is_signed_out || @waiting_for_new_credentials
        return
      end

      Log.info("gui.account.state") { "checkConnectivity blocking: #{block_jobs} #{account.display_name_with_host}" }

      if @state != :connected
        set_state(:connecting)
      end

      if @tls_dialog
        Log.debug("gui.account.state") { "Skip checkConnectivity, waiting for tls dialog" }

        return
      end

      if (
        @connection_validator &&
        block_jobs &&
        !@queue_guard.queue.is_blocked
      )
        @connection_validator.delete_later
        @connection_validator.clear
      end

      if @connection_validator
        Log.warn("gui.account.state") {
          "ConnectionValidator already running, ignoring #{account.display_name_with_host} Queue is blocked:" \
            "#{@queue_guard.queue.is_blocked}"
        }

        return
      end

      if !account.credentials.was_fetched
        @waiting_for_new_credentials = true
        account.credentials.fetch_from_keychain
      end

      if account.has_capabilities
        pta = account.capabilities.remote_poll_interval
        polltime = duration_cast < seconds > (ConfigFile.new.remote_poll_interval(pta))
        elapsed = @time_of_last_e_tag_check.secs_to(QDateTime.current_date_time_utc)

        if (
          !block_jobs &&
          is_connected &&
          @time_of_last_e_tag_check.is_valid &&
          elapsed <= polltime.count
        )
          Log.debug("gui.account.state") {
            "#{account.display_name_with_host} The last ETag check succeeded within the last  #{polltime.count} s (" \
              "#{elapsed} s). No connection check needed!"
          }

          return
        end
      end

      if block_jobs
        @queue_guard.block
      end

      @connection_validator = ConnectionValidator.new(account)

      connect(
        @connection_validator,
        ConnectionValidator.connection_result,
        this,
        AccountState.slot_connection_validator_result
      )

      mode = :validate_auth_and_update

      if is_connected
        if block_jobs
          @connection_validator.set_clear_cookies(true)
        end

        mode = :validate_auth_and_update
      elsif @waiting_for_new_credentials
        mode = :validate_server
      else
        @connection_validator.set_clear_cookies(true)
        mode = :validate_auth_and_update
      end

      @connection_validator.check_server(mode)
    end

    def slot_connection_validator_result(status, errors)
      if is_signed_out
        Log.warn("gui.account.state") { "Signed out, ignoring #{status} #{@account.url.to_string}" }

        return
      end

      if status == :connected && !@account.has_capabilities
        @connection_validator.delete_later
        @connection_validator.clear
        check_connectivity

        return
      end

      if @connection_status != status
        Log.info("gui.account.state") { "AccountState connection status change:  #{@connection_status} . #{status}" }
        @connection_status = status
      end

      @connection_errors = errors

      case status
      when :connected
        set_state(:connected)
      when :undefined, :service_unavailable, :timeout, :status_not_found
        set_state(:disconnected)
      when :credentials_wrong, :credentials_not_ready
        slot_invalid_credentials
      when :ssl_error
        nil
      when :captive_portal
        set_state(:connecting)
      end
    end

    def slot_invalid_credentials
      if !@waiting_for_new_credentials
        Log.info("gui.account.state") { "Invalid credentials for #{@account.url.to_string}" }
        @waiting_for_new_credentials = true

        if account.credentials.ready
          account.credentials.invalidate_token
        end

        Log.info("gui.account.state") { "restart oauth" }
        account.credentials.restart_oauth
        set_state(:connecting)
      end
    end

    def slot_credentials_fetched
      Log.info("gui.account.state") { "Fetched credentials for #{@account.url.to_string} attempting to connect" }
      @waiting_for_new_credentials = false
      check_connectivity
    end

    def slot_credentials_asked
      Log.info("gui.account.state") { "Credentials asked for #{@account.url.to_string} are they ready? #{@account.credentials.ready}" }
      @waiting_for_new_credentials = false

      if !@account.credentials.ready
        set_state(:signed_out)

        return
      end

      if @connection_validator
        @connection_validator.delete_later
        @connection_validator.clear
      end

      check_connectivity
    end

    def account_for_qml
      return @account.data
    end

    def is_setting_up
      return @setting_up
    end

    def set_setting_up(setting_up)
      if @setting_up != setting_up
        @setting_up = setting_up
        is_setting_up_changed
      end
    end

    def ready_for_sync
      return !@fetch_server_settings_job && is_connected
    end
  end
end
