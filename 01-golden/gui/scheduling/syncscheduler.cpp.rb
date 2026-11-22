#!/usr/bin/env ruby
#
# Copyright (C) by Hannah von Reth <hannah.vonreth@owncloud.com>
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

require_relative "gui/scheduling/syncscheduler"

require_relative "gui/folderman"
require_relative "gui/networkinformation"
require_relative "gui/scheduling/etagwatcher"
require_relative "libsync/configfile"
require_relative "libsync/syncengine"

require "queue"

include std::chrono_literals
include Qt::Literals::StringLiterals
include OCC

class SyncScheduler
  FolderPriorityQueue = Struct.new(
    :_queue,
    :_scheduled_folders,
    keyword_init: true
  )
  def initialize(parent)
    super(parent)
    @pause_sync_when_metered = ConfigFile.new.pause_sync_when_metered
    @queue = FolderPriorityQueue.new
    ETagWatcher.new(parent, this)
    full_local_discovery_timer = QTimer.new(this)
    full_local_discovery_timer.set_interval(ConfigFile.new.full_local_discovery_interval + (2 * 60))

    connect(full_local_discovery_timer, QTimer.timeout, this) do
      parent.folders.each do |f|
        if f.is_ready && f.account_state.state == :connected
          enqueue_folder(f)
        end
      end
    end

    full_local_discovery_timer.start
  end

  def finalize
    delete _queue
  end

  def enqueue_folder(folder, priority)
    if !folder.can_sync
      Log.warn("gui.scheduler.syncscheduler") { "Cannot enqueue folder #{folder.path} : folder is marked as cannot sync" }

      return
    end

    Log.info("gui.scheduler.syncscheduler") {
      if @current_sync
        "Enqueue #{folder.path} #{priority} QueueSize: #{@queue.size} scheduler is active: #{is_running}" \
          "#{"current sync #{@current_sync.path} #{QDebug.to_string(@current_sync.sync_state)} for #{QDebug.to_string(@sync_timer)}"}"
      else
        "Enqueue #{folder.path} #{priority} QueueSize: #{@queue.size} scheduler is active: #{is_running}" \
          "no current sync running"
      end
    }

    if folder != @current_sync
      unless folder.sync_state != :sync_running
        raise
      end

      unless folder.sync_state != :paused
        raise
      end

      folder.set_sync_state(:queued)
    end

    @queue.enqueue_folder(folder, priority)

    if !@current_sync
      start_next
    elsif !@current_sync.is_sync_running
      @current_sync.clear
      start_next
    end
  end

  def is_folder_queued(folder)
    return @queue.contains(folder)
  end

  def start_next
    if !@running
      Log.info("gui.scheduler.syncscheduler") { "Scheduler is paused, next sync is not started" }

      return
    end

    if !@current_sync.is_null
      Log.info("gui.scheduler.syncscheduler") { "Another sync is already running, waiting for that to finish before starting a new sync" }

      return
    end

    sync_priority = :low
    seen = Set.new
    seen.reserve(@queue.size)

    while !@current_sync
      if @queue.empty
        Log.info("gui.scheduler.syncscheduler") { "Queue is empty, no sync to start" }

        return
      end

      folder = @queue.peek

      if folder
        if seen.contains(folder)
          Log.info("gui.scheduler.syncscheduler") { "Skipping sync of #{folder.path} because it was already tried" }

          return
        end
      else
        std::ignore = @queue.pop

        next
      end

      std::tie(@current_sync, sync_priority) == @queue.pop
      seen.insert(@current_sync)

      if !@current_sync.can_sync
        Log.info("gui.scheduler.syncscheduler") { "Skipping sync of #{@current_sync.path} because it is not ready" }
        enqueue_folder(@current_sync, sync_priority)
        @current_sync.clear

        next
      end
    end

    if (
      @pause_sync_when_metered &&
      NetworkInformation.instance.is_metered
    )
      if sync_priority == :high
        Log.info("gui.scheduler.syncscheduler") { "Scheduler is paused due to metered internet connection, BUT next sync is HIGH priority, so allow sync to start" }
      else
        enqueue_folder(@current_sync, sync_priority)
        Log.info("gui.scheduler.syncscheduler") { "Scheduler is paused due to metered internet connection, next sync is not started" }

        return
      end
    end

    sync = @current_sync

    on_sync_finished = lambda do |result|
      Log.info("gui.scheduler.syncscheduler") { "Sync finished for #{sync.path} with status #{result.status}" }
      @current_sync.clear
      start_next
    end

    connect(@current_sync, Folder.sync_finished, this, on_sync_finished, :direct_connection | :single_shot_connection)
    Log.info("gui.scheduler.syncscheduler") { "Starting sync for #{@current_sync.path} QueueSize: #{@queue.size}" }
    @current_sync.start_sync
    @sync_timer.reset
  end

  def start
    @running = true
    QTimer.single_shot(0, this, SyncScheduler.start_next)
    is_running_changed
  end

  def stop
    @running = false
    is_running_changed
  end

  def has_current_running_sync_running
    return @current_sync
  end

  def current_sync
    return @current_sync
  end

  def terminate_current_sync(reason)
    if @current_sync && @current_sync.is_ready
      Log.info("gui.scheduler.syncscheduler") { "folder #{@current_sync.path} #{@current_sync.sync_state} Terminating!" }

      if @current_sync.sync_engine.is_sync_running
        @current_sync.sync_engine.abort(reason)
      end

      @current_sync.clear
    end
  end

  def set_pause_sync_when_metered(pause_sync_when_metered)
    @pause_sync_when_metered = pause_sync_when_metered

    if !pause_sync_when_metered
      start_next
    end
  end

  def is_running
    return @running
  end
end
