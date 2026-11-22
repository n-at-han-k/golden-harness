#!/usr/bin/env ruby
#
# Copyright (C) by Klaas Freitag <freitag@owncloud.com>
# Copyright (C) by Jocelyn Turcotte <jturcotte@woboq.com>
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

require_relative "syncfilestatustracker"
require_relative "common/asserts"
require_relative "common/syncjournaldb"
require_relative "common/syncjournalfilerecord"
require_relative "syncengine"

require "qfileinfo"
require "qloggingcategory"

module OCC
  module PathComparator
    def call(_, _)
      sensitivity = Utility.fs_case_sensitivity

      return lhs.compare(rhs, sensitivity) < 0
    end
  end

  class SyncFileStatusTracker
    def initialize(sync_engine)
      @sync_engine = sync_engine
      @case_sensitivity = Utility.fs_case_sensitivity
      connect(sync_engine, SyncEngine.about_to_propagate, this, SyncFileStatusTracker.slot_about_to_propagate)
      connect(sync_engine, SyncEngine.item_completed, this, SyncFileStatusTracker.slot_item_completed)
      connect(sync_engine, SyncEngine.finished, this, SyncFileStatusTracker.slot_sync_finished)
      connect(sync_engine, SyncEngine.started, this, SyncFileStatusTracker.slot_sync_engine_running_changed)
      connect(sync_engine, SyncEngine.finished, this, SyncFileStatusTracker.slot_sync_engine_running_changed)
    end

    def lookup_problem(path_to_match, problem_map)
      lower = problem_map.lower_bound(path_to_match)
      it = lower

      while it != problem_map.cend
        problem_path = it.first
        severity = it.second

        if problem_path.compare(path_to_match, @case_sensitivity) == 0
          return severity
        elsif (
          severity == :status_error &&
          problem_path.starts_with(path_to_match, @case_sensitivity) &&
          (
            path_to_match.is_empty ||
            problem_path.at(path_to_match.size) == "/"
          )
        )
          return :status_warning
        elsif !problem_path.starts_with(path_to_match, @case_sensitivity)
          break
        end

        it += 1
      end

      return :status_none
    end

    def has_error_status(item)
      status = item.status

      return (
        item.instruction == CSYNC_INSTRUCTION_ERROR ||
        status == :normal_error ||
        status == :fatal_error ||
        status == :detail_error ||
        status == :blacklisted_error ||
        item.has_blacklist_entry
      )
    end

    def has_excluded_status(item)
      status = item.status

      return (
        item.instruction == CSYNC_INSTRUCTION_IGNORE ||
        status == :file_ignored ||
        status == :conflict
      )
    end

    def file_status(relative_path)
      unless !relative_path.ends_with("/")
        raise
      end

      if relative_path.is_empty
        return resolve_sync_and_error_status("", :not_shared)
      end

      absolute_path = @sync_engine.local_path + relative_path

      if !QFileInfo.exists(absolute_path)
        return SyncFileStatus.new(:status_none)
      end

      if @sync_engine.is_excluded(absolute_path)
        return SyncFileStatus.new(:status_excluded)
      end

      if @dirty_paths.contains(relative_path)
        return :status_sync
      end

      rec = @sync_engine.journal.get_file_record(relative_path)

      if rec.is_valid
        if rec.remote_perm.has_permission(:is_shared)
          return resolve_sync_and_error_status(relative_path, :shared)
        else
          return resolve_sync_and_error_status(relative_path, :not_shared)
        end
      end

      return resolve_sync_and_error_status(relative_path, :not_shared, :path_unknown)
    end

    def slot_path_touched(file_name)
      folder_path = @sync_engine.local_path

      unless file_name.starts_with(folder_path)
        raise
      end

      local_path = file_name.mid(folder_path.size)
      @dirty_paths.insert(local_path)
      file_status_changed(file_name, :status_sync)
    end

    def slot_add_silently_excluded(folder_path)
      @sync_problems[folder_path] = :status_excluded
      file_status_changed(get_system_destination(folder_path), resolve_sync_and_error_status(folder_path, :not_shared))
    end

    def inc_sync_count_and_emit_status_changed(relative_path, shared_flag)
      count = @sync_count[relative_path] += 1

      if count == 0
        if shared_flag == :unknown_shared
          status = file_status(relative_path)
        else
          status = resolve_sync_and_error_status(relative_path, shared_flag)
        end

        file_status_changed(get_system_destination(relative_path), status)

        unless !relative_path.ends_with("/")
          raise
        end

        last_slash_index = relative_path.last_index_of("/")

        if last_slash_index != -1
          inc_sync_count_and_emit_status_changed(relative_path.left(last_slash_index), :unknown_shared)
        elsif !relative_path.is_empty
          inc_sync_count_and_emit_status_changed("", :unknown_shared)
        end
      end
    end

    def dec_sync_count_and_emit_status_changed(relative_path, shared_flag)
      count = @sync_count[relative_path] -= 1

      if count == 0
        @sync_count.remove(relative_path)

        if shared_flag == :unknown_shared
          status = file_status(relative_path)
        else
          status = resolve_sync_and_error_status(relative_path, shared_flag)
        end

        file_status_changed(get_system_destination(relative_path), status)

        unless !relative_path.ends_with("/")
          raise
        end

        last_slash_index = relative_path.last_index_of("/")

        if last_slash_index != -1
          dec_sync_count_and_emit_status_changed(relative_path.left(last_slash_index), :unknown_shared)
        elsif !relative_path.is_empty
          dec_sync_count_and_emit_status_changed("", :unknown_shared)
        end
      end
    end

    def slot_about_to_propagate(items)
      unless @sync_count.is_empty
        raise
      end

      old_problems = {}
      std::swap(@sync_problems, old_problems)

      items.each do |item|
        Log.debug("sync.statustracker") { "Investigating #{item.destination} #{item.status} #{item.instruction}" }
        @dirty_paths.remove(item.destination)
        @dirty_paths.remove(item.original_file)

        if has_error_status(item)
          @sync_problems[item.destination] = :status_error
          invalidate_parent_paths(item.destination)
        elsif has_excluded_status(item)
          @sync_problems[item.destination] = :status_excluded
        end

        if item.remote_perm.has_permission(:is_shared)
          shared_flag = :shared
        else
          shared_flag = :not_shared
        end

        if item.instruction & (~(CSYNC_INSTRUCTION_NONE | CSYNC_INSTRUCTION_UPDATE_METADATA | CSYNC_INSTRUCTION_IGNORE | CSYNC_INSTRUCTION_ERROR))

          inc_sync_count_and_emit_status_changed(item.destination, shared_flag)
        else
          file_status_changed(
            get_system_destination(item.destination),
            resolve_sync_and_error_status(item.destination, shared_flag)
          )
        end
      end

      old_dirty_paths = Set.new
      std::swap(@dirty_paths, old_dirty_paths)
      it = old_dirty_paths.const_begin

      while it != old_dirty_paths.const_end
        file_status_changed(get_system_destination(it), file_status(it))
        it += 1
      end

      it = @sync_problems.begin

      while it != @sync_problems.end
        old_problems.erase(it.first)
        it += 1
      end

      it = old_problems.begin

      while it != old_problems.end
        path = it.first
        severity = it.second

        if severity == :status_error
          invalidate_parent_paths(path)
        end

        file_status_changed(get_system_destination(path), file_status(path))
        it += 1
      end
    end

    def slot_item_completed(item)
      Log.debug("sync.statustracker") { "Item completed #{item.destination} #{item.status} #{item.instruction}" }

      if has_error_status(item)
        @sync_problems[item.destination] = :status_error
        invalidate_parent_paths(item.destination)
      elsif has_excluded_status(item)
        @sync_problems[item.destination] = :status_excluded
      else
        @sync_problems.erase(item.destination)
      end

      if item.remote_perm.has_permission(:is_shared)
        shared_flag = :shared
      else
        shared_flag = :not_shared
      end

      if item.instruction & (~(CSYNC_INSTRUCTION_NONE | CSYNC_INSTRUCTION_UPDATE_METADATA | CSYNC_INSTRUCTION_IGNORE | CSYNC_INSTRUCTION_ERROR))

        dec_sync_count_and_emit_status_changed(item.destination, shared_flag)
      else
        file_status_changed(
          get_system_destination(item.destination),
          resolve_sync_and_error_status(item.destination, shared_flag)
        )
      end
    end

    def slot_sync_finished
      old_sync_count = {}
      std::swap(@sync_count, old_sync_count)
      it = old_sync_count.begin

      while it != old_sync_count.end
        file_status_changed(get_system_destination(it.key), file_status(it.key))
        it += 1
      end
    end

    def slot_sync_engine_running_changed
      file_status_changed(get_system_destination(""), resolve_sync_and_error_status("", :not_shared))
    end

    def resolve_sync_and_error_status(relative_path, shared_flag, is_path_known)
      if is_path_known != 0
        status = SyncFileStatus.new(:status_up_to_date)
      else
        status = SyncFileStatus.new(:status_none)
      end

      if @sync_count.value(relative_path)
        status.set(:status_sync)
      else
        problem_status = lookup_problem(relative_path, @sync_problems)

        if problem_status != :status_none
          status.set(problem_status)
        end
      end

      unless shared_flag != :unknown_shared
        raise
      end

      if shared_flag == :shared
        status.set_shared(true)
      end

      return status
    end

    def invalidate_parent_paths(path)
      split_path = path.split("/", :skip_empty_parts)

      (0...split_path.size).each do |i|
        parent_path = QStringList.new(split_path.mid(0, i)).join("/")
        file_status_changed(get_system_destination(parent_path), file_status(parent_path))
      end
    end

    def get_system_destination(relative_path)
      system_path = @sync_engine.local_path + relative_path

      if system_path.ends_with("/")
        system_path.truncate(system_path.length - 1)
      end

      return system_path
    end
  end
end
