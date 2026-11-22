#!/usr/bin/env ruby
#
# Copyright (C) by Olivier Goffart <ogoffart@owncloud.com>
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

require_relative "propagatorjobs"
require_relative "common/syncjournaldb"
require_relative "common/syncjournalfilerecord"
require_relative "filesystem"
require_relative "owncloudpropagator"
require_relative "owncloudpropagator_p"
require_relative "propagateremotemove"
require "qcoreapplication"
require "qdatetime"
require "qdir"
require "qfile"
require "qsavefile"
require "qstack"
require "qtemporaryfile"

require "time"

module OCC
  class PropagateLocalRemove
    def remove_recursively(absolute)
      removed = []
      locked = []
      errors = []
      success = FileSystem.remove_recursively(absolute, removed, locked, errors)

      if !success
        deleted_dir = ""

        removed.each do |it|
          if !it.path.starts_with(propagator.local_path)
            next
          end

          if !deleted_dir.is_empty && it.path.starts_with(deleted_dir)
            next
          end

          if it.is_dir
            deleted_dir = it.path
          end

          propagator.journal.delete_file_record(it.path.mid(propagator.local_path.size), it.is_dir)
        end

        if !errors.empty
          error_list = []
          error_list.reserve(errors.size)

          errors.each do |err|
            error_list.append("#{QDir.to_native_separators(err.entry.path)} failed with: #{err.error}")
          end

          done(:normal_error, error_list.join(", "))

          return false
        elsif !locked.empty
          error_list = []
          error_list.reserve(errors.size)

          locked.each do |l|
            propagator.seen_locked_file(l.path, :exclusive)
            error_list.append("The file »#{QDir.to_native_separators(l.path)}« is currently in use")
          end

          done(:soft_error, error_list.join(", "))

          return false
        end
      end

      return success
    end

    def start
      @move_to_trash = propagator.sync_options.move_files_to_trash

      if propagator.abort_requested
        return
      end

      filename = propagator.full_local_path(@item.local_name)
      Log.debug("sync.propagator.localremove") { "#{filename}" }
      clash = propagator.local_file_name_clash(@item.local_name)

      if clash
        done(
          :normal_error,
          "Could not remove »#{QDir.to_native_separators(filename)}« because of a local file name clash with »#{QDir.to_native_separators(clash.get)}«!"
        )

        return
      end

      if FileSystem.file_exists(filename)
        if FileSystem.is_file_locked(filename, :exclusive)
          propagator.seen_locked_file(filename, :exclusive)
          done(:soft_error, "The file »#{QDir.to_native_separators(filename)}« is currently in use")

          return
        end

        ok = false
        remove_error = ""

        if @move_to_trash
          ok = QFile.new(filename).move_to_trash

          if !ok
            remove_error = "Could not move »#{filename}« to the trash bin"
          end
        elsif @item.is_directory
          if !ok = remove_recursively(filename)
            return
          end
        else
          ok = FileSystem.remove(filename, remove_error)
        end

        if !ok
          done(:normal_error, remove_error)

          return
        end
      end

      propagator.report_progress(@item, 0)
      propagator.journal.delete_file_record(@item.original_file, @item.is_directory)
      propagator.journal.commit("Local remove")
      done(:success)
    end
  end

  class PropagateLocalMkdir
    def start
      if propagator.abort_requested
        return
      end

      new_dir = QDir.new(propagator.full_local_path(@item.local_name))
      new_dir_str = QDir.to_native_separators(new_dir.path)
      fi = QFileInfo.new(new_dir_str)

      if fi.exists && fi.is_file
        if @delete_existing_file
          Log.debug("sync.propagator.localmkdir") { "deleting existing file #{new_dir_str} to replace it with a dir" }
          remove_error = ""

          if !FileSystem.remove(new_dir_str, remove_error)
            done(:normal_error, "could not delete file »#{new_dir_str}«, error: #{remove_error}")

            return
          end
        elsif @item.instruction == CSYNC_INSTRUCTION_CONFLICT
          error = ""

          if !propagator.create_conflict(@item, @associated_composite, error)
            done(:soft_error, error)

            return
          end
        end
      end

      clash = propagator.local_file_name_clash(@item.local_name)

      if clash
        Log.warn("sync.propagator.localmkdir") { "New folder to create locally already exists with different case: #{@item.local_name}" }

        done(
          :normal_error,
          "Cannot create local folder »#{new_dir_str}« because of a local file name clash with »#{QDir.to_native_separators(clash.get)}«"
        )

        return
      end

      local_dir = QDir.new(propagator.local_path)

      if !local_dir.mkpath(@item.local_name)
        done(:normal_error, "Could not create folder »#{new_dir_str}«")

        return
      end

      new_item = SyncFileItem.new(@item)
      new_item.etag = "_invalid_"
      result = propagator.update_metadata(new_item)

      if !result
        done(:fatal_error, "Error updating metadata: #{result.error}")

        return
      elsif result.get == :locked
        done(:soft_error, "The file »#{new_item.local_name}« is currently in use")

        return
      end

      propagator.journal.commit("localMkdir")

      if @item.instruction == CSYNC_INSTRUCTION_CONFLICT
        result_status = :conflict
      else
        result_status = :success
      end

      done(result_status)
    end

    def set_delete_existing_file(enabled)
      @delete_existing_file = enabled
    end
  end

  class PropagateLocalRename
    def start
      if propagator.abort_requested
        return
      end

      existing_file = propagator.full_local_path(propagator.adjust_renamed_path(@item.local_name))
      target_file = propagator.full_local_path(@item.rename_target)

      if @item.local_name != @item.rename_target
        propagator.report_progress(@item, 0)
        Log.debug("sync.propagator.localrename") { "MOVE  #{existing_file}  =>  #{target_file}" }

        if (
          QString.compare(@item.local_name, @item.rename_target, :case_insensitive) != 0 &&
          propagator.local_file_name_clash(@item.rename_target)
        )
          done(
            :normal_error,
            "The file »#{QDir.to_native_separators(@item.local_name)}« can not be renamed to »#{QDir.to_native_separators(@item.rename_target)}« because of a local file name clash"
          )

          return
        end

        if FileSystem.is_file_locked(existing_file, :exclusive)
          propagator.seen_locked_file(existing_file, :exclusive)
          done(:soft_error, "Could not rename »#{existing_file}« to »#{target_file}«, the file is currently in use")

          return
        end

        rename_error = ""

        if !FileSystem.rename(existing_file, target_file, rename_error)
          done(:normal_error, rename_error)

          return
        end
      end

      old_record = propagator.journal.get_file_record(@item.original_file)
      propagator.journal.delete_file_record(@item.original_file)
      old_file = @item.local_name

      if !@item.is_directory
        new_item = SyncFileItem.new(@item)

        if old_record.is_valid
          new_item.checksum_header = old_record.checksum_header
        end

        result = propagator.update_metadata(new_item)

        if !result
          done(:fatal_error, "Error updating metadata: #{result.error}")

          return
        elsif result.get == :locked
          done(:soft_error, "The file »#{new_item.local_name}« is currently in use")

          return
        end
      else
        propagator.renamed_directories.insert(old_file, @item.rename_target)

        if !PropagateRemoteMove.adjust_selective_sync(propagator.journal, old_file, @item.rename_target)
          done(:fatal_error, "Failed to rename file")

          return
        end
      end

      propagator.journal.commit("localRename")
      done(:success)
    end
  end
end
