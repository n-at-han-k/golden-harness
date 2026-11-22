#!/usr/bin/env ruby
#
# Copyright (C) by Olivier Goffart <ogoffart@woboq.com>
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

require_relative "accountmanager"
require_relative "account"
require_relative "common/asserts"
require_relative "creds/httpcredentials"
require_relative "common/utility"
require_relative "configfile"

require "qsettings"

include Qt::Literals::StringLiterals

module OCC
  class AccountManager
    def url_c
      return "url"
    end

    def default_sync_root_c
      return "default_sync_root"
    end

    def dav_user_disply_name_c
      return "display-name"
    end

    def user_uuidc
      return "uuid"
    end

    def ca_certs_key_c
      return "CaCertificates"
    end

    def accounts_c
      return "Accounts"
    end

    def capabilites_c
      return "capabilities"
    end

    def instance
      instance = AccountManager.new

      return instance
    end

    def restore
      settings = ConfigFile.make_q_settings

      if settings.status != :no_error
        Log.warn("gui.account.manager") { "Could not read settings from #{settings.file_name} #{settings.status}" }

        return false
      end

      size = settings.begin_read_array(accounts_c)

      (0...size).each do |i|
        settings.set_array_index(i)
        url_config = settings.value(url_c)

        if !url_config.is_valid
          Log.warn("gui.account.manager") { "No URL for account  #{settings.group}" }

          next
        end

        acc = create_account(settings.value(user_uuidc, QVariant.from_value(QUuid.create_uuid)).to_uuid)
        acc.set_url(url_config.to_url)
        acc.display_name = settings.value(dav_user_disply_name_c).to_string

        capabilities = settings.value(capabilites_c).value < QVariantMap >
          capabilities.insert("cached", true)

        acc.set_capabilities([acc.url, capabilities])
        acc.set_default_sync_root(settings.value(default_sync_root_c).to_string)
        acc.set_credentials(HttpCredentials.new)
        certs = QSslCertificate.from_data(settings.value(ca_certs_key_c).to_byte_array)
        Log.info("gui.account.manager") { "Restored:  #{certs.count}  unknown certs." }
        acc.set_approved_certs(certs)
        acc_state = AccountState.load_from_settings(acc, settings)

        if acc_state
          add_account_state(acc_state)
        end
      end

      settings.end_array

      return true
    end

    def save
      settings = ConfigFile.make_q_settings
      settings.remove(accounts_c)
      settings.begin_write_array(accounts_c, @accounts.size)
      i = 0

      @accounts.each do |account_state|
        settings.set_array_index(i)
        i += 1
        account = account_state.account
        Log.debug("gui.account.manager") { "Saving account #{account.url.to_string}" }
        settings.set_value(url_c, account.url.to_string)
        settings.set_value(dav_user_disply_name_c, account.display_name)
        settings.set_value(user_uuidc, account.uuid)

        if account.has_capabilities
          settings.set_value(capabilites_c, account.capabilities.raw)
        end

        if account.has_default_sync_root
          settings.set_value(default_sync_root_c, account.default_sync_root)
        end

        Log.info("gui.account.manager") { "Saving  #{account.approved_certs.count}  unknown certs." }
        approved_certs = account.approved_certs
        certs = ""

        approved_certs.each do |cert|
          certs += cert.to_pem + "\n"
        end

        if !certs.is_empty
          settings.set_value(ca_certs_key_c, certs)
        end

        account_state.write_to_settings(settings)
      end

      settings.end_array
      Log.info("gui.account.manager") { "Saved all account settings" }
    end

    def account_names
      accounts = []
      accounts.reserve(AccountManager.instance.accounts.size)

      AccountManager.instance.accounts.each do |a|
        accounts << a.account.display_name_with_host
      end

      std::sort(accounts.begin, accounts.end)

      return accounts
    end

    def accounts_raw
      out = []
      out.reserve(@accounts.size)

      @accounts.values.each do |x|
        out.append(x)
      end

      return out
    end

    def account(uuid)
      acc = Utility.optional_find(@accounts, uuid)

      if acc.has_value
        return acc.value
      end

      return nil
    end

    def add_account(new_account)
      return add_account_state(AccountState.from_new_account(new_account))
    end

    def delete_account(account)
      it = std::find(@accounts.begin, @accounts.end, account)

      if it == @accounts.end
        return
      end

      @accounts.erase(it)

      if account.account.has_default_sync_root
        Utility.unmark_directory_as_sync_root(account.account.default_sync_root)
      end

      account.account.credentials.forget_sensitive_data
      account_removed(account)
      accounts_changed
      account.delete_later
      save
    end

    def create_account(uuid)
      acc = Account.create(uuid)

      return acc
    end

    def shutdown
      accounts = @accounts

      accounts.each do |acc|
        account_removed(acc)
      end

      q_delete_all(accounts)
    end

    def add_account_state(account_state)
      raw_account = account_state.account.data
      connect(raw_account, Account.wants_account_saved, this, AccountManager.save)
      state_ptr = account_state.release
      @accounts.insert(state_ptr.account.uuid, state_ptr)
      account_added(state_ptr)
      accounts_changed

      return state_ptr
    end
  end
end
