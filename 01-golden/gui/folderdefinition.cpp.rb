#!/usr/bin/env ruby
#
# Copyright (C) by Hannah von Reth <h.vonreth@opencloud.eu>
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

require_relative "folderdefinition"

require "qdir"
require "qsettings"

include OCC

class FolderDefinition
  def initialize(account_uuid, dav_url, space_id, display_name)
    @web_dav_url = dav_url
    @space_id = space_id
    @display_name = display_name
    @account_uuid = account_uuid

    unless !@account_uuid.is_null
      raise
    end
  end

  def dav_url_c
    return "davUrl"
  end

  def space_id_c
    return "spaceId"
  end

  def display_name_c
    return "displayString"
  end

  def deployed_c
    return "deployed"
  end

  def priority_c
    return "priority"
  end

  def set_priority(new_priority)
    @priority = new_priority
  end

  def account_uuid
    return @account_uuid
  end

  def priority
    return @priority
  end

  def save(settings, folder)
    settings.set_value("accountUUID", folder.account_uuid)
    settings.set_value("localPath", folder.local_path)
    settings.set_value("journalPath", folder.journal_path)
    settings.set_value(space_id_c, folder.space_id)
    settings.set_value(dav_url_c, folder.web_dav_url)
    settings.set_value(display_name_c, folder.display_name)
    settings.set_value("paused", folder.paused)
    settings.set_value("ignoreHiddenFiles", folder.ignore_hidden_files)
    settings.set_value(deployed_c, folder.is_deployed)
    settings.set_value(priority_c, folder.priority)
    settings.set_value("virtualFilesMode", Utility.enum_to_string(folder.virtual_files_mode))
  end

  def load(settings)
    folder = [settings.value("accountUUID").to_uuid, settings.value(dav_url_c).to_url, settings.value(space_id_c).to_string, settings.value(display_name_c).to_string]
    folder.set_local_path(settings.value("localPath").to_string)
    folder.journal_path = settings.value("journalPath").to_string
    folder.paused = settings.value("paused").to_bool
    folder.ignore_hidden_files = settings.value("ignoreHiddenFiles", QVariant.new(true)).to_bool
    folder.deployed = settings.value(deployed_c, false).to_bool
    folder.priority = settings.value(priority_c, 0).to_u_int
    folder.virtual_files_mode = :off
    vfs_mode_string = settings.value("virtualFilesMode").to_string

    if Utility.is_windows
      vfs = :windows_cf_api
    else
      vfs = :open_v_f_s
    end

    result = VfsPluginManager.instance.prepare(folder.local_path, folder.account_uuid, vfs)

    if result
      vfs_mode_string = Utility.enum_to_string(vfs)
    else
      Log.warn("gui.folder.definition") { "Failed to upgrade #{folder.local_path} to #{vfs} #{result.error}" }
    end

    if !vfs_mode_string.is_empty
      mode = Vfs.mode_from_string(vfs_mode_string)

      if mode
        folder.virtual_files_mode = mode
      else
        Log.warn("gui.folder.definition") { "Unknown virtualFilesMode: #{vfs_mode_string} assuming 'off'" }
      end
    end

    return folder
  end

  def set_local_path(path)
    @local_path = QDir.from_native_separators(path)

    if !@local_path.ends_with("/")
      @local_path.append("/")
    end
  end

  def absolute_journal_path
    return QDir.new(local_path).file_path(journal_path)
  end

  def display_name
    return @display_name
  end

  def set_display_name(s)
    @display_name = s
  end

  def is_deployed
    return @deployed
  end

  def web_dav_url
    unless @web_dav_url.is_valid
      raise
    end

    return @web_dav_url
  end

  def local_path
    return @local_path
  end

  def space_id
    unless @web_dav_url.is_valid || !@space_id.is_empty
      raise
    end

    return @space_id
  end
end
