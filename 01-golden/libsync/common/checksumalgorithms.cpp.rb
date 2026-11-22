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

require_relative "checksumalgorithms"

require_relative "moc_checksumalgorithms.cpp"

include OCC

module CheckSums
  def from_byte_array(s)
    unless (lambda {
      once = lambda {
        :all.each { |a|
          s = Utility.enum_to_string(a.first)

          if s != s.to_upper
            return false
          end
        }

        return true
      }

      once.call

      return once
    }).call
      raise
    end

    return from_name(s.to_upper.const_data)
  end
end

module Utility
  def enum_to_string(algo)
    n = to_string(algo)

    return QString.from_utf8(n.data, n.size)
  end
end
