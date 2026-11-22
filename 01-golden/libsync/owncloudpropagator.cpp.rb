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

require_relative "owncloudpropagator"
require_relative "account"
require_relative "common/asserts"
require_relative "common/syncjournaldb"
require_relative "common/syncjournalfilerecord"
require_relative "common/utility"
require_relative "discoveryphase"
require_relative "filesystem"
require_relative "propagatedownload"
require_relative "propagateremotedelete"
require_relative "propagateremotemkdir"
require_relative "propagateremotemove"
require_relative "propagateupload"
require_relative "propagateuploadtus"
require_relative "propagatorjobs"

require "qcoreapplication"
require "qdir"
require "qfileinfo"
require "qloggingcategory"
require "qobject"
require "qstack"
require "qtimer"
require "qmath"

include std::chrono_literals

module OCC
  class OwncloudPropagator
    GET_MIN_BLACKLIST_TIME = 5
    GET_MAX_BLACKLIST_TIME = (24 * 3600)
    def critical_free_space_limit
      return q_bound(0, 50 * 1000 * 1000, free_space_limit)
    end

    def free_space_limit
      return 250 * 1000 * 1000
    end

    def finalize
    end

    def maximum_active_transfer_job
      if @bandwidth_manager || !@sync_options.parallel_network_jobs
        return 1
      end

      return std::max(3, q_ceil(@sync_options.parallel_network_jobs / 2.0))
    end

    def hard_maximum_active_job
      if !@sync_options.parallel_network_jobs
        return 1
      end

      return @sync_options.parallel_network_jobs
    end
  end

  class PropagateItemJob
    def finalize
      p = propagator

      if p
        p.active_job_list.remove_all(this)
      end
    end

    def schedule_self_or_child
      if state != :not_yet_started
        return false
      end

      Log.info("sync.propagator") { "Starting propagation of #{@item} by #{this}" }
      set_state(:running)

      if thread != QCoreApplication.instance.thread
        QMetaObject.invoke_method(this, PropagateItemJob.start)
      else
        start
      end

      return true
    end

    def create_blacklist_entry(old, item)
      entry = SyncJournalErrorBlacklistRecord.new
      entry.file = item.local_name
      entry.error_string = item.error_string
      entry.last_try_modtime = item.modtime
      entry.last_try_etag = item.etag.to_utf8
      entry.last_try_time = Utility.q_date_time_to_time_t(QDateTime.current_date_time_utc)
      entry.rename_target = item.rename_target
      entry.retry_count = old.retry_count + 1
      entry.request_id = item.request_id
      min_blacklist_time = GET_MIN_BLACKLIST_TIME.count
      max_blacklist_time = q_max(GET_MAX_BLACKLIST_TIME.count, min_blacklist_time)
      entry.ignore_duration = old.ignore_duration * 5

      if item.http_error_code == 403
        Log.warn("sync.propagator") { "Probably firewall error:  #{item.http_error_code} , blacklisting up to 1h only" }
        entry.ignore_duration = q_min(entry.ignore_duration, 60 * 60)
      elsif item.http_error_code == 413 || item.http_error_code == 415
        Log.warn("sync.propagator") { "Fatal Error condition #{item.http_error_code} , maximum blacklist ignore time!" }
        entry.ignore_duration = max_blacklist_time
      end

      entry.ignore_duration = q_bound(min_blacklist_time, entry.ignore_duration, max_blacklist_time)

      if item.http_error_code == 507
        entry.error_category = :insufficient_remote_storage
      elsif item.http_error_code == 0 && item.status == :soft_error
        entry.error_category = :local_soft_error
      end

      return entry
    end

    def blacklist_update(journal, item)
      old_entry = journal.error_blacklist_entry(item.local_name)

      may_blacklist = (
        item.status == :normal_error ||
        item.status == :soft_error ||
        item.status == :detail_error
      )

      if !may_blacklist
        if old_entry.is_valid
          journal.wipe_error_blacklist_entry(item.local_name)
        end

        return
      end

      new_entry = create_blacklist_entry(old_entry, item)
      journal.set_error_blacklist_entry(new_entry)

      if (
        item.status == :soft_error &&
        new_entry.retry_count > 1 &&
        item.http_error_code != 0
      )
        Log.warn("sync.propagator") { "escalating http soft error on  #{item.local_name}  to normal error,  #{item.http_error_code}" }
        item.status = :normal_error
      elsif (
        item.status != :soft_error &&
        item.has_blacklist_entry &&
        new_entry.ignore_duration > 0
      )
        item.status = :blacklisted_error
      end

      Log.info("sync.propagator") { "blacklisting  #{item.local_name}  for  #{new_entry.ignore_duration} , retry count  #{new_entry.retry_count}" }
    end

    def done(status_arg, error_string)
      unless state != :finished
        raise
      end

      set_state(:finished)
      @item.status = status_arg

      if @item.is_restoration
        if @item.status == :success || @item.status == :conflict
          @item.status = :restoration
        else
          @item.error_string += "; Restoration Failed: #{error_string}"
        end
      elsif @item.error_string.is_empty
        @item.error_string = error_string
      end

      if (
        propagator.abort_requested &&
        (
          @item.status == :normal_error ||
          @item.status == :fatal_error
        )
      )
        @item.status = :soft_error
      end

      case @item.status
      when :soft_error, :fatal_error, :normal_error, :detail_error, :message
        blacklist_update(propagator.journal, @item)
      when :success, :restoration
        if @item.has_blacklist_entry
          propagator.journal.wipe_error_blacklist_entry(@item.local_name)

          if @item.original_file != @item.local_name
            propagator.journal.wipe_error_blacklist_entry(@item.original_file)
          end
        end
      when :conflict, :file_ignored, :no_status, :blacklisted_error, :excluded, :filename_reserved
        nil
      when :status_count
        raise
      end

      if @item.has_error_status
        Log.warn("sync.propagator") {
          "Could not complete propagation of #{@item.destination} by #{this} with status #{@item.status}" \
            "and error: #{@item.error_string}"
        }
      else
        Log.info("sync.propagator") { "Completed propagation of #{@item.destination} by #{this} with status #{@item.status}" }
      end

      if !@item.is_directory || @item.relevant_directoy_instruction
        unless (
          !@item.relevant_directoy_instruction ||
          qobject_cast < PropagateDirectory > (this)
        )
          raise
        end

        propagator.item_completed(@item)
      else
        @item.relevant_directoy_instruction = true
      end

      finished(@item.status)

      if @item.status == :fatal_error
        propagator.abort
      end
    end
  end

  class OwncloudPropagator
    def create_job(item)
      Log.debug("sync.propagator") { "Propagating: #{item}" }
      delete_existing = item.instruction == CSYNC_INSTRUCTION_TYPE_CHANGE

      case item.instruction
      when CSYNC_INSTRUCTION_REMOVE
        if item.direction == :down
          return PropagateLocalRemove.new(this, item)
        else
          return PropagateRemoteDelete.new(this, item)
        end
      when CSYNC_INSTRUCTION_NEW, CSYNC_INSTRUCTION_TYPE_CHANGE, CSYNC_INSTRUCTION_CONFLICT
        if item.is_directory
          if item.direction != :up
            job = PropagateLocalMkdir.new(this, item)
            job.set_delete_existing_file(delete_existing)

            return job
          else
            job = PropagateRemoteMkdir.new(this, item)
            job.set_delete_existing(delete_existing)

            return job
          end
        end

        if item.direction != :up
          job = PropagateDownloadFile.new(this, item)
          job.set_delete_existing_folder(delete_existing)

          return job
        else
          job = nil

          if account.capabilities.tus_support.is_valid
            job = PropagateUploadFileTUS.new(this, item)
          else
            job = PropagateUploadFileV1.new(this, item)
          end

          job.set_delete_existing(delete_existing)

          return job
        end
      when CSYNC_INSTRUCTION_SYNC
        if item.direction != :up
          job = PropagateDownloadFile.new(this, item)
          job.set_delete_existing_folder(delete_existing)

          return job
        else
          job = nil

          if account.capabilities.tus_support.is_valid
            job = PropagateUploadFileTUS.new(this, item)
          else
            job = PropagateUploadFileV1.new(this, item)
          end

          job.set_delete_existing(delete_existing)

          return job
        end
      when CSYNC_INSTRUCTION_RENAME
        if item.direction == :up
          return PropagateRemoteMove.new(this, item)
        else
          return PropagateLocalRename.new(this, item)
        end
      when CSYNC_INSTRUCTION_UPDATE_METADATA
        if item.is_directory
          return nil
        end

        return PropagateUpdateMetaDataJob.new(this, item)
      when CSYNC_INSTRUCTION_IGNORE, CSYNC_INSTRUCTION_ERROR
        return PropagateIgnoreJob.new(this, item)
      when CSYNC_INSTRUCTION_NONE
        return nil
      end

      raise
    end

    def small_file_size
      small_file_size = 100 * 1024

      return small_file_size
    end

    def start(items)
      @root_job.reset(PropagateRootDirectory.new(this))
      directories = []
      directories.push(["", @root_job.data])
      current_remove_directory_job = nil
      maybe_conflict_directory = ""

      items.each do |item|
        if (
          current_remove_directory_job &&
          FileSystem.is_child_path_of(item.local_name, current_remove_directory_job.path)
        )
          if item.instruction == CSYNC_INSTRUCTION_REMOVE
            del_dir_job = qobject_cast < PropagateDirectory > (current_remove_directory_job)

            if del_dir_job
              del_dir_job.increase_affected_count
            end

            next
          elsif (
            item.is_directory &&
            item.instruction & (CSYNC_INSTRUCTION_NEW | CSYNC_INSTRUCTION_TYPE_CHANGE)
          )
            del_dir_job = qobject_cast < PropagateDirectory > (current_remove_directory_job)

            if del_dir_job
              del_dir_job.increase_affected_count
            end

            next
          elsif item.instruction & (CSYNC_INSTRUCTION_IGNORE | CSYNC_INSTRUCTION_NONE)
            next
          elsif item.instruction != CSYNC_INSTRUCTION_RENAME
            Log.warn("sync.propagator") { "WARNING:  Job within a removed directory?  This should not happen! #{item}" }

            unless false
              raise
            end
          end
        end

        if !maybe_conflict_directory.is_empty
          if FileSystem.is_child_path_of(item.destination, maybe_conflict_directory)
            Log.info("sync.propagator") { "Skipping job inside CONFLICT directory #{item.local_name} #{item.instruction}" }
            item.set_instruction(CSYNC_INSTRUCTION_NONE)

            next
          else
            maybe_conflict_directory.clear
          end
        end

        while !FileSystem.is_child_path_of(item.destination, directories.top.first)
          directories.pop
        end

        if item.is_directory
          dir = PropagateDirectory.new(this, item)

          if (
            item.instruction == CSYNC_INSTRUCTION_TYPE_CHANGE &&
            item.direction == :up
          )
            items.each do |item2|
              if (
                item2 != item &&
                FileSystem.is_child_path_of(item2.destination, item.destination)
              )
                item2.set_instruction(CSYNC_INSTRUCTION_NONE)
                @another_sync_needed = true
              end
            end
          end

          if item.instruction == CSYNC_INSTRUCTION_REMOVE
            current_remove_directory_job = dir
            @root_job.add_delete_job(current_remove_directory_job)

            directories.each do |directory|
              if directory.second.item.instruction == CSYNC_INSTRUCTION_UPDATE_METADATA
                directory.second.item.set_instruction(CSYNC_INSTRUCTION_NONE)
                @another_sync_needed = true
              end
            end
          else
            directories.top.second.append_job(dir)
          end

          directories.push(q_make_pair(item.destination, dir))
        else
          if item.instruction == CSYNC_INSTRUCTION_TYPE_CHANGE
            current_remove_directory_job = create_job(item)
            @root_job.add_delete_job(current_remove_directory_job)
          else
            directories.top.second.append_task(item)
          end

          if item.instruction == CSYNC_INSTRUCTION_CONFLICT
            maybe_conflict_directory = item.local_name
          end
        end
      end

      connect(@root_job.data, PropagatorJob.finished, this, OwncloudPropagator.emit_finished)
      @job_scheduled = false
      schedule_next_job
    end

    def sync_options
      return @sync_options
    end

    def local_file_name_clash(rel_file)
      unless !rel_file.is_empty
        raise
      end

      if !rel_file.is_empty && Utility.fs_case_preserving
        file_info = QFileInfo.new(@local_dir + rel_file)
        fn = file_info.file_name
        list = file_info.dir.entry_list([fn])

        if (
          list.count > 1 ||
          (
            list.count == 1 &&
            list[0] != fn
          )
        )
          return list[0]
        end
      end

      return false
    end

    def has_case_clash_accessibility_problem(_relfile)
      return false
    end

    def full_local_path(tmp_file_name)
      return @local_dir + tmp_file_name
    end

    def local_path
      return @local_dir
    end

    def schedule_next_job
      if @job_scheduled
        return
      end

      @job_scheduled = true
      QTimer.single_shot(0, this, OwncloudPropagator.schedule_next_job_impl)
    end

    def schedule_next_job_impl
      @job_scheduled = false

      if @active_job_list.count < maximum_active_transfer_job
        if @root_job.schedule_self_or_child
          schedule_next_job
        end
      elsif @active_job_list.count < hard_maximum_active_job
        likely_finished_quickly_count = 0
        i = 0

        while (
          i < maximum_active_transfer_job &&
          i < @active_job_list.count
        )
          if @active_job_list.at(i).is_likely_finished_quickly
            likely_finished_quickly_count += 1
          end

          i += 1
        end

        if @active_job_list.count < maximum_active_transfer_job + likely_finished_quickly_count
          Log.debug("sync.propagator") { "Can pump in another request! activeJobs = #{@active_job_list.count}" }

          if @root_job.schedule_self_or_child
            schedule_next_job
          end
        end
      end
    end

    def report_file_total(item, new_size)
      update_file_total(item, new_size)
    end

    def abort
      if @abort_requested
        return
      end

      if @root_job
        connect(@root_job.data, PropagateDirectory.abort_finished, this, OwncloudPropagator.emit_finished)
        QMetaObject.invoke_method(@root_job.data, lambda { @root_job.abort(:asynchronous) }, :queued_connection)
        QTimer.single_shot(5, this, OwncloudPropagator.abort_timeout)
      else
        emit_finished(:normal_error)
      end
    end

    def report_progress(item, bytes)
      progress(item, bytes)
    end

    def account
      return @account
    end

    def disk_space_check
      free_bytes = Utility.free_disk_space(@local_dir)

      if free_bytes < 0
        return :disk_space_ok
      end

      if free_bytes < critical_free_space_limit
        return :disk_space_critical
      end

      if free_bytes - @root_job.committed_disk_space < free_space_limit
        return :disk_space_failure
      end

      return :disk_space_ok
    end

    def create_conflict(item, composite, error)
      fn = full_local_path(item.local_name)
      rename_error = ""
      conflict_mod_time = FileSystem.get_mod_time(fn)
      conflict_user_name = ""

      if account.capabilities.upload_conflict_files
        conflict_user_name = account.dav_display_name
      end

      conflict_file_name = Utility.make_conflict_file_name(
        item.local_name,
        Utility.q_date_time_from_time_t(conflict_mod_time),
        conflict_user_name
      )

      conflict_file_path = full_local_path(conflict_file_name)

      if FileSystem.is_file_locked(fn, :exclusive)
        seen_locked_file(fn, :exclusive)

        if error
          error = "The file »#{fn}« is currently in use"
        end

        return false
      end

      if !FileSystem.rename(fn, conflict_file_path, rename_error)
        if error
          error = rename_error
        end

        return false
      end

      Log.info("sync.propagator") { "Created conflict file #{fn} . #{conflict_file_name}" }
      conflict_record = ConflictRecord.new
      conflict_record.path = conflict_file_name.to_utf8
      conflict_record.base_modtime = item.previous_modtime
      conflict_record.initial_base_path = item.local_name.to_utf8
      base_record = @journal.get_file_record(item.original_file)

      if base_record.is_valid
        conflict_record.base_etag = base_record.etag.to_utf8
        conflict_record.base_file_id = base_record.file_id
      end

      @journal.set_conflict_record(conflict_record)

      if account.capabilities.upload_conflict_files
        if composite && !QFileInfo.new(conflict_file_path).is_dir
          conflict_item = SyncFileItemPtr.new(SyncFileItem.new)
          conflict_item.set_local_name(conflict_file_name)
          conflict_item.type = :item_type_file
          conflict_item.direction = :up
          conflict_item.set_instruction(CSYNC_INSTRUCTION_NEW)
          conflict_item.modtime = conflict_mod_time
          conflict_item.size = item.previous_size
          new_item(conflict_item)
          composite.append_task(conflict_item)
        else
          @another_sync_needed = true
        end
      end

      return true
    end

    def adjust_renamed_path(original)
      return OCC.adjust_renamed_path(@renamed_directories, original)
    end

    def update_placeholder(item, file_name, replaces_file)
      unless (lambda {
        if item.type == :item_type_virtual_file_dehydration
          pin = sync_options.vfs.pin_state(item.local_name)

          if pin && pin.get == :always_local
            return false
          end
        end

        return true
      }).call
        raise
      end

      return sync_options.vfs.update_metadata(item, file_name, replaces_file)
    end

    def update_metadata(item)
      fs_path = full_local_path(item.destination)

      if !QFileInfo.exists(fs_path)
        Log.warn("sync.propagator") { "Skipping updateMetadata on: #{fs_path} the file does no longer exist." }

        return :ok
      end

      result = update_placeholder(item, fs_path, nil)

      if !result
        return result
      end

      item_copy = item
      inode = FileSystem.get_inode(FileSystem.to_filesystem_path(fs_path))

      if inode
        item_copy.inode = inode.value
      else
        Log.warn("sync.propagator") { "Failed to get inode for #{fs_path}" }
      end

      Log.debug("sync.propagator") { "#{fs_path} Retrieved inode  #{item_copy.inode} (previous item inode:  #{item.inode} )" }
      record = SyncJournalFileRecord.from_sync_file_item(item_copy)

      if result.get == :locked
        record.set_dirty_placeholder(true)
        seen_locked_file(full_local_path(item.local_name), :exclusive)
      end

      d_bresult = @journal.set_file_record(record)

      if !d_bresult
        return d_bresult.error
      end

      return :ok
    end
  end

  class PropagatorJob
    def initialize(propagator, path)
      super(propagator)
      @path = path
      @job_state = :not_yet_started
    end

    def set_state(state)
      @job_state = state
    end

    def propagator
      return qobject_cast < OwncloudPropagator > (parent)
    end
  end

  class PropagatorCompositeJob
    def initialize(propagator, path)
      super(propagator, path)
    end

    def parallelism
      i = 0

      while i < @running_jobs.count
        if @running_jobs.at(i).parallelism != :full_parallelism
          return @running_jobs.at(i).parallelism
        end

        i += 1
      end

      return :full_parallelism
    end

    def slot_sub_job_abort_finished
      @aborts_count -= 1

      if @aborts_count == 0
        abort_finished
      end
    end

    def append_job(job)
      job.set_associated_composite(this)
      @jobs_to_do.append(job)
    end

    def schedule_self_or_child
      if state == :finished
        return false
      end

      if state == :not_yet_started
        set_state(:running)
      end

      i = 0

      while i < @running_jobs.size
        unless @running_jobs.at(i).state == :running
          raise
        end

        if possibly_run_next_job(@running_jobs.at(i))
          return true
        end

        paral = @running_jobs.at(i).parallelism

        if paral == :wait_for_finished
          return false
        end

        i += 1
      end

      while @jobs_to_do.empty && !@tasks_to_do.empty
        next_task = @tasks_to_do.begin
        @tasks_to_do.erase(@tasks_to_do.begin)
        job = propagator.create_job(next_task)

        if !job
          Log.warn("sync.propagator.directory") { "Useless task found for file #{next_task.destination} instruction #{next_task.instruction}" }

          next
        end

        append_job(job)

        break
      end

      if !@jobs_to_do.is_empty
        next_job = @jobs_to_do.first
        @jobs_to_do.remove(0)
        @running_jobs.append(next_job)

        return possibly_run_next_job(next_job)
      end

      if (
        @jobs_to_do.is_empty &&
        @tasks_to_do.empty &&
        @running_jobs.is_empty
      )
        QMetaObject.invoke_method(this, PropagatorCompositeJob.finalize, :queued_connection)
      end

      return false
    end

    def slot_sub_job_finished(status)
      sub_job = sender

      unless sub_job
        raise
      end

      sub_job.delete_later

      unless @running_jobs.remove_all(sub_job) == 1
        raise
      end

      case status
      when :fatal_error, :normal_error, :soft_error, :detail_error, :blacklisted_error
        @error_paths.insert(sub_job.path, status)
      end

      if (
        @jobs_to_do.is_empty &&
        @tasks_to_do.empty &&
        @running_jobs.is_empty
      )
        finalize
      else
        propagator.schedule_next_job
      end
    end

    def finalize
      if state == :finished
        return
      end

      set_state(:finished)

      if @error_paths.empty
        finished(:success)
      else
        finished(@error_paths.last)
      end
    end

    def committed_disk_space
      needed = 0

      @running_jobs.each do |job|
        needed += job.committed_disk_space
      end

      return needed
    end
  end

  class PropagateDirectory
    def initialize(propagator, item)
      super(propagator, item)
      @first_job = propagator.create_job(item)
      @sub_jobs = PropagatorCompositeJob.new(propagator, path)

      if @first_job
        connect(@first_job.get, PropagatorJob.finished, this, PropagateDirectory.slot_first_job_finished)
        @first_job.set_associated_composite(@sub_jobs)
      end

      connect(@sub_jobs, PropagatorJob.finished, this, PropagateDirectory.slot_sub_jobs_finished)
    end

    def parallelism
      if @first_job && @first_job.parallelism != :full_parallelism
        return :wait_for_finished
      end

      if @sub_jobs.parallelism != :full_parallelism
        return :wait_for_finished
      end

      return :full_parallelism
    end

    def schedule_self_or_child
      if state == :finished
        return false
      end

      if state == :not_yet_started
        set_state(:running)
      end

      if @first_job && @first_job.state == :not_yet_started
        return @first_job.schedule_self_or_child
      end

      if @first_job && @first_job.state == :running
        return false
      end

      return @sub_jobs.schedule_self_or_child
    end

    def slot_first_job_finished(status)
      @first_job.release.delete_later

      case status
      when :success, :restoration, :conflict
        nil
      else
        if state != :finished
          abort(:synchronous)
          done(status)
        end

        return
      end

      propagator.schedule_next_job
    end

    def slot_sub_jobs_finished(status)
      if !@item.is_empty
        if (
          @item.relevant_directoy_instruction &&
          @item.status != :success
        )
          unless @item.status != :no_status
            raise
          end

          Log.warn("sync.propagator.directory") { "PropagateDirectory completed with #{status} the dirctory job itself is marked as #{@item.status}" }
          done(@item.status)

          return
        end

        if status == :success
          if (
            @item.instruction == CSYNC_INSTRUCTION_RENAME &&
            @item.original_file != @item.rename_target
          )
            propagator.journal.delete_file_record(@item.original_file, true)
          end

          if (
            @item.instruction == CSYNC_INSTRUCTION_NEW &&
            @item.direction == :down
          )
            unless FileSystem.set_mod_time(propagator.full_local_path(@item.destination), @item.modtime)
              raise
            end
          end

          if @item.instruction & (CSYNC_INSTRUCTION_RENAME | CSYNC_INSTRUCTION_NEW | CSYNC_INSTRUCTION_UPDATE_METADATA)
            @item.relevant_directoy_instruction = true
            @item.status = :success
            result = propagator.update_metadata(@item)

            if !result
              Log.warn("sync.propagator.directory") { "Error writing to the database for file #{@item.local_name} with #{result.error}" }
              done(:fatal_error, "Error updating metadata: #{result.error}")

              return
            elsif result.get == :locked
              done(:soft_error, "The folder »#{@item.destination}« is currently in use")

              return
            end
          end

          if @item.relevant_directoy_instruction
            done(@item.status)

            return
          end
        end
      end

      unless state != :finished
        raise
      end

      set_state(:finished)
      finished(status)

      if @item.relevant_directoy_instruction
        propagator.item_completed(@item)
      end
    end
  end

  class PropagateRootDirectory
    AbortsFinished = Struct.new(
      :sub_jobs_finished,
      :dir_deletion_finished,
      keyword_init: true
    )
    def initialize(propagator)
      super(propagator, SyncFileItemPtr.new((lambda do
        f = SyncFileItem.new
        f.set_local_name("/")

        return f
      end).call))

      @dir_deletion_jobs = PropagatorCompositeJob.new(propagator, path)
      connect(@dir_deletion_jobs, PropagatorJob.finished, this, PropagateRootDirectory.slot_dir_deletion_jobs_finished)
    end

    def parallelism
      return :wait_for_finished
    end

    def abort(abort_type)
      if @first_job
        @first_job.abort(:synchronous)
      end

      if abort_type == :asynchronous
        abort_status = QSharedPointer.new(AbortsFinished.new)

        connect(@sub_jobs, PropagatorCompositeJob.abort_finished, this) do
          abort_status.sub_jobs_finished = true

          if (
            abort_status.sub_jobs_finished &&
            abort_status.dir_deletion_finished
          )
            abort_finished
          end
        end

        connect(@dir_deletion_jobs, PropagatorCompositeJob.abort_finished, this) do
          abort_status.dir_deletion_finished = true

          if (
            abort_status.sub_jobs_finished &&
            abort_status.dir_deletion_finished
          )
            abort_finished
          end
        end
      end

      @sub_jobs.abort(abort_type)
      @dir_deletion_jobs.abort(abort_type)
    end

    def committed_disk_space
      return @sub_jobs.committed_disk_space + @dir_deletion_jobs.committed_disk_space
    end

    def schedule_self_or_child
      if state == :finished
        return false
      end

      if PropagateDirectory.schedule_self_or_child
        return true
      end

      if @sub_jobs.state != :finished
        return false
      end

      return @dir_deletion_jobs.schedule_self_or_child
    end

    def slot_sub_jobs_finished(status)
      case status
      when :success, :restoration, :conflict
        nil
      else
        @status = status

        if state != :finished
          sub_job = qobject_cast < PropagatorCompositeJob > (sender)

          if sub_job
            error_paths = sub_job.error_paths
            delete_jobs = @dir_deletion_jobs.jobs_to_do

            delete_jobs.erase(std::remove_if(delete_jobs.begin, delete_jobs.end, lambda do |p|
              Utility.as_key_value_range(error_paths).each do |path, error|
                info = QFileInfo.new(path)

                if info.is_dir
                  if FileSystem.is_child_path_of(p.path, info.file_path)
                    return true
                  end
                elsif FileSystem.is_child_path_of(p.path, info.path)
                  return true
                end
              end

              return false
            end), delete_jobs.end)

            @dir_deletion_jobs.set_jobs_to_do(delete_jobs)
          end
        end
      end

      propagator.schedule_next_job
    end

    def slot_dir_deletion_jobs_finished(status)
      set_state(:finished)

      if @status != :no_status
        finished(@status)
      else
        finished(status)
      end
    end

    def add_delete_job(job)
      @dir_deletion_jobs.append_job(job)
    end
  end

  class OwncloudPropagator
    def full_remote_path(tmp_file_name)
      return @remote_folder + tmp_file_name
    end

    def remote_path
      return @remote_folder
    end
  end

  class PropagateUpdateMetaDataJob
    def initialize(propagator, item)
      super(propagator, item)
    end

    def start
      file_path = propagator.full_local_path(@item.destination)

      if @item.direction == :down
        prev = propagator.journal.get_file_record(@item.local_name)

        if prev.is_valid
          if @item.checksum_header.is_empty
            @item.checksum_header = prev.checksum_header
          end

          @item.server_has_ignored_files |= prev.server_has_ignored_files
        end
      end

      result = propagator.update_metadata(@item)

      if !result
        done(:fatal_error, "Could not update file: #{result.error}")

        return
      elsif result.get == :locked
        done(:soft_error, "The file »#{@item.local_name}« is currently in use")

        return
      end

      done(:success)
    end
  end
end
