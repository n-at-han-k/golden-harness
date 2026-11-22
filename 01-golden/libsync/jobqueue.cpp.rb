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

require_relative "jobqueue"

require_relative "abstractnetworkjob"
require_relative "account"

require "qloggingcategory"

module OCC
  class JobQueue
    def initialize(account)
      @account = account
    end

    def block
      @blocked += 1
      Log.debug("sync.networkjob.jobqueue") { "block: #{@blocked} #{@account.display_name_with_host}" }
    end

    def unblock
      if !is_blocked
        return
      end

      @blocked -= 1
      Log.debug("sync.networkjob.jobqueue") { "unblock: #{@blocked} #{@account.display_name_with_host}" }

      if @blocked == 0
        tmp = @jobs

        tmp.each do |job|
          if job
            Log.debug("sync.networkjob.jobqueue") { "Retry #{job}" }
            job.retry
          end
        end
      end
    end

    def is_blocked
      return @blocked != 0
    end

    def retry(job)
      if !job.needs_retry
        return false
      end

      if @blocked != 0
        Log.debug("sync.networkjob.jobqueue") { "Retry queued #{job}" }
        @jobs.push_back(job)
      else
        Log.debug("sync.networkjob.jobqueue") { "Direct retry #{job}" }
        job.retry
      end

      return true
    end

    def enqueue(job)
      if @blocked == 0
        return false
      end

      Log.debug("sync.networkjob.jobqueue") { "Queue #{job}" }
      @jobs.push_back(job)

      return true
    end

    def clear
      @blocked = 0
      tmp = @jobs

      tmp.each do |job|
        if job
          Log.debug("sync.networkjob.jobqueue") { "Abort #{job}" }
          job.abort
        end
      end
    end

    def size
      return @jobs.size
    end
  end

  class JobQueueGuard
    def initialize(queue)
      @queue = queue
    end

    def finalize
      unblock
    end

    def block
      if !@blocked
        @blocked = true
        @queue.block

        return true
      end

      return false
    end

    def unblock
      if @blocked
        @blocked = false
        @queue.unblock

        return true
      end

      return false
    end

    def clear
      if @blocked
        @blocked = false
        @queue.clear

        return true
      end

      return false
    end

    def queue
      return @queue
    end
  end
end
