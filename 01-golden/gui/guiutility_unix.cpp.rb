#!/usr/bin/env ruby
#
# Copyright (C) by Erik Verbruggen <erik@verbruggen.consulting>
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

require_relative "guiutility"

require "qstandardpaths"

module OCC
  module Utility
    def start_shell_integration
    end

    def socket_api_socket_path
      return "#{QStandardPaths.writable_location(:runtime_location)}/OpenCloud/socket"
    end

    def is_installed_by_store
      return false
    end
  end
end
