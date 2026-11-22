#!/usr/bin/env ruby
#
# Copyright (C) by Christian Kamm <mail@ckamm.de>
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

require_relative "localdiscoverytracker"

require_relative "syncfileitem"

require "qloggingcategory"

include OCC

class LocalDiscoveryTracker
  def initialize
  end

  def add_touched_path(relative_path)
    Log.debug("sync.localdiscoverytracker") { "inserted touched #{relative_path}" }
    @local_discovery_paths.insert(relative_path)
  end

  def start_sync_full_discovery
    @local_discovery_paths.clear
    @previous_local_discovery_paths.clear
    Log.debug("sync.localdiscoverytracker") { "full discovery" }
  end

  def start_sync_partial_discovery
    if lc_local_discovery_tracker.is_debug_enabled
      paths = []

      @local_discovery_paths.each do |path|
        paths.append(path)
      end

      Log.debug("sync.localdiscoverytracker") { "partial discovery with paths:  #{paths}" }
    end

    @previous_local_discovery_paths = @local_discovery_paths
    @local_discovery_paths.clear
  end

  def local_discovery_paths
    return @local_discovery_paths
  end

  def slot_item_completed(item)
    case item.status
    when :no_status
      unless item.instruction & (CSYNC_INSTRUCTION_NONE | CSYNC_INSTRUCTION_UPDATE_METADATA)
        Q_FALLTHROUGH()
      end

      Q_FALLTHROUGH()
      Q_FALLTHROUGH()
      Q_FALLTHROUGH()
      Q_FALLTHROUGH()

      if @previous_local_discovery_paths.erase(item.local_name)
        Log.debug("sync.localdiscoverytracker") { "wiped successful item #{item.local_name}" }
      end

      if (
        !item.rename_target.is_empty &&
        @previous_local_discovery_paths.erase(item.rename_target)
      )
        Log.debug("sync.localdiscoverytracker") { "wiped successful item #{item.rename_target}" }
      end

      return
    when :success
      Q_FALLTHROUGH()
      Q_FALLTHROUGH()
      Q_FALLTHROUGH()
      Q_FALLTHROUGH()

      if @previous_local_discovery_paths.erase(item.local_name)
        Log.debug("sync.localdiscoverytracker") { "wiped successful item #{item.local_name}" }
      end

      if (
        !item.rename_target.is_empty &&
        @previous_local_discovery_paths.erase(item.rename_target)
      )
        Log.debug("sync.localdiscoverytracker") { "wiped successful item #{item.rename_target}" }
      end

      return
    when :file_ignored
      Q_FALLTHROUGH()
      Q_FALLTHROUGH()
      Q_FALLTHROUGH()

      if @previous_local_discovery_paths.erase(item.local_name)
        Log.debug("sync.localdiscoverytracker") { "wiped successful item #{item.local_name}" }
      end

      if (
        !item.rename_target.is_empty &&
        @previous_local_discovery_paths.erase(item.rename_target)
      )
        Log.debug("sync.localdiscoverytracker") { "wiped successful item #{item.rename_target}" }
      end

      return
    when :restoration
      Q_FALLTHROUGH()
      Q_FALLTHROUGH()

      if @previous_local_discovery_paths.erase(item.local_name)
        Log.debug("sync.localdiscoverytracker") { "wiped successful item #{item.local_name}" }
      end

      if (
        !item.rename_target.is_empty &&
        @previous_local_discovery_paths.erase(item.rename_target)
      )
        Log.debug("sync.localdiscoverytracker") { "wiped successful item #{item.rename_target}" }
      end

      return
    when :conflict
      Q_FALLTHROUGH()

      if @previous_local_discovery_paths.erase(item.local_name)
        Log.debug("sync.localdiscoverytracker") { "wiped successful item #{item.local_name}" }
      end

      if (
        !item.rename_target.is_empty &&
        @previous_local_discovery_paths.erase(item.rename_target)
      )
        Log.debug("sync.localdiscoverytracker") { "wiped successful item #{item.rename_target}" }
      end

      return
    when :message
      if @previous_local_discovery_paths.erase(item.local_name)
        Log.debug("sync.localdiscoverytracker") { "wiped successful item #{item.local_name}" }
      end

      if (
        !item.rename_target.is_empty &&
        @previous_local_discovery_paths.erase(item.rename_target)
      )
        Log.debug("sync.localdiscoverytracker") { "wiped successful item #{item.rename_target}" }
      end

      return
    when :fatal_error
      Q_FALLTHROUGH()
      Q_FALLTHROUGH()
      Q_FALLTHROUGH()
      Q_FALLTHROUGH()
      Q_FALLTHROUGH()
    when :normal_error
      Q_FALLTHROUGH()
      Q_FALLTHROUGH()
      Q_FALLTHROUGH()
      Q_FALLTHROUGH()
    when :soft_error
      Q_FALLTHROUGH()
      Q_FALLTHROUGH()
      Q_FALLTHROUGH()
    when :detail_error
      Q_FALLTHROUGH()
      Q_FALLTHROUGH()
    when :blacklisted_error
      Q_FALLTHROUGH()
    when :excluded, :filename_reserved
      nil
    when :status_count
      raise
    end

    @local_discovery_paths.insert(item.local_name)
    Log.debug("sync.localdiscoverytracker") { "inserted error item #{item.local_name}" }
  end

  def slot_sync_finished(success)
    if success
      Log.debug("sync.localdiscoverytracker") { "sync success, forgetting last sync's local discovery path list" }
    else
      @local_discovery_paths.insert(@previous_local_discovery_paths.begin, @previous_local_discovery_paths.end)
      Log.debug("sync.localdiscoverytracker") { "sync failed, keeping last sync's local discovery path list" }
    end

    @previous_local_discovery_paths.clear
  end
end
