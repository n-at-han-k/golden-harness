#!/usr/bin/env ruby
#
# Copyright (C) by Olivier Goffart <ogoffart@woboq.com>
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

require_relative "discoveryphase"
require_relative "discovery"

require_relative "account"
require_relative "common/asserts"
require_relative "common/checksums"
require_relative "filesystem"

require "qdatetime"
require "qfile"
require "qloggingcategory"
require "qurl"
require "cstring"

include Qt::Literals::StringLiterals

module OCC
  class DiscoveryPhase
    def find_path_in_list(list, path)
      if list.size == 1 && list.cbegin == "/"
        return true
      end

      path_slash = path + "/"
      it = std::lower_bound(list.begin, list.end, path_slash)

      if it != list.end && it == path_slash
        return true
      end

      if it == list.begin
        return false
      end

      it -= 1

      unless it.ends_with("/")
        raise
      end

      return path_slash.starts_with(it)
    end

    def is_in_selective_sync_black_list(path)
      if @selective_sync_black_list.empty
        return false
      end

      if find_path_in_list(@selective_sync_black_list, path)
        return true
      end

      return false
    end

    def adjust_renamed_path(original, d)
      if d == :down
        return OCC.adjust_renamed_path(@renamed_items_remote, original)
      else
        return OCC.adjust_renamed_path(@renamed_items_local, original)
      end
    end

    def adjust_renamed_path_with_original(renamed_items, original)
      slash_pos = original.size
      slash_pos = original.last_index_of("/", slash_pos - 1)

      while slash_pos > 0
        it = renamed_items.const_find(original.left(slash_pos))

        if it != renamed_items.const_end
          return it + original.mid(slash_pos)
        end

        slash_pos = original.last_index_of("/", slash_pos - 1)
      end

      return original
    end

    def find_and_cancel_deleted_job(original_path)
      result = false
      old_etag = ""
      it = @deleted_item.const_find(original_path)

      if it != @deleted_item.cend
        item = it
        instruction = item.instruction

        if (
          instruction == CSYNC_INSTRUCTION_IGNORE &&
          item.type == :item_type_virtual_file
        )
          result = true
          old_etag = item.etag
        else
          if !(instruction == CSYNC_INSTRUCTION_REMOVE || (item.type == :item_type_virtual_file && instruction == CSYNC_INSTRUCTION_NEW) || (item.is_restoration && instruction == CSYNC_INSTRUCTION_NEW) || (item.has_blacklist_entry && instruction == CSYNC_INSTRUCTION_IGNORE))

            Log.warn("sync.discovery") { "OC_ENFORCE(FAILING) #{original_path}" }
            Log.warn("sync.discovery") { "instruction == CSYNC_INSTRUCTION_REMOVE #{instruction == CSYNC_INSTRUCTION_REMOVE}" }

            Log.warn("sync.discovery") {
              "(item._type == ItemTypeVirtualFile && instruction == CSYNC_INSTRUCTION_NEW)" \
                "#{item.type == :item_type_virtual_file && instruction == CSYNC_INSTRUCTION_NEW}"
            }

            Log.warn("sync.discovery") {
              "(item._isRestoration && instruction == CSYNC_INSTRUCTION_NEW)" \
                "#{item.is_restoration && instruction == CSYNC_INSTRUCTION_NEW}"
            }

            Log.warn("sync.discovery") {
              "(item._hasBlacklistEntry && instruction == CSYNC_INSTRUCTION_IGNORE)" \
                "#{item.has_blacklist_entry && instruction == CSYNC_INSTRUCTION_IGNORE}"
            }

            Log.warn("sync.discovery") { "instruction #{instruction}" }
            Log.warn("sync.discovery") { "item._type #{item.type}" }
            Log.warn("sync.discovery") { "item._isRestoration  #{item.is_restoration}" }
            Log.warn("sync.discovery") { "item._remotePerm #{item.remote_perm}" }

            unless false
              raise
            end
          end

          item.set_instruction(CSYNC_INSTRUCTION_NONE)
          result = true
          old_etag = item.etag
        end

        @deleted_item.erase(it)
      end

      other_job = @queued_deleted_directories.take(original_path)

      if other_job
        old_etag = other_job.dir_item.etag
        delete other_job
        result = true
      end

      return [result, old_etag]
    end

    def start_job(job)
      unless !@current_root_job
        raise
      end

      connect(job, ProcessDirectoryJob.finished, this) do
        unless @current_root_job == sender
          raise
        end

        @current_root_job = nil

        if job.dir_item
          item_discovered(job.dir_item)
        end

        job.delete_later

        if !@queued_deleted_directories.is_empty
          next_job = @queued_deleted_directories.take(@queued_deleted_directories.first_key)
          start_job(next_job)
        else
          finished
        end
      end

      @current_root_job = job
      job.start
    end

    def set_selective_sync_black_list(list)
      @selective_sync_black_list = [list.cbegin, list.cend]
    end

    def set_selective_sync_white_list(list)
      @selective_sync_white_list = [list.cbegin, list.cend]
    end

    def schedule_more_jobs
      limit = std::max(1, @sync_options.parallel_network_jobs)

      if @current_root_job && @currently_active_jobs < limit
        @current_root_job.process_sub_jobs(limit - @currently_active_jobs)
      end
    end
  end

  class DiscoverySingleLocalDirectoryJob
    def initialize(account, local_path, vfs, parent)
      super(parent)
      super()
      @local_path = local_path
      @account = account
      @vfs = vfs
      q_register_meta_type("QVector<LocalInfo>")
    end

    def run
      ec = nil
      local_path = FileSystem.to_filesystem_path(@local_path)
      results = []

      std::filesystem::directory_iterator.new(local_path, ec).each do |dirent|
        info = @vfs.stat_type_virtual_file(dirent)

        if info.type == :item_type_unsupported
          next
        end

        if !info.is_valid
          next
        end

        results.push_back(info)
      end

      if ec
        Log.error("sync.discovery") { "Error while opening directory #{@local_path} #{ec.message}" }
        error_string = "Error while opening directory »#{@local_path}«"

        if ec.value == EACCES
          error_string = "Directory not accessible on client, permission denied"
          finished_non_fatal_error(error_string)

          return
        elsif ec.value == ENOENT
          error_string = "Directory not found: »#{@local_path}«"
        elsif ec.value == ENOTDIR
          return
        end

        finished_fatal_error(error_string)

        return
      end

      finished(results)
    end
  end

  class DiscoverySingleDirectoryJob
    def initialize(account, base_url, path, parent)
      super(parent)
      @sub_path = path
      @account = account
      @base_url = base_url
      @ignored_first = false
      @is_root_path = false
    end

    def start
      @pro_find_job = PropfindJob.new(@account, @base_url, @sub_path, :one, this)
      @pro_find_job.set_properties(["resourcetype", "getlastmodified", "getcontentlength", "getetag", "http://owncloud.org/ns:id", "http://owncloud.org/ns:permissions", "http://owncloud.org/ns:checksums", "ocrclone:integrity-id"])

      QObject.connect(
        @pro_find_job,
        PropfindJob.directory_listing_iterated,
        this,
        DiscoverySingleDirectoryJob.directory_listing_iterated_slot
      )

      QObject.connect(@pro_find_job, PropfindJob.finished_with_error, this) do
        msg = @pro_find_job.error_string

        if (
          @pro_find_job.reply.error == :no_error &&
          !@pro_find_job.reply.header(:content_type_header).to_string.contains("application/xml; charset=utf-8")
        )
          msg = "Server error: PROPFIND reply is not XML formatted!"
        end

        finished(HttpError.new(@pro_find_job.http_status_code, msg))
        delete_later
      end

      QObject.connect(
        @pro_find_job,
        PropfindJob.finished_without_error,
        this,
        DiscoverySingleDirectoryJob.ls_job_finished_without_error_slot
      )

      @pro_find_job.start
    end

    def abort
      if @pro_find_job
        @pro_find_job.abort
      end
    end

    def directory_listing_iterated_slot(file, map)
      if !@ignored_first
        @ignored_first = true
        it = Utility.optional_find(map, "permissions")

        if it
          perm = RemotePermissions.from_server_string(it.value)
          first_directory_permissions(perm)
        end
      else
        @results.emplace_back(file, map)
      end

      if @first_etag.is_empty
        it = Utility.optional_find(map, "getetag")

        if it
          @first_etag = Utility.normalize_etag(it.value)
        end
      end
    end

    def ls_job_finished_without_error_slot
      if !@ignored_first
        finished(HttpError.new(0, "Server error: PROPFIND reply is not XML formatted!"))
        delete_later

        return
      elsif !@error.is_empty
        finished(HttpError.new(0, @error))
        delete_later

        return
      end

      etag(@first_etag, @pro_find_job.response_q_time_stamp)
      finished(@results)
      delete_later
    end
  end
end
