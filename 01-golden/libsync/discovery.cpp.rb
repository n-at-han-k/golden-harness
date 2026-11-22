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

require_relative "discovery"
require_relative "csync"
require_relative "owncloudpropagator"
require_relative "syncfileitem"

require_relative "csync_exclude"

require_relative "libsync/common/checksums"
require_relative "libsync/common/syncjournaldb"
require_relative "libsync/filesystem"

require "algorithm"

require "qfile"
require "qfileinfo"
require "qthreadpool"

module OCC
  class ProcessDirectoryJob
    Entries = Struct.new(
      :db_entry,
      :server_entry,
      :local_entry,
      keyword_init: true
    )
    def start
      Log.info("sync.discovery") { "STARTING #{@current_folder.server} #{@query_server} #{@current_folder.local} #{@query_local}" }

      if @query_server == :normal_query
        @server_job = start_async_server_query
      else
        @server_query_done = true
      end

      if @query_local == :normal_query
        if (
          !@discovery_data.should_discover_locally(@current_folder.local) &&
          (
            @current_folder.local == @current_folder.original ||
            !@discovery_data.should_discover_locally(@current_folder.original)
          )
        )
          @query_local = :parent_not_changed
        end
      end

      if @query_local == :normal_query
        start_async_local_query
      else
        @local_query_done = true
      end

      if @local_query_done && @server_query_done
        process
      end
    end

    def process
      unless @local_query_done && @server_query_done
        raise
      end

      entries = Hash.new do |hash, key|
        hash[key] = Entries.new
      end

      @server_normal_query_entries.each do |e|
        entries[e.name].server_entry = e
      end

      @server_normal_query_entries.clear

      if !@discovery_data.statedb.list_files_in_path(@current_folder.original) { |rec|
        entries[rec.name].db_entry = rec
      }
        db_error

        return
      end

      @local_normal_query_entries.each do |e|
        entries[e.name].local_entry = e
      end

      @local_normal_query_entries.clear

      entries.each do |f|
        e = f.second
        path = @current_folder.add_name(f.first)
        is_hidden = e.local_entry.is_hidden || f.first[0] == "."

        if handle_excluded(path.target, e.local_entry.name, e.local_entry.is_directory || e.server_entry.is_directory, is_hidden, e.local_entry.is_sym_link, e.server_entry.is_vault_file)

          if !e.local_entry.is_valid && e.db_entry.is_valid
            Log.warn("sync.discovery") { "Removing db entry for non existing ignored file: #{path.original}" }
            @discovery_data.statedb.delete_file_record(path.original, true)
          end

          next
        end

        if (
          @query_server == :in_black_list ||
          @discovery_data.is_in_selective_sync_black_list(path.original)
        )
          process_blacklisted(path, e.local_entry, e.db_entry)

          next
        end

        process_file(path, e.local_entry, e.server_entry, e.db_entry)
      end

      QTimer.single_shot(0, @discovery_data, DiscoveryPhase.schedule_more_jobs)
    end
  end
end
