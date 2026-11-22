#!/usr/bin/env ruby
#
# Copyright (C) by Duncan Mac-Vicar P. <duncan@kde.org>
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

require_relative "syncresult"
require_relative "progressdispatcher"

require "qcoreapplication"

module OCC
  class SyncResult
    def initialize(status)
      @status = status
    end

    def status
      return @status
    end

    def reset
      this =
      SyncResult.new
    end
  end

  module Utility
    def enum_to_display_name(status)
      case status
      when :undefined
        return QCoreApplication.translate("SyncResult::Status", "Undefined")
      when :queued
        return QCoreApplication.translate("SyncResult::Status", "Queued")
      when :sync_running
        return QCoreApplication.translate("SyncResult::Status", "Sync running")
      when :success
        return QCoreApplication.translate("SyncResult::Status", "Success")
      when :error
        return QCoreApplication.translate("SyncResult::Status", "Error")
      when :setup_error
        return QCoreApplication.translate("SyncResult::Status", "Setup error")
      when :problem
        return QCoreApplication.translate("SyncResult::Status", "Success, some files were ignored.")
      when :paused
        return QCoreApplication.translate("SyncResult::Status", "Sync paused")
      when :offline
        return QCoreApplication.translate("SyncResult::Status", "Offline")
      end

      raise
    end
  end

  class SyncResult
    def set_status(stat)
      @status = stat
      @sync_time = QDateTime.current_date_time_utc
    end

    def sync_time
      return @sync_time
    end

    def error_strings
      return @errors
    end

    def append_error_string(err)
      @errors.append(err)
    end

    def error_string
      if @errors.is_empty
        return nil
      end

      return @errors.first
    end

    def clear_errors
      @errors.clear
    end

    def process_completed_item(item)
      if Progress.is_warning_kind(item.status)
        @found_files_not_synced = true
      end

      if (
        item.is_directory &&
        item.instruction & (CSYNC_INSTRUCTION_NEW | CSYNC_INSTRUCTION_TYPE_CHANGE | CSYNC_INSTRUCTION_REMOVE | CSYNC_INSTRUCTION_RENAME)
      )
        @folder_structure_was_changed = true
      end

      if item.status == :fatal_error || item.status == :normal_error
        append_error_string(QObject.tr("%1: %2").arg(item.local_name, item.error_string))
        @num_error_items += 1

        if !@first_item_error
          @first_item_error = item
        end
      elsif item.status == :conflict
        if item.instruction == CSYNC_INSTRUCTION_CONFLICT
          @num_new_conflict_items += 1

          if !@first_new_conflict_item
            @first_new_conflict_item = item
          end
        else
          @num_old_conflict_items += 1
        end
      elsif (
        !item.has_error_status &&
        item.status != :file_ignored &&
        item.direction == :down
      )
        case item.instruction
        when CSYNC_INSTRUCTION_NEW, CSYNC_INSTRUCTION_TYPE_CHANGE
          @num_new_items += 1

          if !@first_item_new
            @first_item_new = item
          end
        when CSYNC_INSTRUCTION_REMOVE
          @num_removed_items += 1

          if !@first_item_deleted
            @first_item_deleted = item
          end
        when CSYNC_INSTRUCTION_SYNC
          @num_updated_items += 1

          if !@first_item_updated
            @first_item_updated = item
          end
        when CSYNC_INSTRUCTION_RENAME
          if !@first_item_renamed
            @first_item_renamed = item
          end

          @num_renamed_items += 1
        end
      elsif (
        item.instruction == CSYNC_INSTRUCTION_IGNORE &&
        item.has_blacklist_entry
      )
        if item.has_blacklist_entry
          @num_blacklist_errors += 1
        end

        @found_files_not_synced = true
      end
    end

    def num_blacklist_errors
      return @num_blacklist_errors
    end

    def glype
      case status
      when :queued, :sync_running
        return "u'"
      when :paused
        return "u'"
      when :success
        if !has_unresolved_conflicts
          return "u'"
        end

        return "u'"
      when :problem, :undefined
        return "u'"
      when :offline
        return "u'"
      when :error, :setup_error
        return "u'"
      end

      raise
    end
  end
end
