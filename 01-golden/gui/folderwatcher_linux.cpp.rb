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

require "cerrno"
require "sys/inotify"
require "unistd"

require_relative "folder"
require_relative "folderwatcher_linux"

require "qobject"
require "qstringlist"
require "qvarlengtharray"

include Qt::Literals::StringLiterals

module OCC
  class FolderWatcherPrivate
    def initialize(p, path)
      @parent = p
      @folder = path
      @fd = inotify_init1(IN_CLOEXEC)

      if @fd != -1
        @socket = QSocketNotifier.new(@fd, :read)
        connect(@socket, QSocketNotifier.activated, this, FolderWatcherPrivate.slot_received_notification)
      else
        Log.warn("gui.folderwatcher") { "inotify_init1() failed:  #{strerror(errno)}" }
      end

      QMetaObject.invoke_method(this) { slot_add_folder_recursive(path) }
    end

    def finalize
      if @socket
        @socket.set_enabled(false)
        @socket.delete_later
      end

      remove_folders_below(@folder)

      if @fd != -1
        close(@fd)
        @fd = -1
      end
    end

    def find_folders_below(dir, full_list)
      if !dir.exists
        Log.debug("gui.folderwatcher") { "      - non existing path coming in:  #{dir.absolute_path}" }

        return false
      elsif !dir.is_readable
        Log.debug("gui.folderwatcher") { "      - path without read permissions coming in:  #{dir.absolute_path}" }

        return false
      end

      filter = :dirs | :no_dot_and_dot_dot | :no_sym_links | :hidden
      ok = true

      dir.entry_list(["*"], filter).each do |path|
        full_path = dir.path + "/" + path
        full_list.append(full_path)
        ok &= find_folders_below(QDir.new(full_path), full_list)
      end

      return ok
    end

    def inotify_register_path(path)
      if path.is_empty
        unless false
          raise
        end

        return
      end

      folder_path = Utility.ensure_trailing_slash(path)

      wd = inotify_add_watch(
        @fd,
        folder_path.to_utf8.const_data,
        IN_CLOSE_WRITE | IN_ATTRIB | IN_MOVE | IN_CREATE | IN_DELETE | IN_DELETE_SELF | IN_MOVE_SELF | IN_UNMOUNT | IN_ONLYDIR
      )

      if wd != -1
        @watch_to_path.insert(wd, folder_path)
        @path_to_watch.insert(folder_path, wd)
      elsif (
        @parent.is_reliable &&
        (errno == ENOMEM || errno == ENOSPC)
      )
        @parent.is_reliable = false

        @parent.became_unreliable(
          "This problem usually happens when the inotify watches are exhausted. " \
          "Check the FAQ for details."
        )
      end
    end

    def slot_add_folder_recursive(path)
      if @path_to_watch.contains(path)
        return
      end

      subdir_count = 0
      Log.debug("gui.folderwatcher") { "(+) Watcher: #{path}" }
      in_path = QDir.new(path)
      inotify_register_path(in_path.absolute_path)
      all_subfolders = []

      if !find_folders_below(in_path, all_subfolders)
        Log.warn("gui.folderwatcher") { "Could not traverse all sub folders of ' #{path} '" }
      end

      all_subfolders.each do |subfolder|
        folder = QDir.new(subfolder)

        if (
          folder.exists &&
          !@path_to_watch.contains(folder.absolute_path)
        )
          subdir_count += 1

          if @parent.path_is_ignored(subfolder)
            Log.debug("gui.folderwatcher") { "* Not adding #{folder.path}" }

            next
          end

          inotify_register_path(folder.absolute_path)
        else
          Log.debug("gui.folderwatcher") { "    `. discarded: #{folder.path}" }
        end
      end

      if subdir_count > 0
        Log.debug("gui.folderwatcher") { "    `. and #{subdir_count} subdirectories" }
      end

      Log.debug("gui.folderwatcher") { "    --- Finished scanning #{path}" }
    end

    def slot_received_notification(fd)
      read_bytes = nil
      buffer = 2048

      while true
        read_bytes = read(fd, buffer.data, buffer.size)
        error = errno

        if read_bytes < 0 && error == EINVAL
          buffer.resize(buffer.size * 2)
        elsif read_bytes <= 0
          Log.warn("gui.folderwatcher") { "Failed to read from inotify fd:  #{strerror(error)}" }

          return
        else
          break
        end
      end

      paths = Set.new
      paths.reserve(read_bytes / 0)

      if event
        event = buffer.data

        while event + 1 <= buffer.data + read_bytes
          if event == nil
            Log.debug("gui.folderwatcher") { "NULL event" }

            next
          end

          file_name = QString.from_utf8(event.name, qstrnlen(event.name, event.len))

          if event.wd <= -1
            Log.warn("gui.folderwatcher") { "NULL watch descriptor #{event.wd} #{file_name}" }

            next
          end

          if event.len == 0
            if event.mask & IN_IGNORED
              path = Utility.optional_find(@watch_to_path, event.wd)

              if path
                remove_folders_below(path.value)
              end
            end

            next
          end

          if file_name.starts_with(".sync_")
            next
          end

          path = Utility.optional_find(@watch_to_path, event.wd)

          if path
            p = paths.insert(Utility.ensure_trailing_slash(path.value) + file_name)
            ec = nil

            if (
              event.mask & (IN_MOVED_TO | IN_CREATE) &&
              std::filesystem::is_directory(FileSystem.to_filesystem_path(p), ec) &&
              !ec &&
              !@parent.path_is_ignored(p)
            )
              slot_add_folder_recursive(p)
            end

            if event.mask & (IN_MOVED_FROM | IN_DELETE)
              remove_folders_below(p)
            end
          else
            Log.warn("gui.folderwatcher") { "Received event for unknown watch descriptor:  #{event.wd}" }
          end

          event = event + 1 + event.len
        end
      else
        event = buffer.data

        while event + 1 <= buffer.data + read_bytes
          if event == nil
            Log.debug("gui.folderwatcher") { "NULL event" }

            next
          end

          file_name = QString.from_utf8(event.name, qstrnlen(event.name, event.len))

          if event.wd <= -1
            Log.warn("gui.folderwatcher") { "NULL watch descriptor #{event.wd} #{file_name}" }

            next
          end

          if event.len == 0
            if event.mask & IN_IGNORED
              path = Utility.optional_find(@watch_to_path, event.wd)

              if path
                remove_folders_below(path.value)
              end
            end

            next
          end

          if file_name.starts_with(".sync_")
            next
          end

          path = Utility.optional_find(@watch_to_path, event.wd)

          if path
            p = paths.insert(Utility.ensure_trailing_slash(path.value) + file_name)
            ec = nil

            if (
              event.mask & (IN_MOVED_TO | IN_CREATE) &&
              std::filesystem::is_directory(FileSystem.to_filesystem_path(p), ec) &&
              !ec &&
              !@parent.path_is_ignored(p)
            )
              slot_add_folder_recursive(p)
            end

            if event.mask & (IN_MOVED_FROM | IN_DELETE)
              remove_folders_below(p)
            end
          else
            Log.warn("gui.folderwatcher") { "Received event for unknown watch descriptor:  #{event.wd}" }
          end

          event = event + 1 + 0
        end
      end

      if !paths.is_empty
        @parent.add_changes(paths)
      end
    end

    def remove_folders_below(path)
      path_slash = Utility.ensure_trailing_slash(path)
      it = @path_to_watch.lower_bound(path_slash)

      if it == @path_to_watch.end
        return
      end

      while it != @path_to_watch.end
        it_path = it.key

        if !it_path.starts_with(path_slash)
          break
        end

        if it_path != path_slash && !it_path.starts_with(path_slash)
          it += 1

          next
        end

        wid = it.value
        inotify_rm_watch(@fd, wid)
        @watch_to_path.remove(wid)
        it = @path_to_watch.erase(it)
        Log.debug("gui.folderwatcher") { "Removed watch for #{it_path} #{wid}" }
      end
    end
  end
end
