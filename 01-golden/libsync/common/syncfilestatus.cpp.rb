#!/usr/bin/env ruby
#
# Copyright (C) by Klaas Freitag <freitag@owncloud.com>
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

require_relative "syncfilestatus"

require "qdebug"

module OCC
  class SyncFileStatus
    def initialize
      @tag = :status_none
      @shared = false
    end

    def initialize_with_tag(tag)
      @tag = tag
      @shared = false
    end

    def set(tag)
      @tag = tag
    end

    def tag
      return @tag
    end

    def set_shared(is_shared)
      @shared = is_shared
    end

    def shared
      return @shared
    end

    def to_socket_api_string
      status_string = ""
      can_be_shared = true

      case @tag
      when :status_none
        status_string = "NOP"
        can_be_shared = false
      when :status_sync
        status_string = "SYNC"
      when :status_warning
        status_string = "IGNORE"
      when :status_up_to_date
        status_string = "OK"
      when :status_error
        status_string = "ERROR"
      when :status_excluded
        status_string = "IGNORE"
      end

      if can_be_shared && @shared
        status_string += "+SWM"
      end

      return status_string
    end
  end
end

class SyncFileStatus
  def <<(debug)
    saver = QDebugStateSaver.new(debug)
    debug.set_auto_insert_spaces(false)
    debug << "OCC::SyncFileStatus(shared=" << shared << ", tag=" << tag << ")"

    return debug
  end
end
