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

require_relative "propagateremotemkdir"
require_relative "owncloudpropagator_p"
require_relative "account"
require_relative "common/syncjournalfilerecord"
require_relative "propagateremotedelete"
require_relative "common/asserts"

require "qfile"
require "qloggingcategory"
require "qtconcurrent"

include Qt::Literals::StringLiterals
include std::chrono_literals

module OCC
  class PropagateRemoteMkdir
    UPDATE_META_DATA_RETY_TIME_OUT = 30
    def start
      if propagator.abort_requested
        return
      end

      Log.debug("sync.propagator.remotemkdir") { "#{@item.local_name}" }
      propagator.active_job_list.append(this)

      if !@delete_existing
        return slot_start_mkcol_job
      end

      @job = DeleteJob.new(
        propagator.account,
        propagator.web_dav_url,
        propagator.full_remote_path(@item.local_name),
        this
      )

      connect(
        qobject_cast < DeleteJob > (@job),
        DeleteJob.finished_signal,
        this,
        PropagateRemoteMkdir.slot_start_mkcol_job
      )

      @job.start
    end

    def slot_start_mkcol_job
      if propagator.abort_requested
        return
      end

      Log.debug("sync.propagator.remotemkdir") { "#{@item.local_name}" }

      @job = MkColJob.new(
        propagator.account,
        propagator.web_dav_url,
        propagator.full_remote_path(@item.local_name),
        nil,
        this
      )

      connect(
        qobject_cast < MkColJob > (@job),
        MkColJob.finished_with_error,
        this,
        PropagateRemoteMkdir.slot_mkcol_job_finished
      )

      connect(
        qobject_cast < MkColJob > (@job),
        MkColJob.finished_without_error,
        this,
        PropagateRemoteMkdir.slot_mkcol_job_finished
      )

      @job.start
    end

    def abort(abort_type)
      if @job
        @job.abort
      end

      if abort_type == :asynchronous
        abort_finished
      end
    end

    def set_delete_existing(enabled)
      @delete_existing = enabled
    end

    def slot_mkcol_job_finished
      propagator.active_job_list.remove_one(this)

      unless @job
        raise
      end

      err = @job.reply.error
      @item.http_error_code = @job.reply.attribute(:http_status_code_attribute).to_int
      @item.response_time_stamp = @job.response_timestamp
      @item.request_id = @job.request_id

      if @item.http_error_code == 405
        nil
      elsif err != :no_error
        status = classify_error(err, @item.http_error_code, propagator.another_sync_needed)
        done(status, @job.error_string)

        return
      elsif @item.http_error_code != 201
        done(
          :normal_error,
          "Wrong HTTP code returned by server. Expected 201, but received \#{_item._http_error_code}Wrong HTTP code returned by server. Expected 201, but received "
        )

        return
      end

      @item.file_id = @job.reply.raw_header("OC-FileId")
      propagator.active_job_list.append(this)
      propfind_job = PropfindJob.new(@job.account, @job.base_url, @job.path, :zero, this)
      properties = "http://owncloud.org/ns:permissions"

      if @item.file_id.is_null
        properties.append("http://owncloud.org/ns:fileid")
      end

      propfind_job.set_properties(properties)

      connect(propfind_job, PropfindJob.directory_listing_iterated, this) do |_, result|
        propagator.active_job_list.remove_one(this)
        @item.remote_perm = RemotePermissions.from_server_string(result.value("permissions"))

        if @item.file_id.is_null
          @item.file_id = result.value("fileid").to_utf8
        end

        success
      end

      connect(propfind_job, PropfindJob.finished_with_error, this) do
        propagator.active_job_list.remove_one(this)
        done(:normal_error)
      end

      propfind_job.start
    end

    def success
      item_copy = SyncFileItemPtr.create(@item)
      item_copy.etag.clear
      result = propagator.update_metadata(item_copy)

      if !result
        done(:fatal_error, "Error writing metadata to the database: #{result.error}")

        return
      end

      done(:success)
    end
  end
end
