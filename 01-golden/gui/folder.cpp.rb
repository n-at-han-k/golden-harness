#!/usr/bin/env ruby
#
# Copyright (C) by Duncan Mac-Vicar P. <duncan@kde.org>
# Copyright (C) by Daniel Molkentin <danimo@owncloud.com>
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

require_relative "folder"

require_relative "account"
require_relative "accountstate"
require_relative "common/filesystembase"
require_relative "common/syncjournalfilerecord"
require_relative "common/version"
require_relative "configfile"
require_relative "filesystem"
require_relative "folderman"
require_relative "guiutility"
require_relative "folderwatcher"
require_relative "gui/folderdefinition"
require_relative "libsync/graphapi/spacesmanager"
require_relative "libsync/vfs/vfs"
require_relative "localdiscoverytracker"
require_relative "scheduling/syncscheduler"
require_relative "syncengine"
require_relative "syncresult"

require "qcoreapplication"
require "qdir"
require "qsettings"
require "qtimer"
require "qurl"

include Qt::Literals::StringLiterals
include std::chrono_literals

module OCC
  include FileSystem::SizeLiterals

  class Folder
    RETRY_SYNC_LIMIT_C = 3
    def initialize(definition, account_state, vfs, parent)
      super(parent)
      @account_state = account_state
      @definition = definition
      @journal = @definition.absolute_journal_path
      @vfs = vfs.release
      @time_since_last_sync_start.start
      @time_since_last_sync_done.start

      if definition.paused
        @sync_result.set_status(:paused)
      else
        @sync_result.set_status(:queued)
      end

      if check_local_path
        @journal.wipe_error_blacklist_category(:local_soft_error)
        @engine.reset(SyncEngine.new(@account_state.account, web_dav_url, path, nil, @journal))
        @engine.set_ignore_hidden_files(@definition.ignore_hidden_files)

        if !@engine.load_default_excludes
          Log.warn("gui.folder") { "Could not read system exclude file" }
          @sync_result.append_error_string("Failed to load excludes")
          set_sync_state(:setup_error)

          return
        end

        connect(@account_state.data, AccountState.is_connected_changed, this, Folder.can_sync_changed)
        context = QObject.new(this)

        connect(@account_state.account.data, Account.capabilities_changed, context) do
          if @account_state.account.capabilities.private_link_property_available
            fetch_private_link_url(@account_state.account, web_dav_url, nil, this) do |private_link_url|
              @web_url = private_link_url
              web_url_changed
              context.delete_later
            end
          else
            context.delete_later
          end
        end

        connect(@engine.data, SyncEngine.finished, this, Folder.slot_sync_finished, :direct_connection)

        connect(@engine.data, SyncEngine.transmission_progress, this) do |pi|
          ProgressDispatcher.instance.progress_info(this, pi)
        end

        connect(@engine.data, SyncEngine.item_completed, this, Folder.slot_item_completed)
        connect(@engine.data, SyncEngine.seen_locked_file, FolderMan.instance, FolderMan.slot_sync_once_file_unlocks)
        connect(@engine.data, SyncEngine.sync_error, this, Folder.slot_sync_error)
        connect(ProgressDispatcher.instance, ProgressDispatcher.folder_conflicts, this, Folder.slot_folder_conflicts)
        @local_discovery_tracker.reset(LocalDiscoveryTracker.new)

        connect(
          @engine.data,
          SyncEngine.finished,
          @local_discovery_tracker.data,
          LocalDiscoveryTracker.slot_sync_finished
        )

        connect(
          @engine.data,
          SyncEngine.item_completed,
          @local_discovery_tracker.data,
          LocalDiscoveryTracker.slot_item_completed
        )

        QTimer.single_shot(0, this, Folder.start_vfs)
      end
    end

    def finalize
      if @vfs
        @vfs.stop
      end

      @engine.reset
    end

    def check_path_length(_path)
      return nil
    end

    def web_url
      return @web_url
    end

    def check_local_path
      error = ""
      @canonical_local_path = @definition.local_path
      fi = QFileInfo.new(@definition.local_path)

      if !FileSystem.file_exists(@definition.local_path, fi)
        error = "Local folder »#{@definition.local_path}« does not exist."
      else
        @canonical_local_path = fi.canonical_file_path

        if @canonical_local_path.is_empty
          Log.warn("gui.folder") { "Broken symlink: #{@definition.local_path}" }
          @canonical_local_path = @definition.local_path
        elsif !@canonical_local_path.ends_with("/")
          @canonical_local_path.append("/")
        end

        if fi.is_dir && fi.is_readable && fi.is_writable
          path_length_check = check_path_length(@canonical_local_path)

          if !path_length_check
            error = path_length_check.error
          end

          result = VfsPluginManager.instance.prepare(path, @account_state.account.uuid, @vfs.mode)

          if !result
            error = result.error
          elsif error.is_empty
            Log.debug("gui.folder") { "Checked local path ok" }

            if !@journal.open
              error = "Failed to open the database for »#{@definition.local_path}«."
            end
          end
        elsif !fi.is_dir
          error = "»#{@definition.local_path}« should be a folder but is not."
        elsif !fi.is_readable
          error = "»#{@definition.local_path}« is not readable."
        elsif !fi.is_writable
          error = "»#{@definition.local_path}« is not writable."
        end
      end

      if !error.is_empty
        Log.warn("gui.folder") { "#{error}" }
        @sync_result.append_error_string(error)
        set_sync_state(:setup_error)

        return false
      end

      return true
    end

    def load_sync_options
      opt = SyncOptions.new(@vfs)
      cfg_file = ConfigFile.new
      opt.move_files_to_trash = cfg_file.move_to_trash
      opt.vfs = @vfs
      account = @account_state.account

      opt.parallel_network_jobs = lambda do
        if account.is_http2_supported
          return 20
        else
          return 6
        end
      end

      return opt
    end

    def set_is_ready(b)
      if b == @vfs_is_ready
        return
      end

      @vfs_is_ready = b
      is_ready_changed
    end

    def prepare_folder(_path, _display_name, _description, _override)
    end

    def display_name
      return @definition.display_name
    end

    def path
      return @canonical_local_path
    end

    def short_gui_local_path
      p = @definition.local_path
      home = QDir.home_path

      if !home.ends_with("/")
        home.append("/")
      end

      if p.starts_with(home)
        p = p.mid(home.length)
      end

      if p.length > 1 && p.ends_with("/")
        p.chop(1)
      end

      return QDir.to_native_separators(p)
    end

    def ignore_hidden_files
      re = @definition.ignore_hidden_files

      return re
    end

    def set_ignore_hidden_files(ignore)
      if @definition.ignore_hidden_files == ignore
        return
      end

      @definition.ignore_hidden_files = ignore
      reload_excludes
    end

    def clean_path
      cleaned_path = QDir.clean_path(@canonical_local_path)

      if cleaned_path.length == 3 && cleaned_path.ends_with(":/")
        cleaned_path.remove(2, 1)
      end

      return cleaned_path
    end

    def is_sync_running
      return @sync_result.status == :sync_running
    end

    def web_dav_url
      space_id = @definition.space_id

      if !space_id.is_empty
        nil
      end

      return @definition.web_dav_url
    end

    def is_sync_paused
      return @definition.paused
    end

    def can_sync
      return (
        @engine &&
        !is_sync_paused &&
        account_state.ready_for_sync &&
        is_ready &&
        @account_state.account.has_capabilities &&
        @folder_watcher
      )
    end

    def is_ready
      return @vfs_is_ready
    end

    def set_sync_paused(paused)
      if has_setup_error
        return
      end

      if paused == @definition.paused
        return
      end

      @definition.paused = paused
      sync_paused_changed(this, paused)

      if !paused
        set_sync_state(:success)
      else
        set_sync_state(:paused)
      end

      can_sync_changed
    end

    def set_sync_state(state)
      old_is_running = is_sync_running

      if state != @sync_result.status
        Log.debug("gui.folder") { "State of #{path} changed to #{state} old state #{@sync_result.status}" }
        @sync_result.set_status(state)
        sync_state_change

        if state == :setup_error
          set_is_ready(false)
        end

        if old_is_running != is_sync_running
          is_sync_running_changed
        end
      end
    end

    def sync_state
      return @sync_result.status
    end

    def sync_result
      return @sync_result
    end

    def show_sync_result_popup
      if @sync_result.first_item_new
        create_gui_log(@sync_result.first_item_new.destination, :log_status_new, @sync_result.num_new_items)
      end

      if @sync_result.first_item_deleted
        create_gui_log(@sync_result.first_item_deleted.destination, :log_status_remove, @sync_result.num_removed_items)
      end

      if @sync_result.first_item_updated
        create_gui_log(@sync_result.first_item_updated.destination, :log_status_updated, @sync_result.num_updated_items)
      end

      if @sync_result.first_item_renamed
        status = :log_status_rename
        ren_target = QFileInfo.new(@sync_result.first_item_renamed.rename_target).dir
        ren_source = QFileInfo.new(@sync_result.first_item_renamed.local_name).dir

        if ren_target != ren_source
          status = :log_status_move
        end

        create_gui_log(
          @sync_result.first_item_renamed.local_name,
          status,
          @sync_result.num_renamed_items,
          @sync_result.first_item_renamed.rename_target
        )
      end

      if @sync_result.first_new_conflict_item
        create_gui_log(
          @sync_result.first_new_conflict_item.destination,
          :log_status_conflict,
          @sync_result.num_new_conflict_items
        )
      end

      error_count = @sync_result.num_error_items

      if error_count != 0
        create_gui_log(@sync_result.first_item_error.local_name, :log_status_error, error_count)
      end

      Log.info("gui.folder") { "Folder #{path} sync result:  #{@sync_result.status}" }
    end

    def create_gui_log(filename, status, count, rename_target)
      if count > 0
        file = QDir.to_native_separators(filename)
        text = ""

        case status
        when :log_status_remove
          if count > 1
            text = "»#{file}« and %n other file(s) have been removed."
          else
            text = "»#{file}« has been removed."
          end
        when :log_status_new
          if count > 1
            text = "»#{file}« and %n other file(s) have been added."
          else
            text = "»#{file}« has been added."
          end
        when :log_status_updated
          if count > 1
            text = "»#{file}« and %n other file(s) have been updated."
          else
            text = "»#{file}« has been updated."
          end
        when :log_status_rename
          if count > 1
            text = "»#{file}« has been renamed to »#{rename_target}« and %n other file(s) have been renamed."
          else
            text = "»#{file}« has been renamed to »#{rename_target}«."
          end
        when :log_status_move
          if count > 1
            text = "»#{file}« has been moved to »#{rename_target}« and %n other file(s) have been moved."
          else
            text = "»#{file}« has been moved to »#{rename_target}«."
          end
        when :log_status_conflict
          if count > 1
            text = "»#{file}« and %n other file(s) have sync conflicts."
          else
            text = "»#{file}« has a sync conflict. Please check the conflict file!"
          end
        when :log_status_error
          if count > 1
            text = "»#{file}« and %n other file(s) could not be synced due to errors. See the log for details."
          else
            text = "»#{file}« could not be synced due to an error. See the log for details."
          end
        end

        if !text.is_empty
          Log.info("gui.folder") { "Sync Activity: #{text}" }
        end
      end
    end

    def start_vfs
      unless @vfs
        raise
      end

      unless @vfs.mode == @definition.virtual_files_mode
        raise
      end

      vfs_params = VfsSetupParams.new(
        @account_state.account,
        web_dav_url,
        @definition.space_id,
        display_name,
        @engine.get
      )

      vfs_params.journal = @journal
      vfs_params.provider_display_name = QCoreApplication.application_name
      vfs_params.provider_name = QCoreApplication.application_name
      vfs_params.provider_version = Version.version
      vfs_params.socket_path = Utility.socket_api_socket_path

      connect(
        @engine.sync_file_status_tracker,
        SyncFileStatusTracker.file_status_changed,
        @vfs.data,
        Vfs.file_status_changed
      )

      connect(@vfs.data, Vfs.started, this) do
        state_db_file = @journal.database_file_path
        @vfs.file_status_changed(state_db_file + "-wal", :status_excluded)
        @vfs.file_status_changed(state_db_file + "-shm", :status_excluded)
        @engine.set_sync_options(load_sync_options)

        if @vfs.mode != :off
          @engine.journal.set_selective_sync_list(:selective_sync_black_list, nil)
        end

        register_folder_watcher

        connect(@vfs.get, Vfs.need_sync, this) do
          if can_sync
            FolderMan.instance.scheduler.enqueue_folder(this, :high)
          end
        end

        set_is_ready(true)
        FolderMan.instance.folder_list_changed

        if can_sync
          FolderMan.instance.scheduler.enqueue_folder(this)
        end
      end

      connect(@vfs.data, Vfs.error, this) do |error|
        @sync_result.append_error_string(error)
        set_sync_state(:setup_error)
      end

      slot_next_sync_full_local_discovery
      @vfs.start(vfs_params)
    end

    def slot_discard_download_progress
      folderpath = QDir.new(@definition.local_path)
      keep_nothing = Set.new
      deleted_infos = @journal.get_and_delete_stale_download_infos(keep_nothing)

      deleted_infos.each do |deleted_info|
        tmppath = folderpath.file_path(deleted_info.tmpfile)
        Log.info("gui.folder") { "Deleting temporary file:  #{tmppath}" }
        FileSystem.remove(tmppath)
      end
    end

    def slot_wipe_error_blacklist
      return @journal.wipe_error_blacklist
    end

    def slot_watched_paths_changed(paths, reason)
      if !is_ready
        return
      end

      need_sync = false

      paths.each do |path|
        unless FileSystem.is_child_path_of(path, this.path)
          raise
        end

        relative_path = path.mid(this.path.size)

        if reason == :un_lock
          journal_db.wipe_error_blacklist_entry(relative_path, :local_soft_error)
          index = 0
          p = relative_path
          index = p.last_index_of("/")

          while index != -1
            p = p.left(index)
            rec = journal_db.error_blacklist_entry(p)

            if rec.is_valid
              if rec.error_category == :local_soft_error
                journal_db.wipe_error_blacklist_entry(p)
              end
            end

            index = p.last_index_of("/")
          end
        end

        @local_discovery_tracker.add_touched_path(relative_path)
        record = @journal.get_file_record(relative_path)

        if reason != :un_lock
          spurious = false

          if (
            record.is_valid &&
            !FileSystem.file_changed(FileSystem.to_filesystem_path(path), FileSystem::FileChangedInfo.from_sync_journal_file_record(record))
          )
            spurious = true
            pin_state = @vfs.pin_state(relative_path)

            if pin_state
              if pin_state == :always_local && record.is_virtual_file
                spurious = false
              end

              if pin_state == :online_only && record.is_file
                spurious = false
              end
            end
          end

          if spurious
            Log.info("gui.folder") { "Ignoring spurious notification for file #{relative_path}" }

            next
          end
        end

        warn_on_new_excluded_item(record, relative_path)
        watched_file_changed_externally(path)
        need_sync = true
      end

      if need_sync && can_sync
        FolderMan.instance.scheduler.enqueue_folder(this)
      elsif (
        !need_sync &&
        @sync_result.status == :queued &&
        FolderMan.instance.scheduler.is_folder_queued(this)
      )
        set_sync_state(:success)
      end
    end

    def set_virtual_files_enabled(enabled)
      new_mode = @definition.virtual_files_mode

      if enabled && @definition.virtual_files_mode == :off
        new_mode = VfsPluginManager.instance.best_available_vfs_mode
      elsif !enabled && @definition.virtual_files_mode != :off
        new_mode = :off
      end

      if new_mode != @definition.virtual_files_mode
        is_paused = @definition.paused

        if !is_paused
          set_sync_paused(true)
        end

        finalize_vfs_switch = lambda do
          ok = false
          old_blacklist = journal_db.get_selective_sync_list(:selective_sync_black_list, ok)
          journal_db.set_selective_sync_list(:selective_sync_black_list, nil)
          @vfs.wipe_dehydrated_virtual_files
          set_is_ready(false)
          @vfs.stop
          @vfs.unregister_folder
          disconnect(@vfs.data, nil, this, nil)
          disconnect(@engine.sync_file_status_tracker, nil, @vfs.data, nil)
          @vfs.reset(VfsPluginManager.instance.create_vfs_from_plugin(new_mode).release)
          @definition.virtual_files_mode = new_mode

          if enabled
            connect(@vfs.data, Vfs.started, this) do
              old_blacklist.each do |entry|
                journal_db.schedule_path_for_remote_discovery(entry)
                std::ignore = vfs.set_pin_state(entry, :online_only)
              end
            end
          end

          if !is_paused
            set_sync_paused(is_paused)
          end

          start_vfs
        end

        if FolderMan.instance.scheduler.current_sync == this
          connect(this, Folder.sync_finished, this, finalize_vfs_switch, :single_shot_connection)
          FolderMan.instance.scheduler.terminate_current_sync("Switching VFS mode on folder »#{display_name}«")
          FolderMan.instance.scheduler.enqueue_folder(this)
        else
          finalize_vfs_switch.call
        end
      end
    end

    def supports_selective_sync
      return !virtual_files_enabled && is_ready
    end

    def is_deployed
      return @definition.is_deployed
    end

    def vfs_mode
      return @vfs.mode
    end

    def priority
      return @definition.priority
    end

    def set_priority(p)
      return @definition.set_priority(p)
    end

    def is_file_excluded_absolute(full_path)
      if !@engine.is_null
        return @engine.is_excluded(full_path)
      end

      return true
    end

    def is_file_excluded_relative(relative_path)
      return is_file_excluded_absolute(path + relative_path)
    end

    def wipe_for_removal
      if has_setup_error
        return
      end

      set_is_ready(false)
      @folder_watcher.reset
      slot_discard_download_progress
      @journal.close
      state_db_file = @engine.journal.database_file_path
      file = QFile.new(state_db_file)

      if file.exists
        if !file.remove
          Log.error("gui.folder") { "Failed to remove existing csync StateDB  #{state_db_file}" }
        else
          Log.info("gui.folder") { "wipe: Removed csync StateDB  #{state_db_file}" }
        end
      else
        Log.warn("gui.folder") { "statedb is empty, can not remove." }
      end

      QFile.remove(state_db_file + ".ctmp")
      QFile.remove(state_db_file + "-shm")
      QFile.remove(state_db_file + "-wal")
      QFile.remove(state_db_file + "-journal")
      @vfs.stop
      @vfs.unregister_folder
      @vfs.reset(nil)
    end

    def reload_excludes
      do_reload = lambda do |start_sheduler|
        @journal.force_remote_discovery_next_sync
        slot_next_sync_full_local_discovery

        if @engine
          if !@engine.reload_excludes
            @sync_result.append_error_string("Failed to load excludes")
            set_sync_state(:setup_error)
          end

          @engine.set_ignore_hidden_files(@definition.ignore_hidden_files)

          if @folder_watcher
            @folder_watcher.restart
          end
        end

        if start_sheduler
          FolderMan.instance.scheduler.start
        end
      end

      if FolderMan.instance.scheduler.current_sync == this
        was_running = FolderMan.instance.scheduler.is_running
        FolderMan.instance.scheduler.stop

        on_sync_finished = lambda do
          do_reload.call(was_running)
          FolderMan.instance.scheduler.enqueue_folder(this)
        end

        connect(this, Folder.sync_finished, this, on_sync_finished, :single_shot_connection | :queued_connection)
        FolderMan.instance.scheduler.terminate_current_sync("Reloading excludes on folder »#{display_name}«")
      else
        do_reload.call(false)
      end
    end

    def start_sync
      unless is_ready
        raise
      end

      unless @folder_watcher
        raise
      end

      if !!is_sync_running
        Log.error("gui.folder") { "ERROR sync is still running and new sync requested." }

        return
      end

      if !can_sync
        Log.error("gui.folder") { "ERROR folder is currently not sync able." }

        return
      end

      @time_since_last_sync_start.start
      @sync_result.reset
      set_sync_state(:sync_running)
      Log.info("gui.folder") { "*** Start syncing  #{display_name} client version #{Version.display_string}" }
      set_dirty_network_limits
      slot_watched_paths_changed(@folder_watcher.pop_change_set, :other)
      full_local_discovery_interval = ConfigFile.new.full_local_discovery_interval
      has_done_full_local_discovery = @time_since_last_full_local_discovery.is_valid

      periodic_full_local_discovery_now = (
        full_local_discovery_interval.count >= 0 &&
        @time_since_last_full_local_discovery.has_expired(full_local_discovery_interval.count)
      )

      if (
        @folder_watcher &&
        @folder_watcher.is_reliable &&
        has_done_full_local_discovery &&
        !periodic_full_local_discovery_now
      )
        Log.info("gui.folder") { "Allowing local discovery to read from the database" }
        @engine.set_local_discovery_options(:database_and_filesystem, @local_discovery_tracker.local_discovery_paths)
        @local_discovery_tracker.start_sync_partial_discovery
      else
        Log.info("gui.folder") { "Forbidding local discovery to read from the database" }
        @engine.set_local_discovery_options(:filesystem_only)
        @local_discovery_tracker.start_sync_full_discovery
      end

      @engine.start_sync
    end

    def set_dirty_network_limits
      unless is_ready
        raise
      end

      cfg = ConfigFile.new
      download_limit = -75
      use_down_limit = cfg.use_download_limit

      if use_down_limit >= 1
        download_limit = cfg.download_limit * 1000
      elsif use_down_limit == 0
        download_limit = 0
      end

      upload_limit = -75
      use_up_limit = cfg.use_upload_limit

      if use_up_limit >= 1
        upload_limit = cfg.upload_limit * 1000
      elsif use_up_limit == 0
        upload_limit = 0
      end

      @engine.set_network_limits(upload_limit, download_limit)
    end

    def reload_sync_options
      @engine.set_sync_options(load_sync_options)
    end

    def slot_sync_error(message, category)
      @sync_result.append_error_string(message)
      ProgressDispatcher.instance.sync_error(this, message, category)
    end

    def slot_sync_finished(success)
      if !is_ready
        return
      end

      Log.info("gui.folder") { "Client version #{Version.display_string}" }
      sync_error = !@sync_result.error_strings.is_empty

      if sync_error
        Log.warn("gui.folder") { "SyncEngine finished with ERROR" }
      else
        Log.info("gui.folder") { "SyncEngine finished without problem." }
      end

      another_sync_needed = false
      sync_status = :undefined

      if sync_error
        sync_status = :error
      elsif @sync_result.found_files_not_synced
        sync_status = :problem
      elsif @definition.paused
        sync_status = :paused
      else
        sync_status = :success
      end

      if sync_status == :success || sync_status == :problem
        @consecutive_failing_syncs = 0
      else
        @consecutive_failing_syncs += 1
        another_sync_needed |= @consecutive_failing_syncs <= RETRY_SYNC_LIMIT_C
        Log.info("gui.folder") { "the last #{@consecutive_failing_syncs} syncs failed" }
      end

      if sync_status == :success && success
        journal_db.set_selective_sync_list(:selective_sync_white_list, nil)
      end

      if (
        (
          sync_status == :success ||
          sync_status == :problem
        ) &&
        success
      )
        if @engine.last_local_discovery_style == :filesystem_only
          @time_since_last_full_local_discovery.start
        end
      end

      if sync_status != :undefined
        set_sync_state(sync_status)
        show_sync_result_popup
      end

      sync_finished(@sync_result)
      @last_sync_duration = std::chrono::milliseconds(@time_since_last_sync_start.elapsed)
      @time_since_last_sync_done.start

      if @engine.is_another_sync_needed
        @consecutive_follow_up_syncs += 1
        another_sync_needed |= @consecutive_follow_up_syncs <= RETRY_SYNC_LIMIT_C
        Log.info("gui.folder") { "another sync was requested by the finished sync, this has happened #{@consecutive_follow_up_syncs} times" }
      else
        @consecutive_follow_up_syncs = 0
      end

      if another_sync_needed && can_sync
        QTimer.single_shot(10, this) { FolderMan.instance.scheduler.enqueue_folder(this) }
      end
    end

    def slot_item_completed(item)
      if (
        item.status == :success &&
        item.instruction & (CSYNC_INSTRUCTION_NONE | CSYNC_INSTRUCTION_UPDATE_METADATA)
      )
        return
      end

      @sync_result.process_completed_item(item)
      ProgressDispatcher.instance.item_completed(this, item)
    end

    def slot_next_sync_full_local_discovery
      @time_since_last_full_local_discovery.invalidate
    end

    def schedule_path_for_local_discovery(relative_path)
      @local_discovery_tracker.add_touched_path(relative_path)
    end

    def slot_folder_conflicts(folder, conflict_paths)
      if folder != this
        return
      end

      r = @sync_result

      if conflict_paths.size > r.num_new_conflict_items + r.num_old_conflict_items
        r.set_num_old_conflict_items(conflict_paths.size - r.num_new_conflict_items)
      end
    end

    def warn_on_new_excluded_item(record, path)
      if record.is_valid
        return
      end

      ok = false
      blacklist = @journal.get_selective_sync_list(:selective_sync_black_list, ok)

      if !ok
        return
      end

      if !blacklist.contains(path + "/")
        return
      end

      fi = QFileInfo.new(@canonical_local_path + path)

      if !fi.exists
        return
      end

      if fi.is_dir
        message = "The folder »#{fi.file_path}« was created but was excluded from synchronization previously. " \
                  "Data inside it will not be synchronized."
      else
        message = "The file »#{fi.file_path}« was created but was excluded from synchronization previously. " \
                  "It will not be synchronized."
      end

      Log.warn("gui.folder") { "» #{fi.file_name} « is not synchronized: #{message}" }
    end

    def slot_watcher_unreliable(message)
      Log.warn("gui.folder") { "Folder watcher for #{path} became unreliable: #{message}" }
    end

    def register_folder_watcher
      if !@folder_watcher.is_null
        return
      end

      @folder_watcher.reset(FolderWatcher.new(this))

      connect(@folder_watcher.data, FolderWatcher.path_changed, this) do |paths|
        slot_watched_paths_changed(paths, :other)
      end

      connect(@folder_watcher.data, FolderWatcher.changes_detected, this) do
        if can_sync && !is_sync_running
          set_sync_state(:queued)
        end
      end

      connect(@folder_watcher.data, FolderWatcher.lost_changes, this, Folder.slot_next_sync_full_local_discovery)
      connect(@folder_watcher.data, FolderWatcher.became_unreliable, this, Folder.slot_watcher_unreliable)
      @folder_watcher.init(path)
    end

    def virtual_files_enabled
      return @definition.virtual_files_mode != :off
    end
  end
end
