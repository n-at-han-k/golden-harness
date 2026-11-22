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

require_relative "syncfileitem"
require_relative "common/syncjournalfilerecord"
require_relative "common/utility"
require_relative "filesystem"

require "qcoreapplication"

require "bitset"

module OCC
  class SyncFileItem
    def from_sync_journal_file_record(rec)
      item = SyncFileItemPtr.create
      item.local_name = rec.path
      item.inode = rec.inode
      item.modtime = rec.modtime
      item.type = rec.type
      item.etag = rec.etag
      item.file_id = rec.file_id
      item.size = rec.size
      item.remote_perm = rec.remote_perm
      item.server_has_ignored_files = rec.server_has_ignored_files
      item.checksum_header = rec.checksum_header

      return item
    end

    def instruction
      return @instruction
    end

    def set_instruction(instruction)
      unless bitset.new(instruction).count == 1
        raise
      end

      @instruction = instruction
    end
  end

  module Utility
    def enum_to_display_name(s)
      case s
      when :no_status
        return QCoreApplication.translate("SyncFileItem::Status", "Undefined")
      when :fatal_error
        return QCoreApplication.translate("SyncFileItem::Status", "Fatal Error")
      when :normal_error
        return QCoreApplication.translate("SyncFileItem::Status", "Error")
      when :soft_error
        return QCoreApplication.translate("SyncFileItem::Status", "Info")
      when :success
        return QCoreApplication.translate("SyncFileItem::Status", "Success")
      when :conflict
        return QCoreApplication.translate("SyncFileItem::Status", "Conflict")
      when :file_ignored
        return QCoreApplication.translate("SyncFileItem::Status", "File Ignored")
      when :restoration
        return QCoreApplication.translate("SyncFileItem::Status", "Restored")
      when :detail_error
        return QCoreApplication.translate("SyncFileItem::Status", "Error")
      when :blacklisted_error
        return QCoreApplication.translate("SyncFileItem::Status", "Blacklisted")
      when :excluded
        return QCoreApplication.translate("SyncFileItem::Status", "Excluded")
      when :message
        return QCoreApplication.translate("SyncFileItem::Status", "Message")
      when :filename_reserved
        return QCoreApplication.translate("SyncFileItem::Status", "Filename Reserved")
      when :status_count
        raise
      end

      raise
    end
  end
end

class SyncFileItem
  def <<(debug)
    if !item
      debug << "OCC::SyncFileItem(0x0)"
    else
      saver = QDebugStateSaver.new(debug)
      debug.set_auto_insert_spaces(false)
      debug << "OCC::SyncFileItem(file=" << local_name

      if !@rename_target.is_empty
        debug << ", destination=" << destination
      end

      debug << ", type=" << @type << ", instruction=" << instruction << ", status=" << @status << ")"
    end

    return debug
  end
end
