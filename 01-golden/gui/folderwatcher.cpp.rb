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

require_relative "folderwatcher"

require "cstdint"

require "qflags"
require "qthread"
require "qtimer"

require_relative "folderwatcher_linux"

require_relative "folder"
require_relative "filesystem"

include std::chrono_literals

module OCC
  class FolderWatcher
    NOTIFICATION_TIMEOUT_C = 10
    def initialize(folder)
      super(folder)
      @folder = folder
      @timer.set_interval(NOTIFICATION_TIMEOUT_C)
      @timer.set_single_shot(true)

      connect(@timer, QTimer.timeout, this) do
        paths = pop_change_set

        unless !paths.empty
          raise
        end

        if !paths.is_empty
          Log.info("gui.folderwatcher") { "Detected changes in paths: #{paths}" }
          path_changed(paths)
        end
      end
    end

    def finalize
    end

    def init(root)
      unless !@d
        raise
      end

      @root = root
      @d.reset(FolderWatcherPrivate.new(this, root))
    end

    def path_is_ignored(path)
      unless !path.is_empty
        raise
      end

      unless @folder
        raise
      end

      if !QFileInfo.exists(path)
        ec = nil

        rel_path = FileSystem.from_filesystem_path(std::filesystem::proximate(
          FileSystem.to_filesystem_path(path),
          FileSystem.to_filesystem_path(@folder.path),
          ec
        ))

        unless !ec
          raise
        end

        if ec
          Log.debug("gui.folderwatcher") { "* Failed to lookup record for path: #{path} error: #{ec.message}" }

          return false
        end

        record = @folder.journal_db.get_file_record(rel_path)

        if record.is_valid
          Log.debug("gui.folderwatcher") { "* Not ignoring removed file #{path}" }

          return false
        end

        Log.debug("gui.folderwatcher") { "* Ignoring file #{path} It no longer exists and we don't have it in the database." }

        return true
      end

      if (
        @folder.is_file_excluded_absolute(path) &&
        !Utility.is_conflict_file(path)
      )
        Log.debug("gui.folderwatcher") { "* Ignoring file #{path}" }

        return true
      end

      return false
    end

    def is_reliable
      return @is_reliable
    end

    def test_linux_watch_count
      return @d.test_watch_count
    end

    def add_changes(paths)
      unless thread == QThread.current_thread
        raise
      end

      unless (
        (!@timer.is_active && @change_set.is_empty) ||
        !@change_set.is_empty
      )
        raise
      end

      unless !paths.is_empty
        raise
      end

      it = paths.cbegin

      while it != paths.cend
        if path_is_ignored(it)
          it = paths.erase(it)
        else
          it += 1
        end
      end

      if !paths.is_empty
        @change_set.unite(paths)

        if !@timer.is_active
          @timer.start
          changes_detected
        end
      end
    end

    def pop_change_set
      @timer.stop

      return @change_set
    end

    def restart
      @d.reset
      @d.reset(FolderWatcherPrivate.new(this, @root))
    end
  end
end
