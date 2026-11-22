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

require_relative "pinstate"
require_relative "moc_pinstate.cpp"

require "qcoreapplication"

include OCC

module Utility
  def enum_to_display_name(availability)
    case availability
    when :always_local
      return QCoreApplication.translate("pinstate", "Always available locally")
    when :all_hydrated
      return QCoreApplication.translate("pinstate", "Currently available locally")
    when :mixed
      return QCoreApplication.translate("pinstate", "Some available online only")
    when :all_dehydrated, :online_only
      return QCoreApplication.translate("pinstate", "Available online only")
    end

    raise
  end
end
