#!/usr/bin/env ruby
#
# Copyright (C) by Olivier Goffart <ogoffart@woboq.com>
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

require_relative "remotepermissions"
require "cstring"

module OCC
  class RemotePermissions
    LETTERS = " WDNVCKRSMmz"
    def from_array(p)
      @value = not_null_mask

      if !p
        return
      end

      while p
        res = std::strchr(LETTERS, p)

        if res
          @value |= (1 << (res - LETTERS))
        end

        p += 1
      end
    end

    def to_db_value
      result = ""

      if is_null
        return result
      end

      result.reserve(:permissions_count)
      i = 1

      while i <= :permissions_count
        if @value & (1 << i)
          result.append(LETTERS[i])
        end

        i += 1
      end

      if result.is_empty
        result.append(" ")
      end

      return result
    end

    def to_string
      return QString.from_utf8(to_db_value)
    end

    def from_db_value(value)
      if value.is_empty
        return RemotePermissions.new
      end

      perm = RemotePermissions.new
      perm.from_array(value.const_data)

      return perm
    end

    def from_server_string(value)
      perm = RemotePermissions.new
      perm.from_array(value.utf16)

      return perm
    end
  end
end
