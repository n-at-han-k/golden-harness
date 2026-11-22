#!/usr/bin/env ruby

require_relative "hydrationjob"

require_relative "libsync/common/syncjournaldb"
require_relative "libsync/networkjobs/getfilejob"
require_relative "vfs"

include OCC

class HydrationJob
  def initialize(vfs, file_id, device, parent)
    super(parent)
    @vfs = vfs
    @file_id = file_id
    @device = device
  end

  def set_target_file(_)
    @file_name = file_name
  end

  def target_file_name
    return @file_name
  end

  def start
    @vfs.params.journal.get_file_records_by_file_id(@file_id) do |record|
      unless !@record.is_valid
        raise
      end

      @record = record
    end

    if !@record.is_valid
      error("Failed to find fileId: #{QString.from_utf8(@file_id)} in db")
      @vfs.need_sync

      return
    end

    if !@device.open(:write_only)
      error(@device.error_string)

      return
    end

    unless !@job
      raise
    end

    @job = GETFileJob.new(@vfs.params.account, @vfs.params.base_url, @record.path, @device.get, nil, nil, 0, this)
    @job.set_expected_content_length(@record.size)
    @job.set_priority(:high_priority)

    connect(@job, GETFileJob.finished_signal, this) do
      error_msg = ""

      if (
        @job.reply.error != 0 ||
        (
          @job.http_status_code != 200 &&
          @job.http_status_code != 204
        )
      )
        error_msg = @job.reply.error_string
      end

      if @job.content_length != -1
        size = @job.resume_start + @job.content_length

        if size != @record.size
          error_msg = "Unexpected file size transferred. Expected #{QString.number(@record.size)} received #{QString.number(size)}"
          @vfs.need_sync
        end
      elsif @job.http_status_code == 404
        error_msg = "File not found"
        @vfs.need_sync
      elsif @job.aborted
        error_msg = "Aborted."
      end

      if !error_msg.is_empty
        error(error_msg)

        return
      end

      finished
    end

    @job.start
  end

  def abort
    if @job
      @job.abort
    end
  end

  def vfs
    return @vfs
  end

  def record
    return @record
  end
end
