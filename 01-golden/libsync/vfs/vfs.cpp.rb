#!/usr/bin/env ruby
#
# Copyright (C) by Dominik Schmidt <dschmidt@owncloud.com>
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
#

require_relative "vfs"

require_relative "plugins/vfs/off/vfs_off"
require_relative "plugins/vfs/openvfs/vfs_openvfs"

require_relative "libsync/common/filesystembase"
require_relative "libsync/common/plugin"
require_relative "libsync/common/syncjournaldb"
require_relative "libsync/common/version"
require_relative "libsync/filesystem"
require_relative "libsync/syncengine"

require "qcoreapplication"
require "qloggingcategory"
require "qpluginloader"

include OCC
include Qt::Literals::StringLiterals

class Vfs
  def initialize(parent)
    super(parent)
  end

  def mode_from_string(str)
    if str == "off"
      return :off
    elsif str == "cfapi"
      return :windows_cf_api
    elsif str == "openvfs"
      return :open_v_f_s
    end

    return nil
  end
end

module Utility
  def enum_to_string(mode)
    case mode
    when :windows_cf_api
      return "cfapi"
    when :off
      return "off"
    when :open_v_f_s
      return "openvfs"
    end

    raise
  end
end

class Vfs
  def start(params)
    @setup_params = VfsSetupParams.new(params)
    start_impl(this.params)
  end

  def wipe_dehydrated_virtual_files
    if mode == :off
      return
    end

    @setup_params.journal.get_files_below_path("") do |rec|
      if (
        rec.type != :item_type_virtual_file &&
        rec.type != :item_type_virtual_file_download
      )
        return
      end

      relative_path = rec.path
      Log.debug("sync.vfs") { "Removing db record for dehydrated file #{relative_path}" }
      @setup_params.journal.delete_file_record(relative_path)
      absolute_path = @setup_params.root / relative_path

      if QFile.exists(absolute_path)
        if is_dehydrated_placeholder(absolute_path)
          Log.debug("sync.vfs") { "Removing local dehydrated placeholder #{relative_path}" }
          FileSystem.remove(absolute_path)
        end
      end
    end

    @setup_params.journal.force_remote_discovery_next_sync
  end
end

module HydrationJobVfs
  _INSTANCE = nil

  def hydrate_file(_, _)
    return nil
  end
end

class VfsPluginManager
  def is_vfs_plugin_available(mode)
    if mode == :off
      return true
    end

    if mode == :open_v_f_s
      return OpenVfsPluginFactory.new.check_availability
    end

    return create_plugin_factory_internal(mode) != nil
  end

  def best_available_vfs_mode
    if is_vfs_plugin_available(:windows_cf_api)
      return :windows_cf_api
    elsif is_vfs_plugin_available(:open_v_f_s)
      return :open_v_f_s
    elsif is_vfs_plugin_available(:off)
      return :off
    end

    raise
  end

  def create_vfs_plugin_factory(mode)
    name = Utility.enum_to_string(mode)

    if name.is_empty
      return nil
    end

    plugin_path = plugin_file_name("vfs", name)

    if !is_vfs_plugin_available(mode)
      Log.error("sync.plugins") { "Could not load plugin: not existent or bad metadata #{plugin_path}" }

      return [plugin_path, nil]
    end

    factory = create_plugin_factory_internal(mode)

    if !factory
      return [plugin_path, nil]
    end

    return [plugin_path, factory]
  end

  def create_plugin_factory_internal(mode)
    result = @plugin_cache.const_find(mode)

    if result != @plugin_cache.cend
      return result
    end

    return @plugin_cache[mode] = (lambda do
      name = Utility.enum_to_string(mode)

      if !!name.is_empty
        return nil
      end

      plugin_path = plugin_file_name("vfs", name)
      loader = QPluginLoader.new(plugin_path)
      basemeta = loader.meta_data

      if basemeta.is_empty || !basemeta.contains("IID")
        Log.debug("sync.plugins") { "Plugin doesn't exist: #{loader.file_name} LibraryPath: #{QCoreApplication.library_paths}" }

        return nil
      end

      if basemeta["IID"].to_string != "eu.opencloud.PluginFactory"
        Log.warn("sync.plugins") { "Plugin has wrong IID #{loader.file_name} #{basemeta["IID"]}" }

        return nil
      end

      metadata = basemeta["MetaData"].to_object

      if metadata["type"].to_string != "vfs"
        Log.warn("sync.plugins") { "Plugin has wrong type #{loader.file_name} #{metadata["type"]}" }

        return nil
      end

      if metadata["version"].to_string != OCC::Version.version.to_string
        Log.warn("sync.plugins") { "Plugin has wrong version #{loader.file_name} #{metadata["version"]}" }

        return nil
      end

      if !loader.load
        Log.warn("sync.plugins") { "Plugin failed to load: #{loader.error_string}" }

        return nil
      end

      plugin = loader.instance

      if !plugin
        Log.error("sync.plugins") { "Could not load plugin #{plugin_path} #{loader.error_string}" }

        return nil
      end

      factory = qobject_cast < PluginFactory > (plugin)

      if !factory
        Log.error("sync.plugins") { "Plugin #{loader.file_name} does not implement PluginFactory" }

        return nil
      end

      if !factory.check_availability
        Log.error("sync.plugins") { "Plugin #{loader.file_name} does not implement PluginFactory" }

        return nil
      end

      return factory
    end).call
  end

  def create_vfs_from_plugin(mode)
    if mode == :off
      return VfsOff.new(nil)
    end

    if mode == :open_v_f_s
      return OpenVFS.new(nil)
    end

    plugin_path = create_vfs_plugin_factory(mode)

    if factory
      vfs = qobject_cast < Vfs > (factory.create(nil))

      if !vfs
        Log.error("sync.plugins") { "Plugin #{plugin_path} does not create a Vfs instance" }

        return nil
      end

      Log.info("sync.plugins") { "Created VFS instance from plugin #{plugin_path}" }

      return vfs
    end

    return nil
  end

  def prepare(path, account_uuid, mode)
    canonical_path = FileSystem.canonical_path(path)

    if mode == :off
      return nil
    end

    if mode == :open_v_f_s
      return OpenVfsPluginFactory.new.prepare(canonical_path, account_uuid)
    end

    plugin_path = create_vfs_plugin_factory(mode)

    if factory
      return factory.prepare(canonical_path, account_uuid)
    end

    return QCoreApplication.translate("VfsPluginManager", "The Virtual filesystem %1 is not supported on this platform").arg(Utility.enum_to_string(mode))
  end

  def instance
    if !_INSTANCE
      @instance = VfsPluginManager.new
    end

    return _INSTANCE
  end
end

module VfsSetupParams
  def initialize(account, base_url, space_id, folder_display_name, sync_engine)
    @account = account
    @base_url = base_url
    @sync_engine = sync_engine
    @space_id = space_id
    @folder_display_name = folder_display_name
    @root = sync_engine.local_path

    unless filesystem_path.ends_with("/")
      raise
    end
  end

  def folder_display_name
    return @folder_display_name
  end

  def sync_engine
    return @sync_engine
  end

  def filesystem_path
    return @root.to_string
  end

  def root
    return @root
  end
end
