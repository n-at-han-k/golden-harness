#!/usr/bin/env ruby
#
# Copyright (C) by Duncan Mac-Vicar P. <duncan@kde.org>
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

require_relative "syncengine"

require "qcoreapplication"
require_relative "account"
require_relative "common/asserts"
require_relative "common/syncfilestatus"
require_relative "common/syncjournaldb"
require_relative "common/syncjournalfilerecord"
require_relative "configfile"
require_relative "creds/abstractcredentials"
require_relative "csync_exclude"
require_relative "discovery"
require_relative "discoveryphase"
require_relative "filesystem"
require_relative "owncloudpropagator"
require_relative "propagatedownload"
require_relative "vfs/vfs"

require "chrono"

require "qdir"
require "qloggingcategory"
require "qsslsocket"
require "qstringlist"
require "qtextstream"
require "qtime"
require "qurl"

include std::chrono_literals
include Qt::Literals::StringLiterals

module OCC
  class SyncEngine
    MINIMUM_FILE_AGE_FOR_UPLOAD = 2
    def initialize(account, base_url, local_path, remote_path, journal)
      @account = account
      @base_url = base_url
      @needs_update = false
      @sync_running = false
      @local_path = local_path
      @remote_path = remote_path
      @journal = journal
      @progress_info = ProgressInfo.new
      @upload_limit = 0
      @download_limit = 0
      q_register_meta_type < SyncFileItem > ("SyncFileItem")
      q_register_meta_type < SyncFileItemPtr > ("SyncFileItemPtr")
      q_register_meta_type < SyncFileItem::Status > ("SyncFileItem::Status")
      q_register_meta_type < SyncFileStatus > ("SyncFileStatus")
      q_register_meta_type < SyncFileItemSet > ("SyncFileItemSet")
      q_register_meta_type < SyncFileItem::Direction > ("SyncFileItem::Direction")

      unless local_path.ends_with("/")
        raise
      end

      @excluded_files.reset(ExcludedFiles.new)
      @sync_file_status_tracker.reset(SyncFileStatusTracker.new(this))
    end

    def finalize
      unless !is_sync_running
        raise
      end

      if is_sync_running
        abort("application exit")
      end

      @excluded_files.reset
    end

    def check_error_blacklisting(item)
      if !@journal
        Log.error("sync.engine") { "Journal is undefined!" }

        return false
      end

      entry = @journal.error_blacklist_entry(item.local_name)
      item.has_blacklist_entry = false

      if !entry.is_valid
        return false
      end

      item.has_blacklist_entry = true
      now = Utility.q_date_time_to_time_t(QDateTime.current_date_time_utc)

      if now >= entry.last_try_time + entry.ignore_duration
        Log.info("sync.engine") { "blacklist entry for  #{item.local_name}  has expired!" }

        return false
      end

      if item.direction == :up
        if item.modtime == 0 || entry.last_try_modtime == 0
          return false
        elsif item.modtime != entry.last_try_modtime
          Log.info("sync.engine") { "#{item.local_name}  is blacklisted, but has changed mtime!" }

          return false
        elsif item.rename_target != entry.rename_target
          Log.info("sync.engine") { "#{item.local_name}  is blacklisted, but rename target changed from #{entry.rename_target}" }

          return false
        end
      elsif item.direction == :down
        if item.etag.is_empty || entry.last_try_etag.is_empty
          Log.info("sync.engine") { "#{item.local_name} one ETag is empty, no blacklisting" }

          return false
        elsif item.etag.to_utf8 != entry.last_try_etag
          Log.info("sync.engine") { "#{item.local_name}  is blacklisted, but has changed etag!" }

          return false
        end
      end

      wait_seconds = entry.last_try_time + entry.ignore_duration - now
      Log.info("sync.engine") { "Item is on blacklist:  #{entry.file} retries: #{entry.retry_count} for another #{wait_seconds} s" }
      item.set_instruction(CSYNC_INSTRUCTION_IGNORE)

      if entry.error_category == :local_soft_error
        item.status = :soft_error
        item.error_string = entry.error_string
      else
        item.status = :blacklisted_error
        wait_seconds_str = Utility.duration_to_descriptive_string1(std::chrono::seconds(wait_seconds))
        item.error_string = "#{entry.error_string} (skipped due to earlier error, trying again in #{wait_seconds_str})"

        if entry.error_category == :insufficient_remote_storage
          slot_insufficient_remote_storage
        end
      end

      return true
    end

    def is_file_transfer_instruction(instruction)
      return (
        instruction == CSYNC_INSTRUCTION_CONFLICT ||
        instruction == CSYNC_INSTRUCTION_NEW ||
        instruction == CSYNC_INSTRUCTION_SYNC ||
        instruction == CSYNC_INSTRUCTION_TYPE_CHANGE
      )
    end

    def delete_stale_download_infos(sync_items)
      download_file_paths = Set.new

      sync_items.each do |it|
        if (
          it.direction == :down &&
          it.type == :item_type_file &&
          is_file_transfer_instruction(it.instruction)
        )
          download_file_paths.insert(it.local_name)
        end
      end

      deleted_infos = @journal.get_and_delete_stale_download_infos(download_file_paths)

      deleted_infos.each do |deleted_info|
        tmppath = @propagator.full_local_path(deleted_info.tmpfile)
        Log.info("sync.engine") { "Deleting stale temporary file:  #{tmppath}" }
        FileSystem.remove(tmppath)
      end
    end

    def delete_stale_upload_infos(sync_items)
      upload_file_paths = Set.new

      sync_items.each do |it|
        if (
          it.direction == :up &&
          it.type == :item_type_file &&
          is_file_transfer_instruction(it.instruction)
        )
          upload_file_paths.insert(it.local_name)
        end
      end

      std::ignore = @journal.delete_stale_upload_infos(upload_file_paths)
    end

    def delete_stale_error_blacklist_entries(sync_items)
      blacklist_file_paths = Set.new

      sync_items.each do |it|
        if it.has_blacklist_entry
          blacklist_file_paths.insert(it.local_name)
        end
      end

      @journal.delete_stale_error_blacklist_entries(blacklist_file_paths)
    end

    def conflict_record_maintenance
      conflict_record_paths = @journal.conflict_record_paths

      conflict_record_paths.each do |path|
        fs_path = @propagator.full_local_path(QString.from_utf8(path))

        if !QFileInfo.exists(fs_path)
          @journal.delete_conflict_record(path)
        end
      end

      @seen_conflict_files.each do |path|
        unless Utility.is_conflict_file(path)
          raise
        end

        bapath = path.to_utf8

        if !conflict_record_paths.contains(bapath)
          record = ConflictRecord.new
          record.path = bapath
          base_path = Utility.conflict_file_base_name_from_pattern(path)
          record.initial_base_path = base_path.to_utf8
          base_record = @journal.get_file_record(base_path)

          if base_record.is_valid
            record.base_file_id = base_record.file_id
          end

          @journal.set_conflict_record(record)
        end
      end
    end

    def slot_item_discovered(item)
      if Utility.is_conflict_file(item.local_name)
        @seen_conflict_files.insert(item.local_name)
      end

      if item.instruction == CSYNC_INSTRUCTION_NONE
        if (
          @account.capabilities.upload_conflict_files &&
          Utility.is_conflict_file(item.local_name)
        )
          item.error_string = "Unresolved conflict."
          item.set_instruction(CSYNC_INSTRUCTION_IGNORE)
          item.status = :conflict
        end

        return
      end

      check_error_blacklisting(item)
      @needs_update = true

      unless (lambda {
        it = @sync_items.find(item)

        if it != @sync_items.cend
          item2 = it.get

          Log.warn("sync.engine") {
            "We already have an item for  #{item2.local_name} : #{item2.instruction} #{item2.direction} |" \
              "#{item.instruction} #{item.direction}"
          }

          return false
        end

        return true
      }).call
        raise
      end

      @sync_items.insert(item)
      slot_new_item(item)

      if item.is_directory
        slot_folder_discovered(item.etag.is_empty, item.local_name)
      end
    end

    def start_sync
      if @sync_running
        unless false
          raise
        end

        return
      end

      @duration.reset
      @sync_running = true
      @another_sync_needed = false
      @seen_conflict_files.clear
      @progress_info.reset

      if !QFileInfo.exists(@local_path)
        sync_error("Unable to find local sync folder.")
        finalize(false)

        return
      end

      min_free = critical_free_space_limit
      free_bytes = Utility.free_disk_space(@local_path)

      if free_bytes >= 0
        if free_bytes < min_free
          Log.warn("sync.engine") {
            "Too little space available at #{@local_path} . Have #{free_bytes} bytes and require at least #{min_free}" \
              "bytes"
          }

          sync_error("Only #{Utility.octets_to_string(free_bytes)} are available, need at least #{Utility.octets_to_string(min_free)} to start")
          finalize(false)

          return
        else
          Log.info("sync.engine") { "There are #{Utility.octets_to_string(free_bytes)} available at #{@local_path}" }
        end
      else
        Log.warn("sync.engine") { "Could not determine free space available at #{@local_path}" }
      end

      @sync_items.clear
      @needs_update = false

      if !@journal.exists
        Log.info("sync.engine") { "New sync (no sync journal exists)" }
      else
        Log.info("sync.engine") { "Sync with existing sync journal" }
      end

      Log.info("sync.engine") { "Using Qt  #{q_version}  SSL library  #{QSslSocket.ssl_library_version_string}  on  #{Utility.platform_name}" }

      if !@journal.open
        Log.warn("sync.engine") { "No way to create a sync journal!" }
        sync_error("Unable to open or create the local sync database. Make sure you have write access in the sync folder.")
        finalize(false)

        return
      end

      @journal.clear_etag_storage_filter
      @excluded_files.set_exclude_conflict_files(!@account.capabilities.upload_conflict_files)
      @last_local_discovery_style = @local_discovery_style
      ok = false
      selective_sync_black_list = @journal.get_selective_sync_list(:selective_sync_black_list, ok)

      if ok
        using_selective_sync = !selective_sync_black_list.is_empty

        if using_selective_sync
          Log.info("sync.engine") { "Using Selective Sync" }
        else
          Log.info("sync.engine") { "NOT Using Selective Sync" }
        end
      else
        Log.warn("sync.engine") { "Could not retrieve selective sync list from DB" }
        sync_error("Unable to read the blacklist from the local database")
        finalize(false)

        return
      end

      Log.info("sync.engine") { "#### Discovery start #################################################### #{@duration}" }

      if account.is_http2_supported
        Log.info("sync.engine") { "Server #{account.capabilities.status.version_string} Using HTTP/2" }
      else
        Log.info("sync.engine") { "Server #{account.capabilities.status.version_string} " }
      end

      @progress_info.status = :discovery
      transmission_progress(@progress_info)
      @discovery_phase.reset(DiscoveryPhase.new(@account, sync_options, @base_url))
      @discovery_phase.excludes = @excluded_files.get
      @discovery_phase.statedb = @journal
      @discovery_phase.local_dir = @local_path

      if !@discovery_phase.local_dir.ends_with("/")
        @discovery_phase.local_dir += "/"
      end

      @discovery_phase.remote_folder = @remote_path

      if !@discovery_phase.remote_folder.ends_with("/")
        @discovery_phase.remote_folder += "/"
      end

      @discovery_phase.should_discover_locally = lambda do |s|
        return should_discover_locally(s)
      end

      @discovery_phase.set_selective_sync_black_list(selective_sync_black_list)
      @discovery_phase.set_selective_sync_white_list(@journal.get_selective_sync_list(:selective_sync_white_list, ok))

      if !ok
        Log.warn("sync.engine") { "Unable to read selective sync list, aborting." }
        sync_error("Unable to read from the sync journal.")
        finalize(false)

        return
      end

      invalid_filename_pattern = @account.capabilities.invalid_filename_regex

      if !invalid_filename_pattern.is_empty
        @discovery_phase.invalid_filename_rx = QRegularExpression.new(invalid_filename_pattern)
      end

      @discovery_phase.server_blacklisted_files = @account.capabilities.blacklisted_files
      @discovery_phase.ignore_hidden_files = ignore_hidden_files
      connect(@discovery_phase.get, DiscoveryPhase.item_discovered, this, SyncEngine.slot_item_discovered)
      connect(@discovery_phase.get, DiscoveryPhase.fatal_error, this, SyncEngine.abort)
      connect(@discovery_phase.get, DiscoveryPhase.finished, this, SyncEngine.slot_discovery_finished)

      connect(
        @discovery_phase.get,
        DiscoveryPhase.silently_excluded,
        @sync_file_status_tracker.data,
        SyncFileStatusTracker.slot_add_silently_excluded
      )

      discovery_job = ProcessDirectoryJob.new(@discovery_phase.get, :always_local, @discovery_phase.get)
      @discovery_phase.start_job(discovery_job)
      connect(discovery_job, ProcessDirectoryJob.etag, this, SyncEngine.slot_root_etag_received)
    end

    def slot_folder_discovered(local, folder)
      if !@last_update_progress_callback_call.is_valid
        @last_update_progress_callback_call.start
      elsif @last_update_progress_callback_call.elapsed < 200
        return
      else
        @last_update_progress_callback_call.start
      end

      if local
        @progress_info.current_discovered_local_folder = folder
        @progress_info.current_discovered_remote_folder.clear
      else
        @progress_info.current_discovered_remote_folder = folder
        @progress_info.current_discovered_local_folder.clear
      end

      transmission_progress(@progress_info)
    end

    def slot_root_etag_received(e, time)
      if @remote_root_etag.is_empty
        Log.debug("sync.engine") { "Root etag: #{e}" }
        @remote_root_etag = e
        root_etag(@remote_root_etag, time)
      end
    end

    def slot_new_item(item)
      @progress_info.adjust_totals_for_file(item)
    end

    def slot_discovery_finished
      if !@discovery_phase
        return
      end

      Log.info("sync.engine") { "#### Discovery end #################################################### #{@duration}" }

      if !@journal.open
        Log.warn("sync.engine") { "Bailing out, DB failure" }
        sync_error("Cannot open the sync journal")
        finalize(false)

        return
      else
        @journal.commit_if_needed_and_start_new_transaction("Post discovery")
      end

      @progress_info.current_discovered_remote_folder.clear
      @progress_info.current_discovered_local_folder.clear
      @progress_info.status = :reconcile
      transmission_progress(@progress_info)

      finish = lambda do
        if @discovery_phase.another_sync_needed
          @another_sync_needed = true
        end

        unless std::is_sorted(@sync_items.begin, @sync_items.end)
          raise
        end

        regex = sync_options.file_regex

        if regex.is_valid
          names = Set.new

          @sync_items.each do |i|
            if regex.match(i.local_name).has_match
              index = -1
              ref = ""

              loop do
                ref = QStringView.new(i.local_name).mid(0, index)
                names.insert(ref)
                index = ref.last_index_of("/")

                unless index > 0
                  break
                end
              end
            end
          end

          erase_if = lambda do |c, pred|
            old_size = c.size
            i = c.begin
            last = c.end

            while i != last
              if pred.call(i)
                i = c.erase(i)
              else
                i += 1
              end
            end

            return old_size - c.size
          end

          erase_if.call(@sync_items, lambda do |i|
            return !names.contains(QStringView.new(i.local_name))
          end)
        end

        Log.info("sync.engine") { "#### Reconcile (aboutToPropagate) #################################################### #{@duration}" }
        @local_discovery_paths.clear
        about_to_propagate(@sync_items)
        Log.info("sync.engine") { "#### Reconcile (aboutToPropagate OK) #################################################### #{@duration}" }
        @progress_info.status = :propagation
        transmission_progress(@progress_info)
        @progress_info.start_estimate_updates
        @journal.commit("post treewalk")
        @propagator = OwncloudPropagator.new(@account, sync_options, @base_url, @local_path, @remote_path, @journal)
        connect(@propagator.get, OwncloudPropagator.item_completed, this, SyncEngine.slot_item_completed)
        connect(@propagator.get, OwncloudPropagator.progress, this, SyncEngine.slot_progress)
        connect(@propagator.get, OwncloudPropagator.update_file_total, this, SyncEngine.update_file_total)

        connect(
          @propagator.get,
          OwncloudPropagator.finished,
          this,
          SyncEngine.slot_propagation_finished,
          :queued_connection
        )

        connect(@propagator.get, OwncloudPropagator.seen_locked_file, this, SyncEngine.seen_locked_file)

        connect(
          @propagator.get,
          OwncloudPropagator.insufficient_local_storage,
          this,
          SyncEngine.slot_insufficient_local_storage
        )

        connect(
          @propagator.get,
          OwncloudPropagator.insufficient_remote_storage,
          this,
          SyncEngine.slot_insufficient_remote_storage
        )

        connect(@propagator.get, OwncloudPropagator.new_item, this, SyncEngine.slot_new_item)
        set_network_limits(@upload_limit, @download_limit)
        delete_stale_download_infos(@sync_items)
        delete_stale_upload_infos(@sync_items)
        delete_stale_error_blacklist_entries(@sync_items)
        @journal.commit("post stale entry removal")

        if @needs_update
          started
        end

        @propagator.start(@sync_items)
        Log.info("sync.engine") { "#### Post-Reconcile end #################################################### #{@duration}" }
      end

      finish.call
    end

    def set_network_limits(upload, download)
      @upload_limit = upload
      @download_limit = download

      if @propagator
        if upload != 0 || download != 0
          Log.info("sync.engine") { "Network Limits (down/up)  #{upload} #{download}" }

          if !@propagator.bandwidth_manager
            @propagator.bandwidth_manager = BandwidthManager.new(@propagator.get)
          end
        end

        if @propagator.bandwidth_manager
          @propagator.bandwidth_manager.set_current_upload_limit(upload)
        end
      end
    end

    def slot_item_completed(item)
      unless (lambda {
        finished = item.finished
        item.finished = true

        return !finished
      }).call
        raise
      end

      @progress_info.set_progress_complete(item)
      transmission_progress(@progress_info)
      item_completed(item)
    end

    def slot_propagation_finished(success)
      if @propagator.another_sync_needed
        @another_sync_needed = true
      end

      conflict_record_maintenance
      Log.info("sync.engine") { "Updating files marked as dirty" }

      @journal.get_file_records_with_dirty_placeholders.each do |record|
        @propagator.update_metadata(SyncFileItem.from_sync_journal_file_record(record))
      end

      @journal.commit("All Finished.", false)
      @progress_info.last_completed_item = SyncFileItem.new
      @progress_info.status = :done
      transmission_progress(@progress_info)
      finalize(success)
    end

    def finalize(success)
      unless q_app.thread == thread
        raise
      end

      Log.info("sync.engine") { "Sync run for #{@local_path} took #{@duration}" }
      @duration.stop

      if @discovery_phase
        @discovery_phase.release.delete_later
      end

      @sync_running = false
      finished(success)
      @propagator.reset
      @seen_conflict_files.clear
      @unique_errors.clear
      @local_discovery_paths.clear
      @local_discovery_style = :filesystem_only
    end

    def slot_progress(item, current)
      @progress_info.set_progress_item(item, current)
      transmission_progress(@progress_info)
    end

    def update_file_total(item, new_size)
      @progress_info.update_totals_for_file(item, new_size)
      transmission_progress(@progress_info)
    end

    def account
      return @account
    end

    def set_local_discovery_options(style, paths)
      @local_discovery_style = style
      @local_discovery_paths = paths
      info = @journal.get_upload_infos

      info.each do |i|
        @local_discovery_paths.insert(i.path)
      end

      prev = ""
      it = @local_discovery_paths.begin

      while it != @local_discovery_paths.end
        if (
          !prev.is_null &&
          it.starts_with(prev) &&
          (
            prev.ends_with("/") ||
            it == prev ||
            it.at(prev.size) <= "/"
          )
        )
          it = @local_discovery_paths.erase(it)
        else
          prev = it
          it += 1
        end
      end
    end

    def should_discover_locally(path)
      if @local_discovery_style == :filesystem_only
        return true
      end

      it = @local_discovery_paths.lower_bound(path)

      if it == @local_discovery_paths.end || !it.starts_with(path)
        if (
          it != @local_discovery_paths.begin &&
          path.starts_with(it -= 1)
        )
          return (
            it.ends_with("/") ||
            (path.size > it.size && path.at(it.size) <= "/")
          )
        end

        return false
      end

      if it.size == path.size || path.is_empty
        return true
      end

      while true
        if it.size > path.size && it.at(path.size) == "/"
          return true
        end

        it += 1

        if it == @local_discovery_paths.end || !it.starts_with(path)
          return false
        end
      end

      return false
    end

    def abort(reason)
      aborting = false

      if @propagator
        aborting = true
        @propagator.abort
      elsif @discovery_phase
        aborting = true
        disconnect(@discovery_phase.get, nil, this, nil)
      end

      if aborting
        Log.info("sync.engine") { "Aborting sync" }
        sync_error("Aborted due to: #{reason}")
        finalize(false)
      end
    end

    def slot_summary_error(message)
      if @unique_errors.contains(message)
        return
      end

      @unique_errors.insert(message)
      sync_error(message, :normal)
    end

    def slot_insufficient_local_storage
      slot_summary_error(
        "Disk space is low: Downloads that would reduce free space " \
        "below #{Utility.octets_to_string(free_space_limit)} were skipped."
      )
    end

    def slot_insufficient_remote_storage
      msg = "Space quota exceeded. Please contact the Administrator of this space."

      if @unique_errors.contains(msg)
        return
      end

      @unique_errors.insert(msg)
      sync_error(msg, :insufficient_remote_storage)
    end

    def is_excluded(file_path)
      unless QDir.is_absolute_path(file_path.to_string)
        raise
      end

      return @excluded_files.is_excluded(file_path, local_path, ignore_hidden_files)
    end

    def load_default_excludes
      ConfigFile.setup_default_exclude_file_paths(@excluded_files)

      return @excluded_files.reload_exclude_files
    end

    def clear_manual_excludes
      @excluded_files.clear_manual_excludes
    end

    def reload_excludes
      return @excluded_files.reload_exclude_files
    end

    def add_exclude_list(file_path)
      @excluded_files.add_exclude_file_path(file_path)
    end

    def add_manual_exclude(file_path)
      @excluded_files.add_manual_exclude(file_path)
    end
  end
end
