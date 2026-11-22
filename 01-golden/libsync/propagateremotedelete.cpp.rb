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

require_relative "propagateremotedelete"
require_relative "owncloudpropagator_p"
require_relative "account"
require_relative "common/asserts"

require "qloggingcategory"

module OCC
  class DeleteJob
    def initialize(account, url, path, parent)
      super(account, url, path, parent)
    end

    def start
      send_request("DELETE")
      AbstractNetworkJob.start
    end

    def finished
      Log.info("sync.networkjob.delete") { "DELETE of #{reply.request.url} FINISHED WITH STATUS #{reply_status_string}" }
    end
  end

  class PropagateRemoteDelete
    def start
      if propagator.abort_requested
        return
      end

      Log.debug("sync.propagator.remotedelete") { "#{@item.local_name}" }

      @job = DeleteJob.new(
        propagator.account,
        propagator.web_dav_url,
        propagator.full_remote_path(@item.local_name),
        this
      )

      connect(@job.data, DeleteJob.finished_signal, this, PropagateRemoteDelete.slot_delete_job_finished)
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

    def slot_delete_job_finished
      propagator.active_job_list.remove_one(this)

      unless @job
        raise
      end

      err = @job.reply.error
      http_status = @job.reply.attribute(:http_status_code_attribute).to_int
      @item.http_error_code = http_status
      @item.response_time_stamp = @job.response_timestamp
      @item.request_id = @job.request_id

      if err != :no_error && err != :content_not_found_error
        status = classify_error(err, @item.http_error_code, propagator.another_sync_needed)
        done(status, @job.error_string)

        return
      end

      if http_status != 204 && http_status != 404
        done(
          :normal_error,
          "Wrong HTTP code returned by server. Expected 204, but received \#{_item._http_error_code}Wrong HTTP code returned by server. Expected 204, but received "
        )

        return
      end

      propagator.journal.delete_file_record(@item.original_file, @item.is_directory)
      propagator.journal.commit("Remote Remove")
      done(:success)
    end
  end
end
