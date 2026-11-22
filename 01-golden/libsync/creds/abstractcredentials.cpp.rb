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

require "qloggingcategory"

require_relative "account"
require_relative "common/asserts"
require_relative "creds/abstractcredentials"

module OCC
  class AbstractCredentials
    def initialize
      @account = nil
      @was_fetched = false
    end

    def set_account(account)
      unless !@account
        raise
      end

      @account = account
    end

    def check_credentials(_)
    end
  end
end
