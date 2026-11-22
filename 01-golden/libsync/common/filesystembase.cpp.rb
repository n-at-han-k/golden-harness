#!/usr/bin/env ruby
#
# Copyright (C) by Daniel Molkentin <danimo@owncloud.com>
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

require_relative "filesystembase"
require_relative "common/asserts"
require_relative "utility"

require "qcoreapplication"
require "qdatetime"
require "qdir"
require "qfile"
require "qsettings"

require "sys/stat"
require "sys/types"

require_relative "moc_filesystembase.cpp"

include Qt::Literals::StringLiterals

module OCC
  module FileSystem
    FILE_NAME_MAX_C = 255 - 10
    REPLACEMENT_CHAR_C = "_"
    def to_filesystem_path(path)
      return QtPrivate.to_filesystem_path(path)
    end

    def from_filesystem_path(path)
      return QtPrivate.from_filesystem_path(path)
    end

    def long_win_path(inpath)
      return inpath
    end

    def set_file_hidden(_filename, _hidden)
    end

    def get_default_write_permissions
      result = :write_user
      mask = umask(0)
      umask(mask)

      if !(mask & S_IWGRP)
        result |= :write_group
      end

      if !(mask & S_IWOTH)
        result |= :write_other
      end

      return result
    end

    def set_file_read_only(_filename, readonly)
      file = QFile.new(filename)
      permissions = file.permissions
      all_write_permissions = :write_user | :write_group | :write_other | :write_owner
      default_write_permissions = get_default_write_permissions
      permissions &= all_write_permissions

      if !readonly
        permissions |= default_write_permissions
      end

      file.set_permissions(permissions)
    end

    def set_folder_minimum_permissions(_filename)
    end

    def set_file_read_only_weak(filename, readonly)
      file = QFile.new(filename)
      permissions = file.permissions

      if !readonly && (permissions & :write_owner)
        return
      end

      set_file_read_only(filename, readonly)
    end

    def rename(origin_file_name, destination_file_name, error_string)
      success = false
      error = ""
      orig = QFile.new(origin_file_name)
      success = orig.rename(destination_file_name)

      if !success
        error = orig.error_string
      end

      if !success
        Log.warn("sync.filesystem") { "Error renaming file #{origin_file_name} to #{destination_file_name} failed:  #{error}" }

        if error_string
          error_string = error
        end
      end

      return success
    end

    def unchecked_rename_replace(_origin_file_name, destination_file_name, error_string)
      unless error_string
        raise
      end

      success = false
      orig = QFile.new(origin_file_name)
      success = true
      dest_exists = file_exists(destination_file_name)

      if dest_exists && !QFile.remove(destination_file_name)
        error_string = orig.error_string
        Log.warn("sync.filesystem") { "Target file could not be removed." }
        success = false
      end

      if success
        success = orig.rename(destination_file_name)
      end

      if !success
        error_string = orig.error_string
        Log.warn("sync.filesystem") { "Renaming temp file to final failed:  #{error_string}" }

        return false
      end

      return true
    end

    def open_and_seek_file_shared_read(file, error_or_null, seek)
      error_dummy = ""

      if error_or_null
        error = error_or_null
      else
        error = error_dummy
      end

      error.clear

      if !file.open(:read_only)
        error = file.error_string

        return false
      end

      if !file.seek(seek)
        error = file.error_string

        return false
      end

      return true
    end

    def file_exists(filename, file_info)
      re = file_info.exists

      if file_info.file_path != filename
        re = QFileInfo.exists(filename)
      end

      return re
    end

    def remove(file_name, error_string)
      f = QFile.new(file_name)

      if !f.remove
        if error_string
          error_string = f.error_string
        end

        Log.warn("sync.filesystem") { "Failed to delete: #{file_name} Error: #{f.error_string}" }

        return false
      end

      return true
    end

    def is_file_locked(_file_name, _mode)
      return false
    end

    def is_lnk_file(filename)
      return filename.ends_with(".lnk")
    end

    def is_junction(_filename)
      return false
    end

    def is_child_path_of2(child, parent)
      sensitivity = Utility.fs_case_sensitivity

      if parent.is_empty
        return :is_child | :is_parent_empty
      end

      if child.compare(parent, sensitivity) == 0
        return :is_child | :is_equal
      end

      is_separator = lambda do |c|
        return (
          c == "/" ||
          (Utility.is_windows && c == "\\")
        )
      end

      if is_separator.call(parent.back)
        if child.starts_with(parent, sensitivity)
          return :is_child
        end
      end

      clean_parent = QDir.clean_path(parent.to_string)
      clean_child = QDir.clean_path(child.to_string)

      if clean_child.compare(clean_parent, sensitivity) == 0
        return :is_child | :is_equal
      end

      if clean_child.starts_with(clean_parent + "/", sensitivity)
        return :is_child
      end

      return :is_no_child
    end

    def create_portable_file_name(path, file_name, reserved_size)
      tmp = path_escape(file_name)
      tmp.resize(min(tmp.size, FILE_NAME_MAX_C - reserved_size))
      tmp = tmp.trimmed

      return QDir.clean_path(path + "/" + tmp)
    end

    def path_escape(s)
      tmp = s
      tmp.replace("../", REPLACEMENT_CHAR_C)
      tmp.replace("/", REPLACEMENT_CHAR_C)

      :illegal_filename_chars_windows.each do |c|
        tmp.replace(c, REPLACEMENT_CHAR_C)
      end

      return tmp.trimmed
    end
  end
end
