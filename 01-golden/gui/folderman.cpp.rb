#!/usr/bin/env ruby
#
# Copyright (C) by Klaas Freitag <freitag@owncloud.com>
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

require_relative "folderman"

require_relative "socketapi/socketapi"

require "qcoreapplication"

require_relative "account"
require_relative "accountmanager"
require_relative "accountstate"
require_relative "common/asserts"
require_relative "configfile"
require_relative "gui/folder"
require_relative "gui/folderdefinition"
require_relative "gui/networkinformation"
require_relative "libsync/syncengine"
require_relative "scheduling/syncscheduler"
require_relative "syncresult"

require "qtcore"

include Qt::Literals::StringLiterals
include std::chrono
include std::chrono_literals

module OCC
  class TrayOverallStatusResult
    _INSTANCE = nil

    def folders_c
      return QAnyStringView.new("Folders")
    end

    def number_of_sync_journals(path)
      return QDir.new(path).entry_list([".sync_*.db", "._sync_*.db"], :hidden | :files).size
    end

    def add_result(f)
      @overall_status.num_new_conflict_items += f.sync_result.num_new_conflict_items
      @overall_status.num_error_items += f.sync_result.num_error_items
      @overall_status.num_blacklist_errors += f.sync_result.num_blacklist_errors
      time = f.last_sync_time

      if time > last_sync_done
        last_sync_done = time
      end

      if (
        f.is_sync_paused ||
        NetworkInformation.instance.is_behind_captive_portal ||
        NetworkInformation.instance.is_metered
      )
        status = :paused
      else
        status = f.sync_result.status
      end

      if status == :undefined
        status = :problem
      end

      if status > @overall_status.status
        @overall_status.set_status(status)
      end
    end

    def overall_status
      return @overall_status
    end
  end

  class FolderMan
    def initialize
      @scheduler = SyncScheduler.new(this)
      @socket_api = SocketApi.new
      @socket_api.start_shell_integration
    end

    def instance
      if !_INSTANCE
        @instance = FolderMan.new
      end

      return _INSTANCE
    end

    def finalize
      unload_and_delete_all_folders
      q_delete_all(@folders)
      @instance = nil
    end

    def folders
      return @folders
    end

    def unload_folder(f)
      unless f
        raise
      end

      @folders.remove_all(f)

      if !f.has_setup_error
        disconnect(f, nil, this, nil)
        disconnect(f, nil, f.sync_engine.sync_file_status_tracker, nil)
        disconnect(f.sync_engine, nil, f, nil)
      end
    end

    def unload_and_delete_all_folders
      if !@folders.is_empty
        save_folders
        folders = @folders

        folders.each do |folder|
          unload_folder(folder)
          folder.delete_later
        end
      end
    end

    def load_folders
      Log.info("gui.folder.manager") { "Setup folders from settings file" }
      settings = ConfigFile.make_q_settings
      size = settings.begin_read_array(folders_c)

      (0...size).each do |i|
        settings.set_array_index(i)
        folder_definition = FolderDefinition.load(settings)

        if SyncJournalDb.db_is_too_new_for_client(folder_definition.absolute_journal_path)
          next
        end

        vfs = VfsPluginManager.instance.create_vfs_from_plugin(folder_definition.virtual_files_mode)

        if !vfs
          q_fatal("Could not load plugin")
        end

        account = AccountManager.instance.account(folder_definition.account_uuid)

        if account.is_null
          q_fatal("Could not load account")
        end

        add_folder_internal(folder_definition, account, vfs)
      end

      settings.end_array
      folder_list_changed

      return @folders.size
    end

    def save_folders
      settings = ConfigFile.make_q_settings
      settings.remove(folders_c)
      settings.begin_write_array(folders_c, @folders.size)
      i = 0

      @folders.each do |folder|
        settings.set_array_index(i)
        i += 1
        definition_to_save = folder.definition
        definition_to_save.set_web_dav_url(folder.web_dav_url)
        definition_to_save.set_display_name(folder.display_name)
        FolderDefinition.save(settings, definition_to_save)
      end

      settings.end_array
    end

    def ensure_journal_gone(journal_db_file)
      if (
        QFile.exists(journal_db_file) &&
        !QFile.remove(journal_db_file)
      )
        Log.warn("gui.folder.manager") { "Could not remove old db file at #{journal_db_file}" }

        return false
      end

      return true
    end

    def slot_folder_can_sync_changed
      f = qobject_cast < Folder > (sender)

      unless f
        raise
      end

      if f.can_sync
        nil
      end
    end

    def schedule_all_folders
      @folders.each do |f|
        if f && f.can_sync
          scheduler.enqueue_folder(f)
        end
      end
    end

    def slot_sync_once_file_unlocks(_path, _mode)
    end

    def slot_is_connected_changed
      account_state = AccountStatePtr.new(qobject_cast < AccountState > (sender))

      if !account_state
        return
      end

      account_name = account_state.account.display_name_with_host

      if account_state.is_connected
        Log.info("gui.folder.manager") { "Account #{account_name} connected, scheduling its folders" }

        @folders.each do |f|
          if f.account_state == account_state && f.can_sync
            scheduler.enqueue_folder(f)
          end
        end
      elsif (
        account_state.state == :disconnected ||
        account_state.state == :signed_out
      )
        Log.info("gui.folder.manager") { "Account #{account_name} disconnected or paused, terminating or descheduling sync folders" }

        if (
          scheduler.current_sync &&
          scheduler.current_sync.account_state == account_state
        )
          scheduler.terminate_current_sync("Account disconnected or paused")
        end
      end
    end

    def set_sync_enabled(enabled)
      if enabled
        scheduler.start
      else
        scheduler.stop
      end

      Log.info("gui.folder.manager") { "#{__method__} #{enabled}" }
      folder_sync_state_change(nil)
    end

    def slot_remove_folders_for_account(account_state)
      folders_to_remove = []
      folders_to_remove.reserve(16)

      @folders.each do |folder|
        if folder.account_state == account_state
          folders_to_remove.append(folder)
        end
      end

      folders_to_remove.each do |f|
        remove_folder(f)
      end
    end

    def slot_server_version_changed(account)
      if account.server_support_level == :unsupported
        Log.warn("gui.folder.manager") {
          "The server version is unsupported: #{account.capabilities.status.version_string}" \
            "pausing all folders on the account"
        }

        @folders.each do |f|
          if f.account_state.account.data == account
            f.set_sync_paused(true)
          end
        end
      end
    end

    def is_any_sync_running
      if @scheduler.has_current_running_sync_running
        return true
      end

      @folders.each do |f|
        if f.is_sync_running
          return true
        end
      end

      return false
    end

    def add_folder(account_state, folder_definition)
      definition = folder_definition
      definition.journal_path = SyncJournalDb.make_db_name(folder_definition.local_path)

      if !ensure_journal_gone(definition.absolute_journal_path)
        return nil
      end

      vfs = VfsPluginManager.instance.create_vfs_from_plugin(folder_definition.virtual_files_mode)

      if !vfs
        Log.warn("gui.folder.manager") { "Could not load plugin for mode #{folder_definition.virtual_files_mode}" }

        return nil
      end

      folder = add_folder_internal(definition, account_state, vfs)

      if folder
        folder_sync_state_change(folder)
        folder_list_changed
      end

      save_folders

      return folder
    end

    def add_folder_internal(folder_definition, account_state, vfs)
      folder = Folder.new(folder_definition, account_state, vfs, this)
      Log.info("gui.folder.manager") { "Adding folder to Folder Map  #{folder} #{folder.path}" }
      @folders.push_back(folder)

      if !folder.has_setup_error
        connect(folder, Folder.sync_state_change, this) { folder_sync_state_change(folder) }
        connect(folder, Folder.can_sync_changed, this, FolderMan.slot_folder_can_sync_changed)

        connect(
          folder,
          Folder.watched_file_changed_externally,
          folder.sync_engine.sync_file_status_tracker,
          SyncFileStatusTracker.slot_path_touched
        )
      end

      return folder
    end

    def folder_for_path(path, relative_path)
      absolute_path = QDir.clean_path(path) + "/"

      @folders.each do |folder|
        folder_path = folder.clean_path + "/"

        if FileSystem.is_child_path_of2(absolute_path, folder_path).test_any_flag(:is_child)
          if relative_path
            relative_path = absolute_path.mid(folder_path.length)
            relative_path.chop(1)
          end

          return folder
        end
      end

      if relative_path
        relative_path.clear
      end

      return nil
    end

    def remove_folder(f)
      if !f
        return
      end

      Log.info("gui.folder.manager") { "Removing  #{f.path}" }

      if scheduler.current_sync == f
        scheduler.terminate_current_sync("Folder is about to be removed")
      end

      f.set_sync_paused(true)
      f.wipe_for_removal
      unload_folder(f)
      folder_removed(f)
      folder_list_changed
      f.delete_later
      save_folders
    end

    def get_backup_name(full_path_name)
      if full_path_name.ends_with("/")
        full_path_name.chop(1)
      end

      if full_path_name.is_empty
        return ""
      end

      new_name = full_path_name + " (backup)"
      fi = QFileInfo.new(new_name)
      cnt = 2

      loop do
        if fi.exists
          new_name = full_path_name + " (backup #{cnt})"
          cnt += 1
          fi.set_file(new_name)
        end

        unless fi.exists
          break
        end
      end

      return new_name
    end

    def set_dirty_network_limits
      @folders.each do |f|
        if f && f.is_sync_running
          f.set_dirty_network_limits
        end
      end
    end

    def tray_overall_status(folders)
      result = TrayOverallStatusResult.new

      folders.each do |folder|
        result.add_result(folder)
      end

      return result
    end

    def tray_tooltip_status_string(result, paused)
      folder_message = ""

      case result.status
      when :success, :problem
        if result.has_unresolved_conflicts
          folder_message = "Sync was successful, unresolved conflicts."
        else
          return Utility.enum_to_display_name(result.status)
        end
      else
        return Utility.enum_to_display_name(result.status)
      end

      if paused
        folder_message = "#{folder_message} (Sync is paused)"
      end

      return folder_message
    end

    def check_path_for_sync_root_marking_recursive(path, folder_type, account_uuid)
      existing_tags = Utility.get_directory_sync_root_markings(path)

      if !existing_tags.first.is_empty
        if existing_tags.first != QCoreApplication.organization_domain
          return FolderMan.tr("The folder »%1« is already in use by application %2!").arg(path, existing_tags.first)
        end

        case folder_type
        when :spaces_folder
          if existing_tags.second == account_uuid
            return nil
          end

          return FolderMan.tr("The folder »%1« is already in use by another account.").arg(path)
        when :spaces_sync_root
          return FolderMan.tr("The folder »%1« is already in use by another account.").arg(path)
        end
      end

      parent = QFileInfo.new(path).path

      if parent == path
        return nil
      end

      return check_path_for_sync_root_marking_recursive(parent, folder_type, account_uuid)
    end

    def check_path_validity_recursive(path, folder_type, account_uuid)
      if path.is_empty
        return FolderMan.tr("No valid folder selected!")
      end

      path_lenght_check = Folder.check_path_length(path)

      if !path_lenght_check
        return path_lenght_check.error
      end

      selected_path_info = QFileInfo.new(path)

      if !selected_path_info.exists
        parent_path = selected_path_info.path

        if parent_path != path
          return check_path_validity_recursive(parent_path, folder_type, account_uuid)
        end

        return FolderMan.tr("The selected path does not exist!")
      end

      if number_of_sync_journals(selected_path_info.file_path) != 0
        return FolderMan.tr("The folder »%1« is used in a folder sync connection!").arg(QDir.to_native_separators(selected_path_info.file_path))
      end

      if !selected_path_info.is_dir
        return FolderMan.tr("The selected path is not a folder!")
      end

      if !selected_path_info.is_writable
        return FolderMan.tr("You have no permission to write to the selected folder!")
      end

      return check_path_for_sync_root_marking_recursive(path, folder_type, account_uuid)
    end

    def check_path_validity_for_new_folder(path, folder_type, account_uuid)
      if path.is_empty
        return "Passingg an empty path is not supported"
      end

      user_dir = FileSystem.canonical_path(path) + "/"

      @folders.each do |f|
        folder_dir = FileSystem.canonical_path(f.path) + "/"
        is_child = FileSystem.is_child_path_of2(folder_dir, user_dir)

        if is_child.test_flag(:is_equal)
          return "There is already a sync from the server to this local folder. " \
                 "Please pick another local folder!"
        elsif is_child.test_flag(:is_child)
          return "The local folder »#{QDir.to_native_separators(path)}« already contains a folder used in a folder sync connection. " \
                 "Please pick another local folder!"
        end

        if FileSystem.is_child_path_of(user_dir, folder_dir)
          return "The local folder »#{QDir.to_native_separators(path)}« is already contained in a folder used in a folder sync connection. " \
                 "Please pick another local folder!"
        end
      end

      result = check_path_validity_recursive(path, folder_type, account_uuid)

      if !result.is_empty
        return "Please pick another local folder for »#{result}«."
      end

      return nil
    end

    def find_good_path_for_new_sync_folder(base_path, new_folder, folder_type, account_uuid)
      unless !account_uuid.is_null || folder_type == :spaces_sync_root
        raise
      end

      normalised_path = FileSystem.create_portable_file_name(base_path, new_folder, std::string_view(" (100)").size)
      relative_path = ""

      if (
        FolderMan.instance.folder_for_path(FileSystem.canonical_path(normalised_path), relative_path) &&
        !relative_path.is_empty
      )
        return FileSystem.canonical_path(normalised_path)
      end

      folder = normalised_path
      attempt = 2

      while attempt <= 100
        if (
          !QFileInfo.exists(folder) &&
          FolderMan.instance.check_path_validity_for_new_folder(folder, folder_type, account_uuid).is_empty
        )
          return FileSystem.canonical_path(folder)
        end

        folder = normalised_path + " (#{attempt})"
        attempt += 1
      end

      unless false
        raise
      end

      return FileSystem.canonical_path(normalised_path)
    end

    def ignore_hidden_files
      if @folders.empty
        return true
      end

      return @folders.first.ignore_hidden_files
    end

    def set_ignore_hidden_files(ignore)
      @folders.each do |folder|
        if folder.ignore_hidden_files == ignore
          next
        end

        folder.set_ignore_hidden_files(ignore)

        if !ignore && folder.can_sync
          @scheduler.enqueue_folder(folder)
        end
      end

      save_folders
    end

    def slot_reload_sync_options
      @folders.each do |f|
        if f
          f.reload_sync_options
        end
      end
    end

    def add_folder_from_wizard(account_state_ptr, folder_definition, use_vfs)
      if !FolderMan.prepare_folder(folder_definition.local_path)
        return nil
      end

      folder_definition.ignore_hidden_files = ignore_hidden_files

      if use_vfs
        folder_definition.virtual_files_mode = VfsPluginManager.instance.best_available_vfs_mode
      end

      new_folder = add_folder(account_state_ptr, folder_definition)

      if new_folder
        Log.debug("gui.folder.manager") { "Local sync folder #{folder_definition.local_path} successfully created!" }
      else
        Log.warn("gui.folder.manager") { "Failed to create local sync folder!" }
      end

      return new_folder
    end

    def add_folder_from_folder_wizard_result(account_state_ptr, description)
      definition = [account_state_ptr.account.uuid, description.dav_url, description.space_id, description.display_name]
      definition.set_local_path(description.local_path)
      f = add_folder_from_wizard(account_state_ptr, definition, description.use_virtual_files)

      if f
        f.journal_db.set_selective_sync_list(:selective_sync_black_list, description.selective_sync_black_list)
        f.set_priority(description.priority)
      end

      return f
    end

    def suggest_sync_folder(folder_type, account_uuid)
      return FolderMan.instance.find_good_path_for_new_sync_folder(
        QDir.home_path,
        QCoreApplication.application_name,
        folder_type,
        account_uuid
      )
    end

    def prepare_folder(folder)
      if !QFileInfo.exists(folder)
        if !QDir.new.mkpath(folder)
          return false
        end

        FileSystem.set_folder_minimum_permissions(folder)
        Folder.prepare_folder(folder, nil, nil, false)
      end

      return true
    end

    def create_instance
      unless !_INSTANCE
        raise
      end

      @instance = FolderMan.new

      return _INSTANCE
    end
  end
end
