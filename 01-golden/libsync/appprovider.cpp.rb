#!/usr/bin/env ruby
#
# Copyright (C) by Hannah von Reth <hannah.vonreth@owncloud.com>
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
#

require_relative "appprovider"

require_relative "common/utility"
require_relative "libsync/account"

require "qcoreapplication"
require "qdesktopservices"
require "qjsonarray"
require "qmimedatabase"

include OCC

module Provider
  def initialize(provider)
    @mime_type = provider.value("mime_type").to_string
    @extension = provider.value("extension").to_string
    @name = provider.value("name").to_string
    @description = provider.value("description").to_string
    @icon = provider.value("icon").to_string
    @default_application = provider.value("default_application").to_string
    @allow_creation = provider.value("allow_creation").to_bool
  end

  def is_valid
    return !mime_type.is_empty
  end
end

class AppProvider
  def initialize(apps)
    mim_types = apps.value("mime-types").to_array
    @providers.reserve(apps.size)

    mim_types.each do |type|
      p = Provider.new(type.to_object)
      @providers.insert(p.mime_type, p)
    end
  end

  def app(mime_type)
    it = Utility.optional_find(@providers, mime_type.name)

    if it
      return it.value
    end

    null_provider = nil

    return null_provider
  end

  def app_with_local_path(local_path)
    db = QMimeDatabase.new
    mime_type = db.mime_type_for_file(local_path)

    return app(mime_type)
  end
end
