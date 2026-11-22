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

require_relative "filesystem"

require_relative "common/asserts"
require_relative "common/utility"
require_relative "libsync/localinfo"
require_relative "libsync/xattr"

require "qcoreapplication"
require "qdiriterator"
require "qfile"
require "qfileinfo"

require_relative "csync"
require_relative "syncfileitem"

require "sys/stat"

include Qt::Literals::StringLiterals

module OCC
  module FileSystem
    MAX_VALUE_SIZE = 1023
    def file_equals(fn1, fn2)
      f1 = QFile.new(fn1)
      f2 = QFile.new(fn2)

      if !f1.open(:read_only) || !f2.open(:read_only)
        Log.warn("sync.filesystem") { "fileEquals: Failed to open  #{fn1} or #{fn2}" }

        return false
      end

      if get_size(QFileInfo.new(fn1)) != get_size(QFileInfo.new(fn2))
        return false
      end

      buffer_size = 16 * 1024
      buffer1 = QByteArray.new(buffer_size, 0)
      buffer2 = QByteArray.new(buffer_size, 0)

      while !f1.at_end
        f1.read(buffer1.data, buffer_size)
        f2.read(buffer2.data, buffer_size)

        if buffer1 != buffer2
          return false
        end
      end

      return true
    end

    def file_time_to_time_t(file_time)
      return std::chrono::system_clock::to_time_t(std::chrono::clock_cast(file_time))
      system_time = std::chrono::time_point_cast(std::chrono::file_clock::to_sys(file_time))

      return std::chrono::system_clock::to_time_t(system_time)
    end

    def time_t_to_file_time(file_time)
      return std::chrono::clock_cast(std::chrono::system_clock::from_time_t(file_time))

      return std::chrono::file_clock::from_sys(std::chrono::system_clock::from_time_t(file_time))
    end

    def get_mod_time(filename)
      rc = nil
      file_time = std::filesystem::last_write_time(filename, rc)

      if rc
        unless !rc
          raise
        end

        return std::chrono::system_clock::to_time_t(std::chrono::system_clock::now)
      else
        return file_time_to_time_t(file_time)
      end
    end

    def set_mod_time(filename, mod_time)
      rc = nil
      std::filesystem::last_write_time(filename, time_t_to_file_time(mod_time), rc)

      if rc
        Log.warn("sync.filesystem") { "Error setting mtime for #{filename} failed: rc #{rc.value} , error message: #{rc.message}" }

        unless !rc
          raise
        end

        return false
      end

      return true
    end
  end

  module FileChangedInfo
    def from_sync_file_item(item)
      if item.inode == 0
        return { size: item.size, mtime: item.modtime, inode: nil, type: item.type }
      else
        return { size: item.size, mtime: item.modtime, inode: item.inode, type: item.type }
      end
    end

    def from_sync_file_item_previous(item)
      return { size: item.previous_size, mtime: item.previous_modtime, type: item.type }
    end

    def from_sync_journal_file_record(record)
      if !record.is_valid
        return nil
      end

      return { size: record.size, mtime: record.modtime, inode: record.inode, type: record.type }
    end
  end

  module FileSystem
    def file_changed(path, previous_info)
      dirent = std::filesystem::directory_entry.new(path)

      if !dirent.exists
        if previous_info.mtime.has_value
          Log.debug("sync.filesystem") { "#{path.native} was removed" }

          return true
        else
          unless false
            raise
          end

          return false
        end
      end

      info = LocalInfo.new(dirent)

      if previous_info.type != :item_type_unsupported
        if (
          previous_info.type == :item_type_directory &&
          info.type == :item_type_file
        )
          Log.debug("sync.filesystem") { "File #{path.native} has changed: from dir to file" }

          return true
        end

        if (
          previous_info.type == :item_type_file &&
          info.type == :item_type_directory
        )
          Log.debug("sync.filesystem") { "File #{path.native} has changed: from file to dir" }

          return true
        end
      end

      if (
        previous_info.inode.has_value &&
        previous_info.inode.value != info.inode
      )
        Log.debug("sync.filesystem") { "File #{path.native} has changed: inode #{previous_info.inode.value} <-. #{info.inode}" }

        return true
      end

      if info.is_directory
        if previous_info.size != 0
          Log.debug("sync.filesystem") { "File #{path.native} has changed: from file to dir" }

          return true
        end
      elsif info.size != previous_info.size
        Log.debug("sync.filesystem") { "File #{path.native} has changed: size:  #{previous_info.size} <. #{info.size}" }

        return true
      end

      if info.modtime != previous_info.mtime
        Log.debug("sync.filesystem") { "File #{path.native} has changed: mtime:  #{previous_info.mtime} <. #{info.modtime}" }

        return true
      end

      return false
    end

    def canonical_path(p)
      ec = nil

      if !std::filesystem::exists(p, ec) && !ec
        normalized = p.lexically_normal
        parent_path = normalized.parent_path

        if parent_path == p
          return p
        end

        if normalized.filename.empty
          return canonical_path(parent_path)
        else
          return canonical_path(parent_path) / normalized.filename
        end
      end

      if ec
        Log.warn("sync.filesystem") { "Failed to check existence of path: #{p} #{ec.message}" }
      end

      out = std::filesystem::canonical(p, ec)

      if ec
        Log.warn("sync.filesystem") { "Failed to canonicalize path: #{p} #{ec.message}" }

        return p
      end

      return out
    end

    def canonical_path_with_p(p)
      return FileSystem.from_filesystem_path(canonical_path(FileSystem.to_filesystem_path(p)))
    end

    def get_size(filename)
      ec = nil
      size = std::filesystem::file_size(filename, ec)

      if ec
        if !std::filesystem::is_directory(filename)
          Log.error("sync.filesystem") { "Error getting size for #{filename} #{ec.value} #{ec.message}" }
        else
          Log.warn("sync.filesystem") { "Called getFileSize on a directory" }

          unless false
            raise
          end
        end

        return 0
      end

      return size
    end

    def remove_recursively(path, success, locked, errors)
      all_removed = true
      di = QDirIterator.new(path, :all_entries | :hidden | :system | :no_dot_and_dot_dot)
      remove_error = ""

      while di.has_next
        di.next
        fi = di.file_info

        is_dir = (
          fi.is_dir &&
          !fi.is_sym_link &&
          !FileSystem.is_junction(fi.absolute_file_path)
        )

        if is_dir
          all_removed &= remove_recursively(path + "/" + di.file_name, success, locked, errors)
        elsif FileSystem.is_file_locked(di.file_path, :exclusive)
          locked.push_back([di.file_path, is_dir])
          all_removed = false
        elsif FileSystem.remove(di.file_path, remove_error)
          success.push_back([di.file_path, is_dir])
        else
          errors.push_back([[di.file_path, is_dir], remove_error])
          Log.warn("sync.filesystem") { "Error removing  #{di.file_path} #{":"} #{remove_error}" }
          all_removed = false
        end
      end

      if all_removed
        all_removed = QDir.new.rmdir(path)

        if all_removed
          success.push_back([path, true])
        else
          errors.push_back([[path, true], QCoreApplication.translate("FileSystem", "Could not remove folder")])
          Log.warn("sync.filesystem") { "Error removing folder #{path}" }
        end
      end

      return all_removed
    end

    def get_inode(_filename)
      info = LocalInfo.new(filename)

      unless info.is_valid
        raise
      end

      if !info.is_valid
        return nil
      end

      return info.inode
    end
  end

  module Tags
    def get(path, key)
      platform_key = key

      if Utility.is_linux
        platform_key = "user." + platform_key
      end

      d = Xattr.getxattr(to_filesystem_path(path), platform_key)

      if d
        return QString.from_utf8(d)
      end

      return nil
    end

    def set(path, key, value)
      unless value.size < MAX_VALUE_SIZE
        raise
      end

      platform_key = key

      if Utility.is_linux
        platform_key = "user." + platform_key
      end

      return Xattr.setxattr(to_filesystem_path(path), platform_key, value.to_utf8)
    end

    def remove(path, key)
      platform_key = key

      if Utility.is_linux
        platform_key = "user.#{platform_key}"
      end

      return Xattr.removexattr(to_filesystem_path(path), platform_key)
    end
  end
end
