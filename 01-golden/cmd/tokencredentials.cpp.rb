#!/usr/bin/env ruby
#
# Copyright (C) by Hannah von Reth <h.vonreth@opencloud.eu>
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

require_relative "tokencredentials"

require_relative "creds/httpcredentials"
require_relative "libsync/accessmanager"

require "qtimer"

require_relative "tokencredentials.moc"

include OCC

class TokenCredentials
  OCC::TokensAccessManager = Struct.new(
    :_token,
    keyword_init: true
  )
  def initialize(username, token)
    @access_manager = TokensAccessManager.new(username, token, this)

    connect(@access_manager, QNetworkAccessManager.finished, this) do |reply|
      if reply.error == :authentication_required_error
        authentication_failed
      end
    end
  end

  def create_am
    return @access_manager
  end

  def ready
    return true
  end

  def fetch_from_keychain
    @was_fetched = true
    QTimer.single_shot(0, this) { fetched }
  end

  def restart_oauth
  end

  def persist
  end

  def invalidate_token
  end

  def forget_sensitive_data
  end
end
