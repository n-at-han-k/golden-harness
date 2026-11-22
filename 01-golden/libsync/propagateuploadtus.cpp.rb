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

require_relative "propagateuploadtus"
require_relative "account"
require_relative "capabilities"
require_relative "common/asserts"
require_relative "common/checksums"
require_relative "common/syncjournaldb"
require_relative "common/syncjournalfilerecord"
require_relative "common/utility"
require_relative "filesystem"
require_relative "httplogger"
require_relative "networkjobs"
require_relative "owncloudpropagator_p"
require_relative "propagateupload"
require_relative "propagatorjobs"
require_relative "syncengine"

require "qfileinfo"

require "cmath"
require "memory"

module OCC
  class PropagateUploadFileTUS
    def initialize(propagator, item)
      super(propagator, item)
    end

    def prepare_device(chunk_size)
      local_file_name = propagator.full_local_path(@item.local_name)

      if FileSystem.is_file_locked(local_file_name, :shared_read)
        propagator.seen_locked_file(local_file_name, :shared_read)
        abort_with_error(:soft_error, "The file »#{local_file_name}« is currently in use")

        return nil
      end

      device = UploadDevice.new(local_file_name, @current_offset, chunk_size, propagator.bandwidth_manager)

      if !device.open(:read_only)
        Log.warn("sync.propagator.upload.tus") { "Could not prepare upload device:  #{device.error_string}" }
        abort_with_error(:soft_error, device.error_string)

        return nil
      end

      return device
    end

    def make_creation_with_upload_job(request, device)
      unless propagator.account.capabilities.tus_support.extensions.contains("creation-with-upload")
        raise
      end

      checksum_header = ChecksumHeader.parse_checksum_header(@transmission_checksum_header)
      encoded_meta_data = []

      add_meta_data = lambda do |key, value|
        encoded_meta_data << key.+(" ").+(value.to_base64)
      end

      add_meta_data.call("filename", propagator.full_remote_path(@item.local_name).to_utf8)

      add_meta_data.call(
        "checksum",
        Utility.enum_to_string(checksum_header.type).to_utf8 + " " + checksum_header.checksum
      )

      add_meta_data.call("mtime", QByteArray.number(@item.modtime))
      request.set_raw_header("Upload-Metadata", encoded_meta_data.join(","))
      request.set_raw_header("Upload-Length", QByteArray.number(@item.size))

      return SimpleNetworkJob.new(propagator.account, propagator.web_dav_url, nil, "POST", device, request, this)
    end

    def prepare_request(chunk_size)
      request = QNetworkRequest.new
      headers = PropagateUploadFileCommon.headers
      it = headers.cbegin

      while it != headers.cend
        request.set_raw_header(it.key, it.value)
        it += 1
      end

      request.set_header(:content_type_header, "application/offset+octet-stream")
      request.set_header(:content_length_header, QByteArray.number(chunk_size))
      request.set_raw_header(upload_offset, QByteArray.number(@current_offset))
      set_tus_version_header(request)

      return request
    end

    def upload_offset
      return "Upload-Offset"
    end

    def set_tus_version_header(req)
      req.set_raw_header("Tus-Resumable", "1.0.0")
    end

    def do_start_upload
      if @transmission_checksum_header.is_empty
        abort_with_error(:soft_error, "Checksum computation failed")

        return
      end

      propagator.report_progress(@item, 0)
      propagator.active_job_list.append(this)
      info = propagator.journal.get_upload_info(@item.local_name)

      if info.validate(@item.size, @item.modtime, @item.checksum_header)
        @location = info.url

        unless @location.is_valid
          raise
        end

        job = SimpleNetworkJob.new(propagator.account, @location, nil, "HEAD", nil, this)
        connect(job, SimpleNetworkJob.finished_signal, this, PropagateUploadFileTUS.slot_chunk_finished)
        job.start
      else
        start_next_chunk
      end
    end

    def start_next_chunk
      if propagator.abort_requested
        return
      end

      chunk_size = lambda do
        chunk_size = @item.size - @current_offset

        if propagator.account.capabilities.tus_support.max_chunk_size
          chunk_size = min(chunk_size, propagator.account.capabilities.tus_support.max_chunk_size)
        end

        return chunk_size
      end

      chunk_size.call
      req = prepare_request(chunk_size)
      device = prepare_device(chunk_size)

      if !device
        return
      end

      job = SimpleNetworkJob.new

      if @current_offset != 0
        Log.debug("sync.propagator.upload.tus") { "Starting to patch upload: #{propagator.full_remote_path(@item.local_name)}" }
        job = SimpleNetworkJob.new(propagator.account, @location, nil, "PATCH", device, req, this)
      else
        unless @location.is_empty
          raise
        end

        Log.debug("sync.propagator.upload.tus") { "Starting creation with upload: #{propagator.full_remote_path(@item.local_name)}" }
        job = make_creation_with_upload_job(req, device)
      end

      job.set_priority(:low_priority)

      Log.debug("sync.propagator.upload.tus") {
        "Offset: #{@current_offset} #{@current_offset / (@item.size + 1) * 100} Chunk: #{chunk_size}" \
          "#{chunk_size / (@item.size + 1) * 100}"
      }

      add_child_job(job)
      connect(job, SimpleNetworkJob.finished_signal, this, PropagateUploadFileTUS.slot_chunk_finished)

      job.add_new_reply_hook do |reply|
        connect(
          reply,
          QNetworkReply.upload_progress,
          qobject_cast < UploadDevice > (job.body.data),
          UploadDevice.slot_job_upload_progress
        )

        connect(reply, QNetworkReply.upload_progress, this) do |bytes_sent, _|
          propagator.report_progress(@item, @current_offset + bytes_sent)
        end
      end

      job.start
    end

    def slot_chunk_finished
      job = qobject_cast < SimpleNetworkJob > (sender)

      unless job
        raise
      end

      Log.debug("sync.propagator.upload.tus") { "#{propagator.full_remote_path(@item.local_name)} #{HttpLogger.request_verb(job.reply)}" }
      @item.http_error_code = job.reply.attribute(:http_status_code_attribute).to_int
      @item.response_time_stamp = job.response_timestamp
      @item.request_id = job.request_id
      err = job.reply.error

      if err != :no_error
        status = @item.http_error_code

        if (
          HttpLogger.request_verb(job.reply) == "HEAD" &&
          (status == 404 || status == 410 || status == 403) &&
          !@restarted_upload
        )
          Log.warn("sync.propagator.upload.tus") {
            "#{propagator.full_remote_path(@item.local_name)} Upload no longer available, starting a new one: #{status}" \
              "#{@location}"
          }

          @restarted_upload = true
          propagator.journal.set_upload_info(@item.local_name, SyncJournalDb.upload_info)
          propagator.journal.commit("upload file restart")
          @location.clear
          @current_offset = 0
          propagator.report_progress(@item, 0)
          start_next_chunk

          return
        end

        if status == 460
          propagator.journal.set_upload_info(@item.local_name, SyncJournalDb.upload_info)
          propagator.journal.commit("upload file checksum mismatch")
        end

        if (
          (
            err == :timeout_error ||
            @item.http_error_code == 409
          ) &&
          !@location.is_empty &&
          HttpLogger.request_verb(job.reply) != "HEAD"
        )
          Log.warn("sync.propagator.upload.tus") { "#{propagator.full_remote_path(@item.local_name)} Encountered a timeout . get progress for #{@location}" }
          req = QNetworkRequest.new
          set_tus_version_header(req)

          update_job = SimpleNetworkJob.new(
            propagator.account,
            propagator.web_dav_url,
            @location.path,
            "HEAD",
            req,
            this
          )

          add_child_job(update_job)
          connect(update_job, SimpleNetworkJob.finished_signal, this, PropagateUploadFileTUS.slot_chunk_finished)
          update_job.start

          return
        end

        common_error_handling(job)

        return
      end

      offset = job.reply.raw_header(upload_offset).to_long_long
      propagator.report_progress(@item, offset)
      @current_offset = offset
      @finished = offset == @item.size

      if @location.is_empty
        @location = job.reply.header(:location_header).to_url
      end

      if !@finished && !@location.is_valid
        abort_with_error(:soft_error, "Upload did not receive a Content-Location.")

        return
      end

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
        if HttpLogger.request_verb(job.reply) == "POST"
          info = @item.to_upload_info
          info.url = @location
          propagator.journal.set_upload_info(@item.local_name, info)
        end

        start_next_chunk

        return
      end

      etag = get_etag_from_reply(job.reply)
      rem_perms = job.reply.raw_header("OC-Perm")

      if !rem_perms.is_empty
        @item.remote_perm = RemotePermissions.from_server_string(QString.from_utf8(rem_perms))
      end

      @finished = !(etag.is_empty || @item.remote_perm.is_null)

      if !@finished
        check = PropfindJob.new(
          propagator.account,
          propagator.web_dav_url,
          propagator.full_remote_path(@item.local_name),
          :zero,
          this
        )

        add_child_job(check)
        check.set_properties(["http://owncloud.org/ns:fileid", "http://owncloud.org/ns:permissions", "getetag"])

        connect(check, PropfindJob.directory_listing_iterated, this) do |_, map|
          @finished = true
          @item.remote_perm = RemotePermissions.from_server_string(map.value("permissions"))
          finalize(Utility.normalize_etag(map.value("getetag")), map.value("fileid").to_utf8)
        end

        connect(check, PropfindJob.finished_with_error, this) { common_error_handling(check) }
        check.start

        return
      end

      @item.remote_perm = RemotePermissions.from_server_string(QString.from_utf8(job.reply.raw_header("Oc-Perm")))
      finalize(etag, job.reply.raw_header("OC-FileID"))
    end

    def finalize(etag, file_id)
      unless @finished
        raise
      end

      @item.etag = etag

      if !file_id.is_empty
        if !@item.file_id.is_empty && @item.file_id != file_id
          Log.warn("sync.propagator.upload.tus") { "File ID changed! #{@item.file_id} #{file_id}" }
        end

        @item.file_id = file_id
      end

      propagator.active_job_list.remove_one(this)
      PropagateUploadFileCommon.finalize
    end

    def abort(abort_type)
      abort_network_jobs(abort_type) do |_|
        return true
      end
    end
  end
end
