#!/usr/bin/env ruby
#
# Copyright (C) Hannah von Reth <hannah.vonreth@owncloud.com>
# Copyright (C) Fabian Müller <fmueller@owncloud.com>
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

require_relative "abstractcorejob"

include OCC

class AbstractCoreJobFactory
  def initialize(nam)
    @nam = nam
  end

  def finalize
  end

  def nam
    return @nam
  end

  def set_job_result(job, result)
    job.set_result(result)
  end

  def set_job_error(job, error_message)
    job.set_error(error_message)
  end
end

class CoreJob
  def initialize(reply, parent)
    super(parent)
    @reply = reply
    @reply.set_parent(this)
    connect(this, CoreJob.finished, this, CoreJob.delete_later, :queued_connection)
  end

  def result
    return @result
  end

  def error_message
    return @error_message
  end

  def reply
    return @reply
  end

  def success
    return @success
  end

  def set_result(result)
    if assert_not_finished
      @success = true
      @result = result
      finished
    end
  end

  def set_error(error_message)
    if assert_not_finished
      @error_message = error_message
      finished
    end
  end

  def assert_not_finished
    unless @result.is_null
      raise
    end

    unless @error_message.is_empty
      raise
    end

    return @result.is_null && @error_message.is_empty
  end
end
