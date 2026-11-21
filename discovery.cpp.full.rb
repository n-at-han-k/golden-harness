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
          @current_folder.local == @current_folder.original ||
          !@discovery_data.should_discover_locally(@current_folder.original)
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

    Entries = Struct.new(
      :db_entry,
      :server_entry,
      :local_entry,
      keyword_init: true
    )
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

      QTimer.single_shot(0, @discovery_data, &DiscoveryPhase.schedule_more_jobs)
    end

    def handle_excluded(path, local_name, is_directory, is_hidden, is_symlink, is_vault_file)
      excluded = @discovery_data.excludes.traversal_pattern_match(path, (is_directory ? ItemTypeDirectory : ItemTypeFile))
      is_invalid_pattern = false

      if (
        excluded == CSYNC_NOT_EXCLUDED &&
        !@discovery_data.invalid_filename_rx.pattern.is_empty
      )
        if path.contains(@discovery_data.invalid_filename_rx)
          excluded = CSYNC_FILE_EXCLUDE_INVALID_CHAR
          is_invalid_pattern = true
        end
      end

      if (
        excluded == CSYNC_NOT_EXCLUDED &&
        @discovery_data.ignore_hidden_files &&
        is_hidden
      )
        excluded = CSYNC_FILE_EXCLUDE_HIDDEN
      end

      if (
        excluded == CSYNC_NOT_EXCLUDED &&
        !local_name.is_empty &&
        @discovery_data.server_blacklisted_files.contains(local_name)
      )
        excluded = CSYNC_FILE_EXCLUDE_SERVER_BLACKLISTED
        is_invalid_pattern = true
      end

      if (excluded == CSYNC_NOT_EXCLUDED && !is_symlink && !is_vault_file)
        return false
      elsif excluded == CSYNC_FILE_SILENTLY_EXCLUDED
        @discovery_data.silently_excluded(path)

        return true
      end

      item = SyncFileItemPtr.create(path)
      item.original_file = path
      item.set_instruction(CSYNC_INSTRUCTION_IGNORE)

      if is_symlink
        item.error_string = "Symbolic links are not supported in syncing."
      elsif is_vault_file
        item.error_string = "Encrypted vault files are not synchronized because they are currently not supported by this application."
      else
        case excluded
        when CSYNC_NOT_EXCLUDED
          nil
        when CSYNC_FILE_SILENTLY_EXCLUDED
          Q_UNREACHABLE
        when CSYNC_FILE_EXCLUDE_LIST
          item.error_string = "The file is listed on the ignore list."
          item.status = :excluded
        when CSYNC_FILE_EXCLUDE_INVALID_CHAR
          if item.local_name.ends_with(".")
            item.error_string = "File names ending with a period are not supported on this file system."
          else
            unsupported_character = QChar

            if (!unsupported_character.is_null)
              item.error_string = "File names containing the character '%1' are not supported on this file system.".arg(unsupported_character)
            elsif (is_invalid_pattern)
              item.error_string = "File name contains at least one invalid character"
            else
              item.error_string = "The file name is a reserved name on this file system."

              if !local_name.is_empty
                item.status = :excluded
              end
            end
          end
        when CSYNC_FILE_EXCLUDE_TRAILING_SPACE
          item.error_string = "Filename contains trailing spaces."
        when CSYNC_FILE_EXCLUDE_LONG_FILENAME
          item.error_string = "Filename is too long."
        when CSYNC_FILE_EXCLUDE_HIDDEN
          item.error_string = "File/Folder is ignored because it's hidden."
          item.status = :excluded
        when CSYNC_FILE_EXCLUDE_CONFLICT
          item.error_string = "Conflict: Server version downloaded, local copy renamed and not uploaded."
          item.status = :conflict
        when CSYNC_FILE_EXCLUDE_SERVER_BLACKLISTED
          item.error_string = "The filename is blacklisted on the server."
        end
      end

      @child_ignored = true
      @discovery_data.item_discovered(item)

      return true
    end

    def process_file(path, local_entry, server_entry, db_entry)
      has_server = (server_entry.is_valid ? "true" : (@query_server == :parent_not_changed ? "db" : "false"))
      has_local = (local_entry.is_valid ? "true" : (@query_local == :parent_not_changed ? "db" : "false"))

      Log.info("sync.discovery") {
        "Processing (db|local|remote)  #{path.original}" \
          " | valid:  #{db_entry.is_valid} / #{has_local} / #{has_server}" \
          " | mtime:  #{db_entry.modtime} / #{local_entry.modtime} / #{server_entry.modtime}" \
          " | size:  #{db_entry.size} / #{local_entry.size} / #{server_entry.size}" \
          " | etag:  #{db_entry.etag} // #{server_entry.etag}" \
          " | checksum:  #{db_entry.checksum_header} // #{server_entry.checksum_header}" \
          " | perm:  #{db_entry.remote_perm} // #{server_entry.remote_perm}" \
          " | fileid:  #{db_entry.file_id} // #{server_entry.file_id}" \
          " | inode:  #{db_entry.inode} / #{local_entry.inode} /" \
          " | type:  #{db_entry.type} / #{local_entry.type} /" \
          " #{server_entry.is_directory ? ItemTypeDirectory : ItemTypeFile}"
      }

      if @discovery_data.is_renamed(path.original)
        Log.debug("sync.discovery") { "Ignoring renamed" }

        return
      end

      item = SyncFileItem.from_sync_journal_file_record(db_entry)
      item.set_local_name(path.target)
      item.original_file = path.original
      item.previous_size = db_entry.size
      item.previous_modtime = db_entry.modtime

      if (item.type == :item_type_virtual_file_download)
        item.type = :item_type_virtual_file
      elsif (item.type == :item_type_virtual_file_dehydration)
        item.type = :item_type_file
      end

      if server_entry.is_valid
        process_file_analyze_remote_info(item, path, local_entry, server_entry, db_entry)

        return
      end

      if (
        @query_server == :parent_not_changed &&
        db_entry.is_valid &&
        (
          db_entry.type == :item_type_virtual_file_download ||
          local_entry.type == :item_type_virtual_file_download
        ) &&
        (
          local_entry.is_valid ||
          @query_local == :parent_not_changed
        )
      )
        item.direction = :down
        item.set_instruction(CSYNC_INSTRUCTION_SYNC)
        item.type = :item_type_virtual_file_download
      end

      process_file_analyze_local_info(item, path, local_entry, server_entry, db_entry, @query_server)
    end

    def compute_local_checksum(header, path, item)
      checksum_header = ChecksumHeader.parse_checksum_header(header)

      if checksum_header.is_valid
        checksum = ComputeChecksum.compute_now_on_file(path, checksum_header.type)

        if !checksum.is_empty
          item.checksum_header = ChecksumHeader(checksum_header.type, checksum).make_checksum_header

          return true
        end
      end

      return false
    end

    def process_file_analyze_remote_info(item, path, local_entry, server_entry, db_entry)
      item.checksum_header = server_entry.checksum_header
      item.file_id = server_entry.file_id
      item.remote_perm = server_entry.remote_perm
      item.type = (server_entry.is_directory ? ItemTypeDirectory : ItemTypeFile)
      item.etag = server_entry.etag

      if !server_entry.error.is_empty
        item.set_instruction(CSYNC_INSTRUCTION_ERROR)
        @child_ignored = true
        item.error_string = server_entry.error
        Log.warn("sync.discovery") { "#{item.error_string}" }
        @discovery_data.item_discovered(item)

        return
      end

      if db_entry.is_valid
        if (server_entry.is_directory != db_entry.is_directory)
          item.set_instruction(CSYNC_INSTRUCTION_TYPE_CHANGE)
          item.direction = :down
          item.modtime = server_entry.modtime
          item.size = server_entry.size

          if db_entry.is_directory
            if (
              @discovery_data.sync_options.vfs.mode != :off &&
              @pin_state != :always_local
            )
              item.type = :item_type_virtual_file
            end
          end
        elsif (
          (
            db_entry.type == :item_type_virtual_file_download ||
            local_entry.type == :item_type_virtual_file_download
          ) &&
          (
            local_entry.is_valid ||
            @query_local == :parent_not_changed
          )
        )
          item.direction = :down
          item.set_instruction(CSYNC_INSTRUCTION_SYNC)
          item.type = :item_type_virtual_file_download
          item.size = server_entry.size
        elsif db_entry.etag != server_entry.etag
          item.direction = :down
          item.modtime = server_entry.modtime
          item.size = server_entry.size

          if server_entry.is_directory
            unless db_entry.is_directory
              raise
            end

            item.set_instruction(CSYNC_INSTRUCTION_UPDATE_METADATA)

          elsif (!local_entry.is_valid && @query_local != :parent_not_changed)
            item.set_instruction(CSYNC_INSTRUCTION_NEW)
          else
            item.set_instruction(CSYNC_INSTRUCTION_SYNC)
          end
        elsif (
          db_entry.remote_perm != server_entry.remote_perm ||
          db_entry.file_id != server_entry.file_id
        )
          item.set_instruction(CSYNC_INSTRUCTION_UPDATE_METADATA)
          item.direction = :down
        else
          process_file_analyze_local_info(item, path, local_entry, server_entry, db_entry, ParentNotChanged)

          return
        end

        process_file_analyze_local_info(item, path, local_entry, server_entry, db_entry, @query_server)

        return
      end

      Q_ASSERT(!db_entry.is_valid)
      item.set_instruction(CSYNC_INSTRUCTION_NEW)
      item.direction = :down
      item.modtime = server_entry.modtime
      item.size = server_entry.size

      post_process_server_new = lambda do
        opts = @discovery_data.sync_options

        if (
          !local_entry.is_valid &&
          item.type == :item_type_file &&
          opts.vfs.mode != :off &&
          @pin_state != :always_local
        )
          item.type = ItemTypeVirtualFile
        end

        process_file_analyze_local_info(item, path, local_entry, server_entry, db_entry, @query_server)
      end

      if local_entry.is_valid
        post_process_server_new.call

        return
      end

      Q_ASSERT(!db_entry.is_valid && !local_entry.is_valid)
      done = false
      async = false

      rename_candidate_processing = lambda do |base|
        if (done)
          return
        end

        if (!base.is_valid)
          return
        end

        if (base.type == :item_type_virtual_file_download)
          item.type = ItemTypeVirtualFileDownload
          done = true

          return
        end

        if (base.type == :item_type_virtual_file_dehydration)
          done = true

          return
        end

        if (base.is_directory != item.is_directory)
          q_c_info(lc_disco, "file types different, not a rename")
          done = true

          return
        end

        if (!server_entry.is_directory && base.etag != server_entry.etag)
          q_c_info(lc_disco, "file etag different, not a rename")
          done = true

          return
        end

        original_path = base.path

        if (@discovery_data.is_renamed(original_path))
          q_c_info(lc_disco, "folder already has a rename entry, skipping")

          return
        end

        original_path_adjusted = @discovery_data.adjust_renamed_path(original_path, :up)

        if (!base.is_directory)
          info = std::filesystem::directory_entry(FileSystem.to_filesystem_path(@discovery_data.local_dir + original_path_adjusted))

          if (!info.exists)
            Log.info("sync.discovery") { "Local file does not exist anymore. #{original_path_adjusted}" }

            return
          end

          if (
            FileSystem.fileTimeToTime_t(info.last_write_time) != base.modtime ||
            info.file_size != base.size ||
            info.is_directory
          )
            Log.info("sync.discovery") { "The file has changed locally, not a rename. #{original_path}" }

            return
          end
        else
          if (!QFileInfo(@discovery_data.local_dir + original_path_adjusted).is_dir)
            Log.info("sync.discovery") { "Local directory does not exist anymore. #{original_path_adjusted}" }

            return
          end
        end

        if (base.is_virtual_file)
          item.type = ItemTypeVirtualFile
        end

        was_deleted_on_server = @discovery_data.find_and_cancel_deleted_job(original_path).first

        post_process_rename = lambda do |path|
          adjusted_original_path = @discovery_data.adjust_renamed_path(original_path, :up)
          @discovery_data.renamed_items_remote.insert(original_path, path.target)
          item.modtime = base.modtime
          item.inode = base.inode
          item.set_instruction(CSYNC_INSTRUCTION_RENAME)
          item.direction = :down
          item.rename_target = path.target
          item.set_local_name(adjusted_original_path)
          item.original_file = original_path
          path.original = original_path
          path.local = adjusted_original_path
          Log.info("sync.discovery") { "Rename detected (down)  #{item.local_name}  .  #{item.rename_target}" }
        end

        if (was_deleted_on_server)
          post_process_rename.call(path)
          done = true
        else
          @pending_async_jobs += 1
          job = RequestEtagJob.new(@discovery_data.account, @discovery_data.base_url, @discovery_data.remote_folder + original_path, this)

          connect(job, RequestEtagJob.finished_signal, this, lambda {
            @pending_async_jobs -= 1
            QTimer.single_shot(0, @discovery_data, &DiscoveryPhase.schedule_more_jobs)

            if (
              job.http_status_code == 207 ||
              @discovery_data.is_renamed(original_path)
            )
              post_process_server_new.call

              return
            elsif (job.http_status_code == 404)
              @discovery_data.find_and_cancel_deleted_job(original_path)
              post_process_rename.call(path)

              process_file_finalize(
                item, path, item.is_directory, (item.instruction == CSYNC_INSTRUCTION_RENAME ? NormalQuery : ParentDontExist), @query_server
              )

              return
            end

            @discovery_data.fatal_error("Error while doing a rename, unhandled status code: %1".arg(job.http_status_code))
          })

          job.start
          done = true
          async = true
        end
      end

      if !@discovery_data.statedb.get_file_records_by_file_id(server_entry.file_id, rename_candidate_processing)
        db_error

        return
      end

      if async
        return
      end

      if item.instruction == CSYNC_INSTRUCTION_NEW
        post_process_server_new.call

        return
      end

      process_file_analyze_local_info(item, path, local_entry, server_entry, db_entry, @query_server)
    end

    def process_file_analyze_local_info(item, path, local_entry, server_entry, db_entry, recurse_query_server)
      no_server_entry = (
        (@query_server != :parent_not_changed && !server_entry.is_valid) ||
        (@query_server == :parent_not_changed && !db_entry.is_valid)
      )

      if no_server_entry
        recurse_query_server = :parent_dont_exist
      end

      server_modified = lambda do
        modified_on_server = (
          item.instruction & (CSYNC_INSTRUCTION_NEW | CSYNC_INSTRUCTION_SYNC | CSYNC_INSTRUCTION_RENAME | CSYNC_INSTRUCTION_TYPE_CHANGE)
        )

        has_local_virtual = local_entry.is_virtual_file || (@query_local == :parent_not_changed && db_entry.is_virtual_file)

        virtual_file_download = (
          item.type == :item_type_virtual_file_download ||
          item.instruction == CSYNC_INSTRUCTION_TYPE_CHANGE
        )

        if (modified_on_server && !virtual_file_download && has_local_virtual)
          item.set_instruction(CSYNC_INSTRUCTION_UPDATE_METADATA)
          modified_on_server = false
          item.type = :item_type_virtual_file
        end

        if db_entry.is_virtual_file && !virtual_file_download
          item.type = :item_type_virtual_file
        end

        return modified_on_server
      end.call

      @child_modified |= server_modified

      finalize = lambda do |path, recurse_query_server|
        recurse = item.is_directory || local_entry.is_directory || server_entry.is_directory

        if (item.instruction == CSYNC_INSTRUCTION_CONFLICT && !item.is_directory)
          recurse = false
        end

        if (@query_local != :normal_query && @query_server != :normal_query)
          recurse = false
        end

        if @query_local == :parent_not_changed
          recurse_query_local = :parent_not_changed
        else
          if local_entry.is_directory || item.instruction == CSYNC_INSTRUCTION_RENAME
            :normal_query
          else
            :parent_dont_exist
          end
        end

        process_file_finalize(item, path, recurse, recurse_query_local, recurse_query_server)
      end

      if !local_entry.is_valid
        if (@query_local == :parent_not_changed && db_entry.is_valid)
          if (no_server_entry)
            item.set_instruction(CSYNC_INSTRUCTION_REMOVE)
            item.direction = :down
          elsif (db_entry.type == :item_type_virtual_file_dehydration)
            item.direction = :down
            item.set_instruction(CSYNC_INSTRUCTION_SYNC)
            item.type = :item_type_virtual_file_dehydration
          end
        elsif (no_server_entry)
          Log.info("sync.discovery") { "Stale DB entry" }
          @discovery_data.statedb.delete_file_record(path.original, true)

          return
        elsif !server_modified
          if !db_entry.server_has_ignored_files
            item.set_instruction(CSYNC_INSTRUCTION_REMOVE)
            item.direction = :up
          end

          finalize.call(path, recurse_query_server)

          return
        end
      end

      unless local_entry.is_valid
        raise
      end

      item.inode = local_entry.inode

      if db_entry.is_valid
        type_change = local_entry.is_directory != db_entry.is_directory

        if (!type_change && local_entry.is_virtual_file)
          if no_server_entry
            item.set_instruction(CSYNC_INSTRUCTION_REMOVE)
            item.direction = :down
          end
        elsif (
          !type_change &&
          (
            (
              db_entry.modtime == local_entry.modtime &&
              db_entry.size == local_entry.size
            ) ||
            (
              local_entry.is_directory
            )
          )
        )

          if (no_server_entry)
            item.set_instruction(CSYNC_INSTRUCTION_REMOVE)
            item.direction = :down
          elsif (
            db_entry.type == :item_type_virtual_file_dehydration ||
            local_entry.type == :item_type_virtual_file_dehydration
          )
            item.direction = :down
            item.set_instruction(CSYNC_INSTRUCTION_SYNC)
            item.type = :item_type_virtual_file_dehydration
          elsif (
            !server_modified &&
            db_entry.inode != local_entry.inode ||
            @discovery_data.sync_options.vfs.needs_metadata_update(*item)
          )
            item.set_instruction(CSYNC_INSTRUCTION_UPDATE_METADATA)
            item.direction = :down
          end
        elsif (server_modified)
          process_file_conflict(item, path, local_entry, server_entry, db_entry)
        elsif (type_change)
          item.set_instruction(CSYNC_INSTRUCTION_TYPE_CHANGE)
          item.direction = :up
          item.checksum_header.clear
          item.size = local_entry.size
          item.modtime = local_entry.modtime
          item.type = (local_entry.is_directory ? ItemTypeDirectory : ItemTypeFile)
          @child_modified = true
        else
          item.set_instruction(CSYNC_INSTRUCTION_SYNC)

          if no_server_entry
            item.set_instruction(CSYNC_INSTRUCTION_NEW)
          end

          item.direction = :up
          item.checksum_header.clear
          item.size = local_entry.size
          item.modtime = local_entry.modtime
          @child_modified = true
          is_eml_file = path.original.ends_with(".eml", :case_insensitive)

          if (
            is_eml_file &&
            db_entry.size == local_entry.size &&
            !db_entry.checksum_header.is_empty
          )
            if (
              compute_local_checksum(db_entry.checksum_header, @discovery_data.local_dir + path.local, item) &&
              item.checksum_header == db_entry.checksum_header
            )
              Log.info("sync.discovery") { "NOTE: Checksums are identical, file did not actually change:  #{path.local}" }
              item.set_instruction(CSYNC_INSTRUCTION_UPDATE_METADATA)
            end
          end
        end

        finalize.call(path, recurse_query_server)

        return
      end

      unless !db_entry.is_valid
        raise
      end

      if (local_entry.is_virtual_file && !no_server_entry)
        unless item.instruction == CSYNC_INSTRUCTION_UPDATE_METADATA
          raise
        end

        unless item.type == :item_type_virtual_file
          raise
        end

        finalize.call(path, recurse_query_server)

        return
      elsif (server_modified)
        process_file_conflict(item, path, local_entry, server_entry, db_entry)
        finalize.call(path, recurse_query_server)

        return
      end

      item.set_instruction(CSYNC_INSTRUCTION_NEW)
      item.direction = :up
      item.checksum_header.clear
      item.size = local_entry.size
      item.modtime = local_entry.modtime

      if local_entry.is_directory
        item.type = ItemTypeDirectory
      else
        if local_entry.is_virtual_file
          item.type = ItemTypeVirtualFile
        else
          item.type = ItemTypeFile
        end
      end

      @child_modified = true

      post_process_local_new = lambda do |path|
        if (local_entry.is_virtual_file)
          is_place_holder = @discovery_data.sync_options.vfs.is_dehydrated_placeholder(@discovery_data.local_dir + path.local)

          if (is_place_holder)
            Log.warn("sync.discovery") { "Wiping virtual file without db entry for #{path.local}" }
            item.set_instruction(CSYNC_INSTRUCTION_REMOVE)
            item.direction = :down
          elsif Log.warn("sync.discovery") { "Virtual file without db entry for #{path.local} but looks odd, keeping" }
            item.set_instruction(CSYNC_INSTRUCTION_IGNORE)
          end
        end
      end

      base = @discovery_data.statedb.get_file_record_by_inode(local_entry.inode)

      if base.has_error
        db_error

        return
      end

      original_path = base.path

      move_check = lambda do
        if (!base.is_valid)
          Log.info("sync.discovery") { "Not a move, no item in db with inode #{local_entry.inode}" }

          return false
        end

        if (base.is_directory != item.is_directory)
          Log.info("sync.discovery") { "Not a move, types don't match #{base.type} #{item.type} #{local_entry.type}" }

          return false
        end

        if (
          !local_entry.is_directory &&
          !base.is_virtual_file &&
          base.modtime != local_entry.modtime ||
          base.size != local_entry.size
        )
          Log.info("sync.discovery") { "Not a move, mtime or size differs,  modtime: #{base.modtime} #{local_entry.modtime} ,  size:" } << base.size << local_entry.size

          return false
        end

        if (
          QFile.exists(@discovery_data.local_dir + original_path) &&
          !(
            Utility.fs_case_preserving &&
            original_path.compare(path.local, :case_insensitive) == 0 &&
            original_path != path.local
          )
        )
          Log.info("sync.discovery") { "Not a move, base file still exists at #{original_path}" }

          return false
        end

        if (
          !base.checksum_header.is_empty &&
          item.type == :item_type_file &&
          base.type == :item_type_file
        )
          if (compute_local_checksum(base.checksum_header, @discovery_data.local_dir + path.original, item))
            Log.info("sync.discovery") { "checking checksum of potential rename  #{path.original} #{item.checksum_header} #{base.checksum_header}" }

            if (item.checksum_header != base.checksum_header)
              Log.info("sync.discovery") { "Not a move, checksums differ" }

              return false
            end
          end
        end

        if (@discovery_data.is_renamed(original_path))
          Log.info("sync.discovery") { "Not a move, base path already renamed" }

          return false
        end

        return true
      end

      if !move_check.call
        post_process_local_new.call(path)
        finalize.call(path, recurse_query_server)

        return
      end

      move_perms = check_move_permissions(base.remote_perm, original_path, item.is_directory)

      if !move_perms.source_ok || !move_perms.destination_ok
        Log.info("sync.discovery") { "Move without permission to rename base file,  source: #{move_perms.source_ok} , target: #{move_perms.destination_ok} , targetNew: #{move_perms.destination_new_ok}" }
        post_process_local_new.call(path)
        finalize.call(path, recurse_query_server)

        if (move_perms.destination_new_ok)
          return
        end

        was_deleted_on_client = @discovery_data.find_and_cancel_deleted_job(original_path)

        if was_deleted_on_client.first
          Log.info("sync.discovery") { "Undid remove instruction on source #{original_path}" }
          @discovery_data.statedb.delete_file_record(original_path, true)
          @discovery_data.statedb.schedule_path_for_remote_discovery(original_path)
          @discovery_data.another_sync_needed = true
        else
          Log.info("sync.discovery") { "Preventing future remove on source #{original_path}" }
          @discovery_data.forbidden_deletes.insert(original_path + "/")
        end

        return
      end

      was_deleted_on_client = @discovery_data.find_and_cancel_deleted_job(original_path)

      process_rename = lambda do |path|
        adjusted_original_path = @discovery_data.adjust_renamed_path(original_path, :down)
        @discovery_data.renamed_items_local.insert(original_path, path.target)
        item.rename_target = path.target
        path.server = adjusted_original_path
        item.set_local_name(path.server)
        path.original = original_path
        item.original_file = path.original
        item.modtime = base.modtime
        item.inode = base.inode
        item.set_instruction(CSYNC_INSTRUCTION_RENAME)
        item.direction = :up
        item.file_id = base.file_id
        item.remote_perm = base.remote_perm
        item.etag = base.etag
        item.type = base.type

        if (item.type == :item_type_virtual_file_download)
          item.type = ItemTypeVirtualFile
        elsif (item.type == :item_type_virtual_file_dehydration)
          item.type = ItemTypeFile
        end

        Log.info("sync.discovery") { "Rename detected (up)  #{item.local_name}  .  #{item.rename_target}" }

        return path
      end

      if was_deleted_on_client.first
        finalize.call(process_rename.call(path), (was_deleted_on_client.second == base.etag ? ParentNotChanged : NormalQuery))
      else
        @pending_async_jobs += 1
        server_original_path = @discovery_data.remote_folder + @discovery_data.adjust_renamed_path(original_path, :down)
        job = RequestEtagJob.new(@discovery_data.account, @discovery_data.base_url, server_original_path, this)

        connect(job, :finished_signal, this) do
          if (
            job.http_status_code == 404 ||
            (job.etag != base.etag && !item.is_directory) ||
            @discovery_data.is_renamed(original_path)
          )
            Log.info("sync.discovery") { "Can't rename because the etag has changed or the directory is gone #{original_path}" }
            post_process_local_new.call(path)
            process_file_finalize(item, path, item.is_directory, NormalQuery, recurse_query_server)
          else
            @discovery_data.find_and_cancel_deleted_job(original_path)

            process_file_finalize(
              item,
              process_rename.call(path),
              item.is_directory,
              NormalQuery,
              (job.etag == base.etag ? ParentNotChanged : NormalQuery)
            )
          end

          @pending_async_jobs -= 1
          QTimer.single_shot(0, @discovery_data, :schedule_more_jobs)
        end

        job.start
      end
    end

    def process_file_conflict(item, path, local_entry, server_entry, db_entry)
      item.previous_size = local_entry.size
      item.previous_modtime = local_entry.modtime

      if server_entry.is_directory && local_entry.is_directory
        item.set_instruction(CSYNC_INSTRUCTION_UPDATE_METADATA)

        return
      end

      if (db_entry.is_virtual_file || local_entry.is_virtual_file)
        item.type = ItemTypeVirtualFileDownload
      end

      if server_entry.checksum_header.is_empty
        size_differs = server_entry.size != local_entry.size
        mod_time_differs = server_entry.modtime != local_entry.modtime
        is_conflict = size_differs || mod_time_differs

        if is_conflict
          Log.debug("sync.discovery") { "#{server_entry.name} : detected conflict: size difference:  #{size_differs} mtime difference:  #{mod_time_differs}" }
        else
          Log.debug("sync.discovery") { "#{server_entry.name} : no conflict detected" }
        end

        if is_conflict
          item.set_instruction(CSYNC_INSTRUCTION_CONFLICT)
        else
          item.set_instruction(CSYNC_INSTRUCTION_UPDATE_METADATA)
        end

        if is_conflict
          item.direction = :none
        else
          item.direction = :down
        end

        return
      end

      up = @discovery_data.statedb.get_upload_info(path.original)

      if up.valid && up.content_checksum == server_entry.checksum_header
        item.set_instruction((
          if up.modtime == local_entry.modtime && up.size == local_entry.size
            CSYNC_INSTRUCTION_UPDATE_METADATA
          else
            CSYNC_INSTRUCTION_SYNC
          end
        ))

        item.direction = :up

        if item.instruction == CSYNC_INSTRUCTION_UPDATE_METADATA
          unless item.local_name == path.original
            raise
          end

          unless item.size == server_entry.size
            raise
          end

          unless item.modtime == server_entry.modtime
            raise
          end

          unless !server_entry.etag.is_empty
            raise
          end

          item.etag = server_entry.etag
          item.file_id = server_entry.file_id
          item.remote_perm = server_entry.remote_perm
          item.checksum_header = server_entry.checksum_header
        end

        return
      end

      item.set_instruction(CSYNC_INSTRUCTION_CONFLICT)
      item.direction = :none
    end

    def process_file_finalize(item, path, recurse, recurse_query_local, recurse_query_server)
      if (
        path.original != path.target &&
        item.instruction & (CSYNC_INSTRUCTION_UPDATE_METADATA | CSYNC_INSTRUCTION_NONE)
      )
        unless @dir_item && @dir_item.instruction == CSYNC_INSTRUCTION_RENAME
          raise
        end

        item.set_instruction(CSYNC_INSTRUCTION_RENAME)
        item.rename_target = path.target
        item.direction = @dir_item.direction
      end

      Log.info("sync.discovery") { "Discovered #{item.local_name} #{item.instruction} #{item.direction} #{item.type}" }

      if (item.is_directory && item.instruction == CSYNC_INSTRUCTION_SYNC)
        item.set_instruction(CSYNC_INSTRUCTION_UPDATE_METADATA)
      end

      removed = item.instruction == CSYNC_INSTRUCTION_REMOVE

      if check_permissions(item)
        if (item.is_restoration && item.is_directory)
          recurse = true
        else
          recurse = false
        end
      end

      if recurse
        job = ProcessDirectoryJob.new(path, item, recurse_query_local, recurse_query_server, this)

        if removed
          job.set_parent(@discovery_data)
          @discovery_data.queued_deleted_directories[path.original] = job
        else
          connect(job, ProcessDirectoryJob.finished, this, &ProcessDirectoryJob.sub_job_finished)
          @queued_jobs.push_back(job)
        end
      else
        if (
          removed ||
          item.type == :item_type_virtual_file &&
          item.instruction == CSYNC_INSTRUCTION_NEW
        )
          @discovery_data.deleted_item[path.original] = item
        end

        @discovery_data.item_discovered(item)
      end
    end

    def process_blacklisted(path, local_entry, db_entry)
      if !local_entry.is_valid
        return
      end

      item = SyncFileItem.from_sync_journal_file_record(db_entry)
      item.set_local_name(path.target)
      item.original_file = path.original
      item.inode = local_entry.inode
      item.is_selective_sync = true

      if (
        db_entry.is_valid &&
        (
          (db_entry.modtime == local_entry.modtime && db_entry.size == local_entry.size) ||
          (local_entry.is_directory && db_entry.is_directory)
        )
      )
        item.set_instruction(CSYNC_INSTRUCTION_REMOVE)
        item.direction = :down
      else
        item.set_instruction(CSYNC_INSTRUCTION_IGNORE)
        item.status = :file_ignored
        item.error_string = "Selective sync: Ignored because its path is deselected"
        @child_ignored = true
      end

      Log.info("sync.discovery") { "Discovered (blacklisted)  #{item.local_name} #{item.instruction} #{item.direction} #{item.is_directory}" }

      if item.is_directory && item.instruction != CSYNC_INSTRUCTION_IGNORE
        job = ProcessDirectoryJob.new(path, item, NormalQuery, InBlackList, this)
        connect(job, :finished, this, :sub_job_finished)
        @queued_jobs.push_back(job)
      else
        @discovery_data.item_discovered(item)
      end
    end

    def check_permissions(item)
      if item.direction != :up
        return true
      end

      case item.instruction
      when CSYNC_INSTRUCTION_TYPE_CHANGE, CSYNC_INSTRUCTION_NEW
        perms = (
          if !@root_permissions.is_null
            @root_permissions
          else
            if @dir_item
              @dir_item.remote_perm
            else
              @root_permissions
            end
          end
        )

        if perms.is_null
          return true
        elsif (
          item.is_directory &&
          !perms.has_permission(:can_add_sub_directories)
        )
          Log.warn("sync.discovery") { "checkForPermission: ERROR #{item.local_name} #{perms}" }
          item.set_instruction(CSYNC_INSTRUCTION_ERROR)
          item.error_string = "Not allowed because you don't have permission to add subfolders to that folder"

          return false
        elsif (!item.is_directory && !perms.has_permission(:can_add_file))
          Log.warn("sync.discovery") { "checkForPermission: ERROR #{item.local_name} #{perms}" }
          item.set_instruction(CSYNC_INSTRUCTION_ERROR)
          item.error_string = "Not allowed because you don't have permission to add files in that folder"

          return false
        end
      when CSYNC_INSTRUCTION_SYNC
        perms = item.remote_perm

        if perms.is_null
          return true
        end

        if !perms.has_permission(:can_write)
          item.set_instruction(CSYNC_INSTRUCTION_CONFLICT)
          item.error_string = "Not allowed to upload this file because it is read-only on the server, restoring"
          item.direction = :down
          item.is_restoration = true
          Log.warn("sync.discovery") { "checkForPermission: RESTORING #{item.local_name} #{item.error_string}" }
          q_swap(item.size, item.previous_size)
          q_swap(item.modtime, item.previous_modtime)

          return false
        end
      when CSYNC_INSTRUCTION_REMOVE
        file_slash = item.local_name + "/"
        forbidden_it = @discovery_data.forbidden_deletes.upper_bound(file_slash)

        if forbidden_it != @discovery_data.forbidden_deletes.cbegin
          forbidden_it -= 1
        end

        if (
          forbidden_it != @discovery_data.forbidden_deletes.cend &&
          file_slash.starts_with(*forbidden_it)
        )
          item.set_instruction(CSYNC_INSTRUCTION_NEW)
          item.direction = :down
          item.is_restoration = true
          item.error_string = "Moved to invalid target, restoring"
          Log.warn("sync.discovery") { "checkForPermission: RESTORING #{item.local_name} #{item.error_string}" }

          return true
        end

        perms = item.remote_perm

        if perms.is_null
          return true
        end

        if !perms.has_permission(:can_delete)
          item.set_instruction(CSYNC_INSTRUCTION_NEW)
          item.direction = :down
          item.is_restoration = true
          item.error_string = "Not allowed to remove, restoring"
          Log.warn("sync.discovery") { "checkForPermission: RESTORING #{item.local_name} #{item.error_string}" }

          return true
        end
      end

      return true
    end

    def check_move_permissions(src_perm, src_path, is_directory)
      dest_perms = (!@root_permissions.is_null ? @root_permissions : (@dir_item ? @dir_item.remote_perm : @root_permissions))
      file_perms = src_perm
      is_rename = src_path.starts_with(@current_folder.original) && src_path.last_index_of("/") == @current_folder.original.size
      destination_ok = true
      destination_new_ok = true

      if (dest_perms.is_null)
        nil
      elsif (
        is_directory &&
        !dest_perms.has_permission(:can_add_sub_directories)
      )
        destination_new_ok = false
      elsif (!is_directory && !dest_perms.has_permission(:can_add_file))
        destination_new_ok = false
      end

      if !is_rename && !destination_new_ok
        destination_ok = false
      end

      source_ok = true

      if (
        !file_perms.is_null &&
        (
          (
            is_rename &&
            !file_perms.has_permission(:can_rename)
          ) ||
          (
            !is_rename &&
            !file_perms.has_permission(:can_move)
          )
        )
      )
        source_ok = false
      end

      return MovePermissionResult.new(source_ok, destination_ok, destination_new_ok)
    end

    def sub_job_finished
      job = qobject_cast < ProcessDirectoryJob > (sender)

      unless job
        raise
      end

      @child_ignored |= job.child_ignored
      @child_modified |= job.child_modified

      if (job.dir_item)
        @discovery_data.item_discovered(job.dir_item)
      end

      count = @running_jobs.remove_all(job)

      unless count == 1
        raise
      end

      job.delete_later
      QTimer.single_shot(0, @discovery_data, :schedule_more_jobs)
    end

    def process_sub_jobs(nb_jobs)
      if @queued_jobs.empty && @running_jobs.empty && @pending_async_jobs == 0
        @pending_async_jobs = -1

        if @dir_item
          if @child_modified && @dir_item.instruction == CSYNC_INSTRUCTION_REMOVE
            @dir_item.set_instruction(CSYNC_INSTRUCTION_NEW)

            if @dir_item.direction == :up
              @dir_item.direction = :down
            else
              @dir_item.direction = :up
            end
          end

          if (
            @child_modified &&
            @dir_item.instruction == CSYNC_INSTRUCTION_TYPE_CHANGE &&
            !@dir_item.is_directory
          )
            @dir_item.set_instruction(CSYNC_INSTRUCTION_CONFLICT)

            if @dir_item.direction == :up
              @dir_item.type = :item_type_directory
              @dir_item.direction = :down
            end
          end

          if @child_ignored && @dir_item.instruction == CSYNC_INSTRUCTION_REMOVE
            @dir_item.set_instruction(CSYNC_INSTRUCTION_NONE)
          end
        end

        finished
      end

      started = 0

      @running_jobs.each do |rj|
        started += rj.process_sub_jobs(nb_jobs - started)

        if (started >= nb_jobs)
          return started
        end
      end

      while started < nb_jobs && !@queued_jobs.empty
        f = @queued_jobs.front
        @queued_jobs.pop_front
        @running_jobs.push_back(f)
        f.start
        started += 1
      end

      return started
    end

    def db_error
      @discovery_data.fatal_error("Error while reading the database")
    end

    def start_async_server_query
      server_job = DiscoverySingleDirectoryJob.new(
        @discovery_data.account,
        @discovery_data.base_url,
        @discovery_data.remote_folder + @current_folder.server,
        this
      )

      if !@dir_item
        server_job.set_is_root_path
      end

      connect(server_job, :etag, this, :etag)
      @discovery_data.currently_active_jobs += 1
      @pending_async_jobs += 1

      connect(server_job, :finished) do |results|
        @discovery_data.currently_active_jobs -= 1
        @pending_async_jobs -= 1

        if results
          @server_normal_query_entries = *results
          @server_query_done = true

          if @local_query_done
            this.process
          else
            code = results.error.code
            Log.warn("sync.discovery") { "Server error in directory #{@current_folder.server} #{code}" }

            if (server_job.is_root_path)
              if (code == 404)
                @discovery_data.fatal_error("This Space is currently unavailable")

                return
              end
            else
              if (code >= 403)
                @dir_item.set_instruction(CSYNC_INSTRUCTION_IGNORE)
                @dir_item.error_string = results.error.message
                this.finished

                return
              end

              @discovery_data.fatal_error(
                tr("Server replied with an error while reading directory »%1«: %2") % {
                  dir: @current_folder.server.is_empty ? "/" : @current_folder.server,
                  msg: results.error.message
                }
              )
            end
          end
        end
      end

      connect(server_job, :first_directory_permissions) do |perms|
        @root_permissions = perms
      end

      server_job.start

      return server_job
    end

    def start_async_local_query
      local_path = @discovery_data.local_dir + @current_folder.local

      local_job = DiscoverySingleLocalDirectoryJob.new(
        @discovery_data.account,
        local_path,
        @discovery_data.sync_options.vfs.data
      )

      @discovery_data.currently_active_jobs += 1
      @pending_async_jobs += 1
      connect(local_job, :item_discovered, @discovery_data, :item_discovered)

      connect(local_job, :child_ignored) do |b|
        @child_ignored = b
      end

      connect(local_job, :finished_fatal_error) do |msg|
        @discovery_data.currently_active_jobs -= 1
        @pending_async_jobs -= 1

        if @server_job
          @server_job.abort
          @discovery_data.fatal_error(msg)
        end
      end

      connect(local_job, :finished_non_fatal_error) do |msg|
        @discovery_data.currently_active_jobs -= 1
        @pending_async_jobs -= 1

        if @dir_item
          @dir_item.set_instruction(CSYNC_INSTRUCTION_IGNORE)
          @dir_item.error_string = msg
          this.finished
        else
          @discovery_data.fatal_error(msg)
        end
      end

      connect(local_job, :finished) do |results|
        @discovery_data.currently_active_jobs -= 1
        @pending_async_jobs -= 1
        @local_normal_query_entries = results
        @local_query_done = true

        if (@server_query_done)
          this.process
        end
      end

      pool = QThreadPool.global_instance
      pool.start(local_job)
    end

    def compute_pin_state(parent_state)
      @pin_state = parent_state

      if @query_local != :parent_dont_exist
        state = @discovery_data.sync_options.vfs.pin_state(@current_folder.local)

        if state
          @pin_state = *state
        end
      end
    end
  end
end
