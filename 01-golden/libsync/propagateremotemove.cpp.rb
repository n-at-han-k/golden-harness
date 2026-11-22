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

require_relative "propagateremotemove"
require_relative "propagatorjobs"
require_relative "owncloudpropagator_p"
require_relative "account"
require_relative "common/syncjournalfilerecord"
require_relative "filesystem"
require_relative "common/asserts"
require "qfile"
require "qstringlist"
require "qdir"

module OCC
  class MoveJob
    def initialize(account, url, path, destination, extra_headers, parent)
      super(account, url, path, parent)
      @destination = destination
      @extra_headers = extra_headers
    end

    def start
      req = QNetworkRequest.new
      req.set_raw_header("Destination", QUrl.to_percent_encoding(@destination, "/"))
      it = @extra_headers.const_begin

      while it != @extra_headers.const_end
        req.set_raw_header(it.key, it.value)
        it += 1
      end

      send_request("MOVE", req)
      AbstractNetworkJob.start
    end

    def finished
      Log.info("sync.networkjob.move") { "MOVE of #{reply.request.url} FINISHED WITH STATUS #{reply_status_string}" }
    end
  end

  class PropagateRemoteMove
    def start
      if propagator.abort_requested
        return
      end

      origin = propagator.adjust_renamed_path(@item.local_name)
      Log.debug("sync.propagator.remotemove") { "#{origin} #{@item.rename_target}" }

      if origin == @item.rename_target
        finalize

        return
      end

      remote_source = propagator.full_remote_path(origin)
      remote_destination = QDir.clean_path(propagator.web_dav_url.path + propagator.full_remote_path(@item.rename_target))
      itype = @item.type

      unless (
        itype != :item_type_virtual_file_download &&
        itype != :item_type_virtual_file_dehydration
      )
        raise
      end

      @job = MoveJob.new(propagator.account, propagator.web_dav_url, remote_source, remote_destination, nil, this)
      connect(@job.data, MoveJob.finished_signal, this, PropagateRemoteMove.slot_move_job_finished)
      propagator.active_job_list.append(this)
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

    def slot_move_job_finished
      propagator.active_job_list.remove_one(this)

      unless @job
        raise
      end

      err = @job.reply.error
      @item.http_error_code = @job.reply.attribute(:http_status_code_attribute).to_int
      @item.response_time_stamp = @job.response_timestamp
      @item.request_id = @job.request_id

      if err != :no_error
        status = classify_error(err, @item.http_error_code, propagator.another_sync_needed)
        done(status, @job.error_string)

        return
      end

      if @item.http_error_code != 201
        done(
          :normal_error,
          "Wrong HTTP code returned by server. Expected 201, but received \#{_item._http_error_code}Wrong HTTP code returned by server. Expected 201, but received "
        )

        return
      end

      finalize
    end

    def finalize
      old_record = propagator.journal.get_file_record(@item.original_file)
      propagator.journal.delete_file_record(@item.original_file)
      new_item = SyncFileItem.new(@item)
      new_item.type = @item.type

      if old_record.is_valid
        new_item.checksum_header = old_record.checksum_header

        if new_item.size != old_record.size
          Log.warn("sync.propagator.remotemove") { "The file sizes differ on server vs sync journal:  #{new_item.size} #{old_record.size}" }
          new_item.size = old_record.size
        end
      end

      result = propagator.update_metadata(new_item)

      if !result
        done(:fatal_error, "Error updating metadata: #{result.error}")

        return
      elsif result.get == :locked
        done(:soft_error, "The file »#{new_item.local_name}« is currently in use")

        return
      end

      if @item.is_directory
        propagator.renamed_directories.insert(@item.local_name, @item.rename_target)

        if !adjust_selective_sync(propagator.journal, @item.local_name, @item.rename_target)
          done(:fatal_error, "Error writing metadata to the database")

          return
        end
      end

      propagator.journal.commit("Remote Rename")
      done(:success)
    end

    def adjust_selective_sync(journal, from_, to_)
      ok = false
      list = journal.get_selective_sync_list(:selective_sync_black_list, ok)

      if !ok
        return false
      end

      changed = false

      unless !from_.ends_with("/")
        raise
      end

      unless !to_.ends_with("/")
        raise
      end

      from = from_ + "/"
      to = to_ + "/"
      out = Set.new
      out.reserve(list.size)
      it = list.begin

      while it != list.end
        if it.starts_with(from)
          out.insert(it.replace(0, from.size, to))
          changed = true
        else
          out.insert(it)
        end

        it += 1
      end

      if changed
        journal.set_selective_sync_list(:selective_sync_black_list, out)
      end

      return true
    end
  end
end
