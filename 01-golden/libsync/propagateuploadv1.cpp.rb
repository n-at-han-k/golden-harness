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

require_relative "account"
require_relative "common/checksums"
require_relative "common/syncjournaldb"
require_relative "filesystem"
require_relative "networkjobs"
require_relative "owncloudpropagator_p"
require_relative "propagateupload"
require_relative "propagatorjobs"
require_relative "syncengine"

require "qdir"
require "qfileinfo"
require "qrandomgenerator"

require "cmath"
require "cstring"
require "memory"

module OCC
  class PropagateUploadFileV1
    def do_start_upload
      file_name = propagator.full_local_path(@item.local_name)

      if FileSystem.is_file_locked(file_name, :shared_read)
        propagator.seen_locked_file(file_name, :shared_read)
        abort_with_error(:soft_error, "The file »#{QDir.to_native_separators(file_name)}« is currently in use")

        return
      end

      propagator.report_progress(@item, 0)
      file_size = @item.size
      headers = PropagateUploadFileCommon.headers
      headers["OC-Total-Length"] = QByteArray.number(file_size)
      path = @item.local_name

      if !@transmission_checksum_header.is_empty
        Log.info("sync.propagator.upload.v1") { "#{propagator.full_remote_path(path)} #{@transmission_checksum_header}" }
        headers[check_sum_header_c] = @transmission_checksum_header
      end

      device = UploadDevice.new(file_name, 0, file_size, propagator.bandwidth_manager)

      if !device.open(:read_only)
        Log.warn("sync.propagator.upload.v1") { "Could not prepare upload device:  #{device.error_string}" }
        abort_with_error(:soft_error, device.error_string)

        return
      end

      device_ptr = device.get

      job = PUTFileJob.new(
        propagator.account,
        propagator.web_dav_url,
        propagator.full_remote_path(path),
        device,
        headers,
        this
      )

      add_child_job(job)
      connect(job, PUTFileJob.finished_signal, this, PropagateUploadFileV1.slot_put_finished)
      connect(job, PUTFileJob.upload_progress, this, PropagateUploadFileV1.slot_upload_progress)
      connect(job, PUTFileJob.upload_progress, device_ptr, UploadDevice.slot_job_upload_progress)
      adjust_last_job_timeout(job, file_size)
      job.start
      propagator.active_job_list.append(this)
    end

    def slot_put_finished
      job = qobject_cast < PUTFileJob > (sender)

      unless job
        raise
      end

      propagator.active_job_list.remove_one(this)

      if @finished
        return
      end

      @item.http_error_code = job.http_status_code
      @item.response_time_stamp = job.response_timestamp
      @item.request_id = job.request_id
      err = job.reply.error

      if err != :no_error
        common_error_handling(job)

        return
      end

      if @item.http_error_code == 202
        done(:normal_error, "The server did ask for a removed legacy feature (polling)")

        return
      end

      etag = get_etag_from_reply(job.reply)
      @finished = etag.length > 0
      full_file_path = propagator.full_local_path(@item.local_name)

      if !FileSystem.file_exists(full_file_path)
        if !@finished
          abort_with_error(:soft_error, "The local file was removed during sync.")

          return
        else
          propagator.another_sync_needed = true
        end
      end

      if FileSystem.file_changed(FileSystem.to_filesystem_path(full_file_path), FileSystem::FileChangedInfo.from_sync_file_item(@item.data))

        propagator.another_sync_needed = true

        if !@finished
          abort_with_error(:message, file_changed_message)

          return
        end
      end

      if !@finished
        done(:normal_error, "The server did not acknowledge the last chunk. (No e-tag was present)")

        return
      end

      fid = job.reply.raw_header("OC-FileID")

      if !fid.is_empty
        if !@item.file_id.is_empty && @item.file_id != fid
          Log.warn("sync.propagator.upload.v1") { "File ID changed! #{@item.file_id} #{fid}" }
        end

        @item.file_id = fid
      end

      @item.etag = etag
      finalize
    end

    def slot_upload_progress(sent, total)
      if sent == 0 && total == 0
        return
      end

      propagator.report_progress(@item, sent)
    end

    def abort(abort_type)
      abort_network_jobs(abort_type) do |job|
        put_job = qobject_cast < PUTFileJob > (job)

        if put_job
          if (
            abort_type == :asynchronous &&
            put_job.body &&
            put_job.body.at_end
          )
            return false
          end
        end

        return true
      end
    end
  end
end
