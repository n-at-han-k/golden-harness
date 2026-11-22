#!/usr/bin/env ruby
#
# Copyright (C) by Olivier Goffart <ogoffart@owncloud.com>
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

require_relative "propagatedownload"
require_relative "account"
require_relative "filesystem"
require_relative "libsync/networkjobs/getfilejob"
require_relative "networkjobs"
require_relative "owncloudpropagator_p"
require_relative "propagatorjobs"

require_relative "common/asserts"
require_relative "common/checksums"
require_relative "common/syncjournaldb"
require_relative "common/syncjournalfilerecord"
require_relative "common/utility"
require_relative "vfs/vfs"

require "qdir"
require "qfileinfo"
require "qloggingcategory"
require "qrandomgenerator"

require "cmath"

require "unistd"

include std::chrono_literals

module OCC
  class PropagateDownloadFile
    def preserve_group_ownership(file_name, fi)
      if chown(file_name.to_local8_bit.const_data, -1, fi.group_id) != 0
        Log.warn("sync.propagator.download") { "Unable to chown #{file_name} to previous group owner #{strerror(errno)}" }
      end
    end

    def create_download_tmp_file_name(previous)
      tmp_file_name = ""
      tmp_path = ""
      slash_pos = previous.last_index_of("/")

      if slash_pos == -1
        tmp_file_name = previous
      else
        tmp_file_name = previous.mid(slash_pos + 1)
        tmp_path = previous.left(slash_pos)
      end

      rg = QRandomGenerator.global
      overhead = 1 + 1 + 2 + 8
      space_for_file_name = q_min(254, tmp_file_name.length + overhead) - overhead

      if tmp_path.length > 0
        return "#{tmp_path}/.#{tmp_file_name.left(space_for_file_name)}.~#{QString.number(rg.generate % 4294967295, 16)}"
      else
        return ".#{tmp_file_name.left(space_for_file_name)}.~#{QString.number(rg.generate % 4294967295, 16)}"
      end
    end

    def start
      if propagator.abort_requested
        return
      end

      @stopwatch.start
      sync_options = propagator.sync_options
      vfs = sync_options.vfs
      fs_path = propagator.full_local_path(@item.local_name)

      if @item.type == :item_type_virtual_file_dehydration
        if FileSystem.file_changed(FileSystem.to_filesystem_path(fs_path), FileSystem::FileChangedInfo.from_sync_file_item_previous(@item.data))

          propagator.another_sync_needed = true
          done(:soft_error, "The file has changed since discovery")

          return
        end

        if FileSystem.is_file_locked(fs_path, :exclusive)
          propagator.seen_locked_file(fs_path, :exclusive)
          done(:soft_error, "Failed to free up space, the file »#{fs_path}« is currently in use")

          return
        end

        Log.debug("sync.propagator.download") { "dehydrating file #{@item.local_name}" }
        update_metadata(false)

        return
      end

      if vfs.mode == :off && @item.type == :item_type_virtual_file
        Log.warn("sync.propagator.download") { "ignored virtual file type of #{@item.local_name}" }
        @item.type = :item_type_file
      end

      if @delete_existing
        delete_existing_folder

        if state == :finished
          return
        end
      end

      if @item.type == :item_type_virtual_file
        Log.debug("sync.propagator.download") { "creating virtual file #{@item}" }
        clash = propagator.local_file_name_clash(@item.local_name)

        if clash
          done(
            :normal_error,
            "The file »#{QDir.to_native_separators(@item.local_name)}« can not be downloaded because of a local file name clash with #{QDir.to_native_separators(clash.get)}!"
          )

          return
        end

        is_conflict = (
          @item.instruction == CSYNC_INSTRUCTION_CONFLICT &&
          QFileInfo.new(fs_path).is_dir
        )

        if is_conflict
          error = ""

          if !propagator.create_conflict(@item, @associated_composite, error)
            done(:soft_error, error)

            return
          end
        end

        r = vfs.create_placeholder(@item)

        if !r
          done(:normal_error, r.error)

          return
        end

        update_metadata(is_conflict)

        return
      end

      csync_is_collision_safe_hash = lambda do |checksum_header|
        safe = std::any_of(:safe_algorithms.begin, :safe_algorithms.end, lambda do |it|
          return checksum_header.starts_with(it.second.data)
        end)

        if !safe
          Log.warn("sync.propagator.download") { "#{checksum_header} is considered unsave" }

          return false
        end

        return true
      end

      if (
        @item.instruction == CSYNC_INSTRUCTION_CONFLICT &&
        @item.size == @item.previous_size &&
        !@item.checksum_header.is_empty &&
        (
          csync_is_collision_safe_hash.call(@item.checksum_header) ||
          @item.modtime == @item.previous_modtime
        )
      )
        Log.debug("sync.propagator.download") { "#{@item.local_name} may not need download, computing checksum" }
        compute_checksum = ComputeChecksum.new(this)
        checksum_header = ChecksumHeader.parse_checksum_header(@item.checksum_header)
        compute_checksum.set_checksum_type(checksum_header.type)
        connect(compute_checksum, ComputeChecksum.done, this, PropagateDownloadFile.conflict_checksum_computed)
        propagator.active_job_list.append(this)
        compute_checksum.start(propagator.full_local_path(@item.local_name))

        return
      end

      start_download
    end

    def conflict_checksum_computed(checksum_type, checksum)
      propagator.active_job_list.remove_one(this)
      checksum_header = ChecksumHeader.parse_checksum_header(@item.checksum_header)

      if checksum_header == ChecksumHeader.new(checksum_type, checksum)
        Log.debug("sync.propagator.download") { "#{@item.local_name} remote and local checksum match" }
        fn = propagator.full_local_path(@item.local_name)

        if @item.modtime != @item.previous_modtime
          FileSystem.set_mod_time(fn, @item.modtime)
        end

        @item.modtime = FileSystem.get_mod_time(fn)
        update_metadata(false)

        return
      end

      start_download
    end

    def start_download
      if propagator.abort_requested
        return
      end

      clash = propagator.local_file_name_clash(@item.local_name)

      if clash
        done(
          :normal_error,
          "The file »#{QDir.to_native_separators(@item.local_name)}« can not be downloaded because of a local file name clash with #{QDir.to_native_separators(clash.get)}!"
        )

        return
      end

      target_file = propagator.full_local_path(@item.local_name)

      if FileSystem.is_file_locked(target_file, :exclusive)
        propagator.seen_locked_file(target_file, :exclusive)
        done(:soft_error, "The file »#{QDir.to_native_separators(@item.local_name)}« is currently in use")

        return
      end

      propagator.report_progress(@item, 0)
      tmp_file_name = ""
      progress_info = propagator.journal.get_download_info(@item.local_name)

      if progress_info.valid
        if progress_info.etag != @item.etag.to_utf8
          FileSystem.remove(propagator.full_local_path(progress_info.tmpfile))
          propagator.journal.set_download_info(@item.local_name, SyncJournalDb.download_info)
        else
          tmp_file_name = progress_info.tmpfile
          @expected_etag_for_resume = QString.from_utf8(progress_info.etag)
        end
      end

      if tmp_file_name.is_empty
        tmp_file_name = create_download_tmp_file_name(@item.local_name)
      end

      @tmp_file.set_file_name(propagator.full_local_path(tmp_file_name))
      @resume_start = @tmp_file.size

      if @resume_start > 0 && @resume_start == @item.size
        Log.info("sync.propagator.download") { "The file is already complete, no need to download" }
        download_finished

        return
      end

      if @tmp_file.exists
        FileSystem.set_file_read_only(@tmp_file.file_name, false)
      end

      if !@tmp_file.open(:append | :unbuffered)
        Log.warn("sync.propagator.download") { "could not open temporary file #{@tmp_file.file_name}" }
        done(:normal_error, @tmp_file.error_string)

        return
      end

      FileSystem.set_file_hidden(@tmp_file.file_name, true)
      disk_space_result = propagator.disk_space_check

      if disk_space_result != :disk_space_ok
        if disk_space_result == :disk_space_failure
          done(:detail_error, "The download would reduce free local disk space below the limit")
          propagator.insufficient_local_storage
        elsif disk_space_result == :disk_space_critical
          done(:fatal_error, "Free space on disk is less than #{Utility.octets_to_string(critical_free_space_limit)}")
        end

        if @resume_start == 0
          @tmp_file.remove
        end

        return
      end

      pi = DownloadInfo.new
      pi.etag = @item.etag.to_utf8
      pi.tmpfile = tmp_file_name
      pi.valid = true
      propagator.journal.set_download_info(@item.local_name, pi)
      propagator.journal.commit("download file start")
      start_full_download
    end

    def start_full_download
      headers = Hash.new do |hash, key|
        hash[key] = QByteArray.new
      end

      @job = GETFileJob.new(
        propagator.account,
        propagator.web_dav_url,
        propagator.full_remote_path(@item.local_name),
        @tmp_file,
        headers,
        @expected_etag_for_resume,
        @resume_start,
        this
      )

      @job.set_bandwidth_manager(propagator.bandwidth_manager)
      @job.set_expected_content_length(@item.size - @resume_start)
      connect(@job.data, GETFileJob.finished_signal, this, PropagateDownloadFile.slot_get_finished)

      connect(
        qobject_cast < GETFileJob > (@job.data),
        GETFileJob.download_progress,
        this,
        PropagateDownloadFile.slot_download_progress
      )

      propagator.active_job_list.append(this)
      @job.start
    end

    def committed_disk_space
      if state == :running
        return q_bound(0, @item.size - @resume_start - @download_progress, @item.size)
      end

      return 0
    end

    def set_delete_existing_folder(enabled)
      @delete_existing = enabled
    end

    def slot_get_finished
      propagator.active_job_list.remove_one(this)
      job = @job

      unless job
        raise
      end

      @item.http_error_code = job.reply.attribute(:http_status_code_attribute).to_int
      @item.response_time_stamp = job.response_timestamp
      @item.request_id = job.request_id
      err = job.reply.error

      if err != :no_error
        bad_range_header = job.resume_start > 0 && @item.http_error_code == 416

        if bad_range_header
          Log.warn("sync.propagator.download") { "server replied 416 to our range request, trying again without" }
          propagator.another_sync_needed = true
        end

        file_not_found = @item.http_error_code == 404

        if file_not_found
          Log.warn("sync.propagator.download") { "server replied 404, assuming file was deleted" }
        end

        if (
          @tmp_file.exists &&
          (
            @tmp_file.size == 0 ||
            bad_range_header ||
            file_not_found
          )
        )
          @tmp_file.close
          FileSystem.remove(@tmp_file.file_name)
          propagator.journal.set_download_info(@item.local_name, SyncJournalDb.download_info)
        end

        if bad_range_header
          job.set_error_status(:soft_error)
        elsif file_not_found
          job.set_error_string("The file was deleted from server")
          job.set_error_status(:soft_error)
          propagator.journal.schedule_path_for_remote_discovery(@item.local_name)
        end

        error_body = ""

        if @item.http_error_code >= 400
          error_string = job.error_string_parsing_body(error_body)
        else
          error_string = job.error_string
        end

        status = job.error_status

        if status == :no_status
          status = classify_error(err, @item.http_error_code, propagator.another_sync_needed, error_body)
        end

        done(status, error_string)

        return
      end

      if !job.etag.is_empty
        unless job.etag == Utility.normalize_etag(job.etag)
          raise
        end

        @item.etag = job.etag
      end

      if job.last_modified
        @item.modtime = job.last_modified
      end

      @tmp_file.close
      @tmp_file.flush
      size_header = "Content-Length"
      has_size_header = true
      body_size = job.reply.raw_header(size_header).to_long_long(has_size_header)
      content_encoding = job.reply.raw_header("content-encoding").to_lower

      if (
        job.reply.attribute(:http2_was_used_attribute).to_bool &&
        (
          content_encoding == "gzip" ||
          content_encoding == "deflate"
        )
      )
        body_size = 0
        has_size_header = false
      end

      if has_size_header && @tmp_file.size > 0 && body_size == 0
        Log.debug("sync.propagator.download") { "#{body_size} #{@item.size} #{@tmp_file.size} #{job.resume_start}" }
        FileSystem.remove(@tmp_file.file_name)
        done(:soft_error, "Broken webserver returned empty content length for non-empty file on resume")

        return
      end

      if (
        body_size > 0 &&
        body_size != (@tmp_file.size - job.resume_start)
      )
        Log.debug("sync.propagator.download") { "#{body_size} != #{@tmp_file.size - job.resume_start} #{@tmp_file.size} #{job.resume_start}" }
        propagator.another_sync_needed = true
        done(:soft_error, "The file could not be downloaded completely.")

        return
      end

      if @tmp_file.size == 0 && @item.size > 0
        FileSystem.remove(@tmp_file.file_name)

        done(
          :normal_error,
          "The downloaded file is empty despite the server announced it should have been #{Utility.octets_to_string(@item.size)}."
        )

        return
      end

      if job.reply.raw_header("OC-Conflict") == "1"
        @conflict_record.path = @item.local_name.to_utf8
        @conflict_record.initial_base_path = job.reply.raw_header("OC-ConflictInitialBasePath")
        @conflict_record.base_file_id = job.reply.raw_header("OC-ConflictBaseFileId")
        @conflict_record.base_etag = job.reply.raw_header("OC-ConflictBaseEtag")
        mtime_header = job.reply.raw_header("OC-ConflictBaseMtime")

        if !mtime_header.is_empty
          @conflict_record.base_modtime = mtime_header.to_long_long
        end
      end

      validator = ValidateChecksumHeader.new(this)
      connect(validator, ValidateChecksumHeader.validated, this, PropagateDownloadFile.transmission_checksum_validated)
      connect(validator, ValidateChecksumHeader.validation_failed, this, PropagateDownloadFile.slot_checksum_fail)
      checksum_header = find_best_checksum(job.reply.raw_header(check_sum_header_c))
      validator.start(@tmp_file.file_name, checksum_header)
    end

    def slot_checksum_fail(err_msg)
      FileSystem.remove(@tmp_file.file_name)
      propagator.another_sync_needed = true
      done(:soft_error, err_msg)
    end

    def delete_existing_folder
      existing_dir = propagator.full_local_path(@item.local_name)

      if !QFileInfo.new(existing_dir).is_dir
        return
      end

      dir = QDir.new(existing_dir)

      if dir.entry_list(:no_dot_and_dot_dot | :all_entries).count == 0
        Log.debug("sync.propagator.download") { "deleting existing dir #{existing_dir} to replace it with a file" }

        if dir.rmdir(existing_dir)
          return
        end
      end

      error = ""

      if !propagator.create_conflict(@item, @associated_composite, error)
        done(:normal_error, error)
      end
    end

    def transmission_checksum_validated(checksum_type, checksum)
      the_content_checksum_type = propagator.account.capabilities.preferred_upload_checksum_type

      if (
        the_content_checksum_type == checksum_type ||
        the_content_checksum_type != :parse_error
      )
        return content_checksum_computed(checksum_type, checksum)
      end

      compute_checksum = ComputeChecksum.new(this)
      compute_checksum.set_checksum_type(the_content_checksum_type)
      connect(compute_checksum, ComputeChecksum.done, this, PropagateDownloadFile.content_checksum_computed)
      compute_checksum.start(@tmp_file.file_name)
    end

    def content_checksum_computed(checksum_type, checksum)
      @item.checksum_header = ChecksumHeader.new(checksum_type, checksum).make_checksum_header
      download_finished
    end

    def download_finished
      unless !@tmp_file.is_open
        raise
      end

      fn = propagator.full_local_path(@item.destination)
      clash = propagator.local_file_name_clash(@item.local_name)

      if clash
        done(
          :normal_error,
          "The file »#{QDir.to_native_separators(@item.local_name)}« cannot be saved because of a local file name clash with »#{QDir.to_native_separators(clash.get)}«!"
        )

        return
      end

      FileSystem.set_mod_time(@tmp_file.file_name, @item.modtime)
      @item.modtime = FileSystem.get_mod_time(@tmp_file.file_name)
      previous_file_exists = FileSystem.file_exists(fn)

      if previous_file_exists
        existing_file = QFileInfo.new(fn)

        if existing_file.permissions != @tmp_file.permissions
          @tmp_file.set_permissions(existing_file.permissions)
        end

        preserve_group_ownership(@tmp_file.file_name, existing_file)
        result = propagator.update_placeholder(@item, @tmp_file.file_name, fn)

        if !result
          done(:normal_error, result.error)

          return
        elsif result.get == :locked
          done(:soft_error, "The file »#{@item.local_name}« is currently in use")

          return
        end
      end

      is_conflict = (
        @item.instruction == CSYNC_INSTRUCTION_CONFLICT &&
        (QFileInfo.new(fn).is_dir || !FileSystem.file_equals(fn, @tmp_file.file_name))
      )

      if is_conflict
        error = ""

        if !propagator.create_conflict(@item, @associated_composite, error)
          done(:soft_error, error)

          return
        end

        previous_file_exists = false
      end

      if previous_file_exists
        if FileSystem.file_changed(FileSystem.to_filesystem_path(fn), FileSystem::FileChangedInfo.from_sync_file_item_previous(@item.data))

          propagator.another_sync_needed = true
          done(:soft_error, "The file has changed since discovery")

          return
        end
      end

      if FileSystem.is_file_locked(fn, :exclusive)
        propagator.seen_locked_file(fn, :exclusive)
        done(:soft_error, "The file »#{fn}« is currently in use")

        return
      end

      error = ""

      if !FileSystem.unchecked_rename_replace(@tmp_file.file_name, fn, error)
        Log.warn("sync.propagator.download") { "Rename failed: #{@tmp_file.file_name} => #{fn} with error: #{error}" }
        propagator.another_sync_needed = true
        done(:soft_error, error)

        return
      end

      FileSystem.set_file_hidden(fn, false)
      @item.size = FileSystem.get_size(FileSystem.to_filesystem_path(fn))

      if @conflict_record.is_valid
        propagator.journal.set_conflict_record(@conflict_record)
      end

      update_metadata(is_conflict)
    end

    def update_metadata(is_conflict)
      result = propagator.update_metadata(@item)

      if !result
        done(:fatal_error, "Error updating metadata: #{result.error}")

        return
      elsif result.get == :locked
        done(:soft_error, "The file »#{@item.local_name}« is currently in use")

        return
      end

      propagator.journal.set_download_info(@item.local_name, SyncJournalDb.download_info)
      propagator.journal.commit("download file start2")

      if is_conflict
        done(:conflict)
      else
        done(:success)
      end

      duration = std::chrono::milliseconds(@stopwatch.elapsed)

      if is_likely_finished_quickly && duration > 5
        Log.warn("sync.propagator.download") {
          "WARNING: Unexpectedly slow connection, took #{duration.count} ms for #{@item.size - @resume_start}" \
            "bytes for #{@item.local_name}"
        }
      end
    end

    def slot_download_progress(received, _)
      if !@job
        return
      end

      @download_progress = received
      propagator.report_progress(@item, @resume_start + received)
    end

    def abort(abort_type)
      if @job
        @job.abort
      end

      if abort_type == :asynchronous
        abort_finished
      end
    end
  end
end
