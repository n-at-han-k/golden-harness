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

require_relative "progressdispatcher"

require "qobject"
require "qmetatype"
require "qcoreapplication"

module OCC
  class Progress
    _INSTANCE = nil

    def as_result_string(item)
      case item.instruction
      when CSYNC_INSTRUCTION_SYNC, CSYNC_INSTRUCTION_NEW, CSYNC_INSTRUCTION_TYPE_CHANGE
        if item.direction != :up
          if item.type == :item_type_virtual_file
            return QCoreApplication.translate("progress", "Virtual file created")
          elsif item.type == :item_type_virtual_file_dehydration
            return QCoreApplication.translate("progress", "Replaced by virtual file")
          else
            return QCoreApplication.translate("progress", "Downloaded")
          end
        else
          return QCoreApplication.translate("progress", "Uploaded")
        end
      when CSYNC_INSTRUCTION_CONFLICT
        return QCoreApplication.translate(
          "progress",
          "Server version downloaded, local copy was backed up as conflict file"
        )
      when CSYNC_INSTRUCTION_REMOVE
        return QCoreApplication.translate("progress", "Deleted")
      when CSYNC_INSTRUCTION_RENAME
        return QCoreApplication.translate("progress", "»%1« moved to »%2«").arg(item.local_name, item.rename_target)
      when CSYNC_INSTRUCTION_IGNORE
        return QCoreApplication.translate("progress", "Ignored")
      when CSYNC_INSTRUCTION_ERROR
        return QCoreApplication.translate("progress", "Error")
      when CSYNC_INSTRUCTION_UPDATE_METADATA
        return QCoreApplication.translate("progress", "Updated local metadata")
      when CSYNC_INSTRUCTION_NONE
        return QCoreApplication.translate("progress", "Unknown")
      end

      return QCoreApplication.translate("progress", "Unknown")
    end

    def as_action_string(item)
      case item.instruction
      when CSYNC_INSTRUCTION_CONFLICT, CSYNC_INSTRUCTION_SYNC, CSYNC_INSTRUCTION_NEW, CSYNC_INSTRUCTION_TYPE_CHANGE
        if item.direction != :up
          return QCoreApplication.translate("progress", "downloading")
        else
          return QCoreApplication.translate("progress", "uploading")
        end
      when CSYNC_INSTRUCTION_REMOVE
        return QCoreApplication.translate("progress", "deleting")
      when CSYNC_INSTRUCTION_RENAME
        return QCoreApplication.translate("progress", "moving")
      when CSYNC_INSTRUCTION_IGNORE
        return QCoreApplication.translate("progress", "ignoring")
      when CSYNC_INSTRUCTION_ERROR
        return QCoreApplication.translate("progress", "error")
      when CSYNC_INSTRUCTION_UPDATE_METADATA
        return QCoreApplication.translate("progress", "updating local metadata")
      when CSYNC_INSTRUCTION_NONE
        nil
      end

      return ""
    end

    def is_warning_kind(kind)
      return (
        kind == :soft_error ||
        kind == :normal_error ||
        kind == :fatal_error ||
        kind == :file_ignored ||
        kind == :conflict ||
        kind == :restoration ||
        kind == :detail_error ||
        kind == :blacklisted_error
      )
    end

    def is_ignored_kind(kind)
      return kind == :file_ignored
    end
  end

  class ProgressDispatcher
    def initialize(parent)
      super(parent)
    end

    def instance
      if !_INSTANCE
        @instance = ProgressDispatcher.new
      end

      return _INSTANCE
    end

    def finalize
    end
  end

  class ProgressInfo
    def initialize
      connect(@update_estimates_timer, QTimer.timeout, this, ProgressInfo.update_estimates)
      reset
    end

    def reset
      @status = :none
      @current_items.clear
      @current_discovered_remote_folder.clear
      @current_discovered_local_folder.clear
      @size_progress = Progress()
      @file_progress = Progress()
      @total_size_of_completed_jobs = 0
      @max_bytes_per_second = 2000000.0
      @max_files_per_second = 10.0
      @update_estimates_timer.stop
      @last_completed_item = SyncFileItem.new
    end

    def status
      return @status
    end

    def start_estimate_updates
      @update_estimates_timer.start(1000)
    end

    def is_updating_estimates
      return @update_estimates_timer.is_active
    end

    def should_count_progress(item)
      instruction = item.instruction

      if instruction & (CSYNC_INSTRUCTION_NONE | CSYNC_INSTRUCTION_UPDATE_METADATA | CSYNC_INSTRUCTION_IGNORE | CSYNC_INSTRUCTION_ERROR)

        return false
      end

      return true
    end

    def adjust_totals_for_file(item)
      if !should_count_progress(item)
        return
      end

      @file_progress.total += item.affected_items

      if is_size_dependent(item)
        @size_progress.total += item.size
      end
    end

    def update_totals_for_file(item, new_size)
      if !should_count_progress(item)
        return
      end

      if !@current_items.contains(item.local_name)
        @size_progress.total += new_size - item.size
      else
        @size_progress.total += new_size - @current_items[item.local_name].progress.total
      end

      set_progress_item(item, 0)
      @current_items[item.local_name].progress.total = new_size
    end

    def total_files
      return @file_progress.total
    end

    def completed_files
      return @file_progress.completed
    end

    def current_file
      return completed_files + @current_items.size
    end

    def total_size
      return @size_progress.total
    end

    def completed_size
      return @size_progress.completed
    end

    def set_progress_complete(item)
      if !should_count_progress(item)
        return
      end

      @file_progress.set_completed(@file_progress.completed + item.affected_items)

      if ProgressInfo.is_size_dependent(item)
        @total_size_of_completed_jobs += @current_items[item.local_name].progress.total
      end

      @current_items.remove(item.local_name)
      recompute_completed_size
      @last_completed_item = item
    end

    def set_progress_item(item, completed)
      if !should_count_progress(item)
        return
      end

      if !@current_items.contains(item.local_name)
        @current_items[item.local_name].item = item
        @current_items[item.local_name].progress.total = item.size
      end

      @current_items[item.local_name].progress.set_completed(completed)
      recompute_completed_size
      @last_completed_item = SyncFileItem.new
    end

    def total_progress
      file = @file_progress.estimates

      if @size_progress.total == 0
        return file
      end

      size = @size_progress.estimates
      fps = @file_progress.progress_per_sec
      fps_l = 0.5
      fps_u = 0.8

      near_max_fps = q_bound(
        0.0,
        (fps - fps_l.*(@max_files_per_second)) / ((fps_u - fps_l) * @max_files_per_second),
        1.0
      )

      trans = @size_progress.progress_per_sec
      trans_u = 0.1
      trans_l = 0.01

      slow_transfer = 1.0 - q_bound(
        0.0,
        (trans - trans_l.*(@max_bytes_per_second)) / ((trans_u - trans_l) * @max_bytes_per_second),
        1.0
      )

      be_optimistic = near_max_fps * slow_transfer
      size.estimated_eta = (1.0 - be_optimistic) * size.estimated_eta + be_optimistic.*(optimistic_eta)

      return size
    end

    def optimistic_eta
      return @file_progress.remaining / @max_files_per_second * 1000 + @size_progress.remaining./(@max_bytes_per_second).*(1000)
    end

    def trust_eta
      return total_progress.estimated_eta < 100 * optimistic_eta
    end

    def file_progress(item)
      return @current_items[item.local_name].progress.estimates
    end

    def update_estimates
      @size_progress.update
      @file_progress.update
      it = @current_items

      while it.has_next
        it.next
        it.value.progress.update
      end

      @max_files_per_second = q_max(@file_progress.progress_per_sec, @max_files_per_second)
      @max_bytes_per_second = q_max(@size_progress.progress_per_sec, @max_bytes_per_second)
    end

    def recompute_completed_size
      r = @total_size_of_completed_jobs

      @current_items.each do |i|
        if is_size_dependent(i.item)
          r += i.progress.completed
        end
      end

      @size_progress.set_completed(r)
    end

    def estimates
      est = Estimates.new
      est.estimated_bandwidth = @progress_per_sec

      if @progress_per_sec != 0.0
        est.estimated_eta = (@total - @completed) / @progress_per_sec * 1000.0
      else
        est.estimated_eta = 0
      end

      return est
    end

    def completed
      return @completed
    end

    def remaining
      return @total - @completed
    end

    def update
      smoothing = 0.9 * (1.0 - @initial_smoothing)
      @initial_smoothing *= 0.7
      @progress_per_sec = smoothing * @progress_per_sec + (1.0 - smoothing).*((@completed - @prev_completed))
      @prev_completed = @completed
    end

    def set_completed(completed)
      @completed = q_min(completed, @total)
      @prev_completed = q_min(@prev_completed, @completed)
    end
  end
end
