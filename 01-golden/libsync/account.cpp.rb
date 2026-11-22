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

require_relative "account"
require_relative "accessmanager"
require_relative "capabilities"
require_relative "common/asserts"
require_relative "cookiejar"
require_relative "creds/credentialmanager"
require_relative "creds/abstractcredentials"
require_relative "graphapi/spacesmanager"
require_relative "networkjobs"

require "qauthenticator"
require "qdir"
require "qloggingcategory"
require "qnetworkaccessmanager"
require "qnetworkcookiejar"
require "qnetworkdiskcache"
require "qsslkey"
require "qstandardpaths"

module OCC
  class Account
    _CUSTOM_COMMON_CACHE_DIRECTORY = nil

    def initialize(uuid, parent)
      super(parent)
      @uuid = uuid
      @capabilities = Capabilities.new(nil, nil)
      @job_queue = this
      @queue_guard = @job_queue
      @credential_manager = CredentialManager.new(this)
      q_register_meta_type < AccountPtr > ("AccountPtr")
    end

    def set_common_cache_directory(directory)
      @custom_common_cache_directory = directory
    end

    def common_cache_directory
      if _CUSTOM_COMMON_CACHE_DIRECTORY.is_empty
        return QStandardPaths.writable_location(:cache_location)
      end

      return _CUSTOM_COMMON_CACHE_DIRECTORY
    end

    def create(uuid)
      acc = AccountPtr.new(Account.new(uuid))
      acc.set_shared_this(acc)

      return acc
    end

    def finalize
    end

    def set_shared_this(shared_this)
      @shared_this = shared_this.to_weak_ref
    end

    def uuid
      return @uuid
    end

    def shared_from_this
      return @shared_this.to_strong_ref
    end

    def avatar
      return @avatar_img
    end

    def set_avatar(img)
      @avatar_img = img
      avatar_changed
    end

    def has_avatar
      return !@avatar_img.is_null
    end

    def display_name_with_host
      user = dav_display_name
      host = @url.host
      port = url.port

      if port > 0 && port != 80 && port != 443
        host += ":#{QString.number(port)}"
      end

      return "#{user}@#{host}"
    end

    def initials
      out = ""

      dav_display_name.split(" ", :skip_empty_parts).each do |p|
        out.append(p.first(1))
      end

      return out
    end

    def avatar_gradient
      return q_hash(display_name_with_host) % :num_presets + 1
    end

    def dav_display_name
      return @display_name
    end

    def set_dav_display_name(new_display_name)
      if @display_name != new_display_name
        @display_name = new_display_name
        display_name_changed
      end
    end

    def credential_manager
      return @credential_manager
    end

    def credentials
      return @credentials.data
    end

    def set_credentials(cred)
      jar = nil

      if @am
        jar = @am.cookie_jar
        jar.set_parent(nil)
        @am.delete_later
      end

      @credentials.reset(cred)
      cred.set_account(this)
      @am = @credentials.create_am

      if jar
        @am.set_cookie_jar(jar)
      end

      connect(@credentials.data, AbstractCredentials.fetched, this) do
        credentials_fetched
        @queue_guard.unblock
      end

      connect(@credentials.data, AbstractCredentials.authentication_started, this) { @queue_guard.block }
      connect(@credentials.data, AbstractCredentials.authentication_failed, this) { @queue_guard.clear }
    end

    def clear_cookie_jar
      Log.info("sync.account") { "Clearing cookies" }
      @am.cookie_jar.delete_later
      @am.set_cookie_jar(CookieJar.new)
    end

    def access_manager
      return @am.data
    end

    def send_raw_request(verb, url, req, data)
      unless verb.is_upper
        raise
      end

      req.set_url(url)

      if verb == "HEAD" && !data
        return @am.head(req)
      elsif verb == "GET" && !data
        return @am.get(req)
      elsif verb == "POST"
        return @am.post(req, data)
      elsif verb == "PUT"
        return @am.put(req, data)
      elsif verb == "DELETE" && !data
        return @am.delete_resource(req)
      end

      return @am.send_custom_request(req, verb, data)
    end

    def set_approved_certs(certs)
      @approved_certs = [certs.begin, certs.end]
      @am.set_custom_trusted_ca_certificates(@approved_certs)
    end

    def add_approved_certs(certs)
      @approved_certs.unite(certs)
      @am.set_custom_trusted_ca_certificates(@approved_certs)
      wants_account_saved(this)
    end

    def set_url(url)
      if @url != url
        @url = url
        url_changed
      end
    end

    def url
      return @url
    end

    def host_name
      return @url.host
    end

    def job_queue
      return @job_queue
    end

    def clear_am_cache
      @am.clear_access_cache
    end

    def capabilities
      unless has_capabilities
        raise
      end

      return @capabilities
    end

    def has_capabilities
      return @capabilities.is_valid
    end

    def set_capabilities(caps)
      if @capabilities != caps
        version_changed = (
          caps.status.legacy_version != @capabilities.status.legacy_version ||
          caps.status.productversion != @capabilities.status.productversion
        )

        @capabilities = caps
        capabilities_changed

        if version_changed
          server_version_changed
        end
      end
    end

    def server_support_level
      if !has_capabilities
        return :supported
      end

      if !capabilities.status.productversion.is_empty
        return :supported
      end

      return :unsupported
    end

    def is_http2_supported
      return @http2_supported
    end

    def set_http2_supported(value)
      @http2_supported = value
    end

    def default_sync_root
      unless !@default_sync_root.is_empty
        raise
      end

      return @default_sync_root
    end

    def has_default_sync_root
      return !@default_sync_root.is_empty
    end

    def set_default_sync_root(sync_root)
      unless @default_sync_root.is_empty
        raise
      end

      if !sync_root.is_empty
        @default_sync_root = sync_root

        if !QFileInfo.exists(@default_sync_root)
          unless QDir.new.mkpath(@default_sync_root)
            raise
          end
        end

        Utility.mark_directory_as_sync_root(@default_sync_root, uuid)
        wants_account_saved(this)
      end
    end

    def set_app_provider(p)
      @app_provider = p
    end

    def app_provider
      return @app_provider
    end

    def invalid_credentials_encountered
      invalid_credentials(Account.q_private_signal)
    end
  end
end

class Account
  def <<(debug)
    saver = QDebugStateSaver.new(debug)
    debug.set_auto_insert_spaces(false)
    debug << "OCC::Account(" << display_name_with_host << ")"

    return debug.maybe_space
  end
end
