#!/usr/bin/env ruby
#
# SPDX-FileCopyrightText: 2021 Nextcloud GmbH and Nextcloud contributors
# SPDX-FileCopyrightText: 2025 OpenCloud GmbH and OpenCloud contributors
# SPDX-License-Identifier: GPL-2.0-or-later
#

require_relative "vfs_openvfs"

require_relative "account"
require_relative "common/chronoelapsedtimer"
require_relative "common/syncjournaldb"
require_relative "filesystem"

require_relative "libsync/xattr"
require_relative "syncfileitem"
require_relative "vfs/hydrationjob"

require "openvfs/openvfs"

require "qcoreapplication"
require "qdir"
require "qfile"
require "qloggingcategory"
require "qstandardpaths"
require "qstring"
require "quuid"

include std::chrono_literals
include Qt::StringLiterals

module OCC
  class OpenVFS
    def initialize(parent)
      super(parent)
    end

    def open_vfs_exe_path
      open_vfs = OCC::FileSystem.path(std::filesystem::path(OPENVFS_EXE))
      binary = OCC::FileSystem.path(q_app.application_dir_path) / open_vfs.get.filename

      if binary.exists
        return binary
      end

      on_path = QStandardPaths.find_executable(QString.from_std_string(open_vfs.get.filename.string))

      if !on_path.is_empty
        return OCC::FileSystem.path(std::filesystem::path(on_path.to_std_string))
      end

      return open_vfs
    end

    def xattr_owner_string(account_uuid)
      return "#{QCoreApplication.application_name}:#{account_uuid.to_string(:without_braces)}"
    end

    def open_vfs_config_file_path
      system_path = OCC::FileSystem.path(QStandardPaths.locate(:config_location, "openvfs/config.json"))

      if !system_path.get.empty
        return system_path
      end

      if OCC::Utility.running_in_app_image
        appimage_path = OCC::FileSystem.path(q_app.application_dir_path) / "../etc/xdg/openvfs/config.json"

        if appimage_path.exists
          return appimage_path
        end
      end

      return nil
    end

    def mode
      return :open_v_f_s
    end

    def start_impl(params)
      Log.debug("sync.vfs.openvfs") { "Start OpenVFS VFS" }
      owner = xattr_owner_string(params.account.uuid).to_std_string
      info = ::OpenVFS::Registration::register_filesystem(params.root, owner)

      if !info
        if info.owner != owner
          error("Unable to claim the sync root for files on demand, the folder is already claimed by #{info.owner}")

          return
        end

        error("Unable to retrieve registration info. Error: #{info.error}")

        return
      end

      Log.debug("sync.vfs.openvfs") { "Mounting #{open_vfs_exe_path.to_string} #{params.root.to_string}" }
      @open_vfs_process = QProcess.new(this)
      @open_vfs_process.set_process_channel_mode(:forwarded_channels)
      log_prefix = lambda { return "[#{QString.number(@open_vfs_process.process_id)} #{path}] " }
      connect(@open_vfs_process, QProcess.finished, this) { Log.fatal("sync.vfs.openvfs") { "#{log_prefix.call} finished #{@open_vfs_process.exit_code}" } }

      connect(@open_vfs_process, QProcess.started, this) do
        Log.info("sync.vfs.openvfs") { "#{log_prefix.call} started" }
        QTimer.single_shot(1, this, Vfs.started)
      end

      connect(@open_vfs_process, QProcess.error_occurred, this) { Log.warn("sync.vfs.openvfs") { "#{log_prefix.call} #{@open_vfs_process.error_string}" } }
      pparams = ["-f", "-i", open_vfs_config_file_path.to_string, "-o", xattr_owner_string(params.account.uuid), "-s", params.socket_path, params.root.to_string]

      if q_environment_variable_int_value("OPENCLOUD_OPENVFS_LOG_FUSE") == 1
        pparams.prepend("-d")
      end

      Log.debug("sync.vfs.openvfs") { "Starting openvfs #{open_vfs_exe_path.to_string} #{pparams}" }
      @open_vfs_process.start(open_vfs_exe_path.to_string, pparams, :read_only)
    end

    def stop
      if @open_vfs_process
        disconnect(@open_vfs_process, QProcess.finished, nil, nil)
        @open_vfs_process.terminate
        @open_vfs_process.wait_for_finished
        @open_vfs_process.delete_later
      end
    end

    def unregister_folder
      ::OpenVFS::Registration::unregister_filesystem([params.root, xattr_owner_string(params.account.uuid).to_std_string])
    end

    def socket_api_pin_state_actions_shown
      return true
    end
  end

  class OpenVfsPluginFactory
    def check_availability
      if !FileSystem.path("/dev/fuse").exists
        Log.warn("sync.vfs.openvfs") { "Fuse is not installed or available on the system" }

        return false
      end

      if QStandardPaths.find_executable("fusermount3").is_empty
        Log.warn("sync.vfs.openvfs") { "fusermount3 is not installed on the system" }

        return false
      end

      return true
    end

    def prepare(path, account_uuid)
      if !@cache_timer.is_started || @cache_timer.duration > 30
        @fuse_mount_cache.clear
        file = QFile.new("/proc/self/mountinfo")

        if file.open(:read_only)
          lines = file.read_all.split("\n")
          file.close

          lines.each do |line|
            fields = line.split(" ")

            if fields.size >= 9 && fields[8] == "fuse.openvfs"
              @fuse_mount_cache << QString.from_utf8(parse_mangled_path(fields[4]))
            end
          end
        else
          Log.warn("sync.vfs.openvfs") { "Failed to read /proc/self/mountinfo #{file.error_string}" }

          return "Failed to read /proc/self/mountinfo"
        end
      end

      if std::ranges::find_if(@fuse_mount_cache, lambda { |p|
        return FileSystem.is_child_path_of2(path, p).test_flag(:is_equal)
      }) != @fuse_mount_cache.cend
        process = QProcess.new
        process.set_process_channel_mode(:merged_channels)
        process.start("fusermount", ["-zu", path])
        process.wait_for_finished

        if process.exit_code != 0
          output = process.read_all
          Log.warn("sync.vfs.openvfs") { "Failed to unmount the OpenVFS mount #{path} #{output}" }

          return "Failed to unmount the OpenVFS mount #{path} Error:#{output}"
        else
          Log.debug("sync.vfs.openvfs") { "Unmounted OpenVFS mount #{path}" }
        end
      end

      fs_path = FileSystem.to_filesystem_path(path)

      if !FileSystem::Xattr.supportsxattr(fs_path)
        Log.debug("sync.vfs.openvfs") { "#{path} does not support xattributes" }

        return "The filesystem for #{path} does not support xattributes."
      end

      info = ::OpenVFS::Registration::from_attributes(fs_path)

      if (
        info &&
        info.owner != xattr_owner_string(account_uuid).to_std_string
      )
        return "The sync path is already claimed by #{info.owner}"
      end

      if !open_vfs_exe_path.exists
        Log.debug("sync.vfs.openvfs") { "OpenVFS executable not found at #{open_vfs_exe_path.to_string}" }

        return "OpenVFS executable not found, please install it"
      end

      vfs_config = open_vfs_config_file_path

      if !vfs_config.get.empty
        Log.debug("sync.vfs.openvfs") { "Using config file #{vfs_config.to_string}" }
      else
        return "Failed to find the OpenVFS config file, please check your installation."
      end

      return nil
    end
  end

  class OpenVFS
    def update_metadata(sync_item, file_path, replaces_file)
      if sync_item.type == :item_type_virtual_file_dehydration
        result = create_placeholder(sync_item)

        if !result
          Log.error("sync.vfs.openvfs") { "Failed to create placeholder for #{file_path} #{result.error}" }

          return result.error
        end

        return :ok
      else
        attributes = lambda do
          if !replaces_file.is_empty
            attr = place_holder_attributes(replaces_file)

            if attr
              return attr
            end
          end

          attr = place_holder_attributes(file_path)

          if attr
            return attr
          end

          unless QFileInfo.exists(file_path)
            raise
          end

          attr = ::OpenVFS::PlaceHolderAttributes::create(
            FileSystem.to_filesystem_path(file_path),
            sync_item.etag.to_std_string,
            sync_item.file_id.to_std_string,
            sync_item.size
          )

          attr.state = :hydrated

          return attr
        end

        attributes.call

        unless attributes
          raise
        end

        attributes.size = sync_item.size
        attributes.file_id = sync_item.file_id.to_std_string
        attributes.etag = sync_item.etag.to_std_string
        Log.debug("sync.vfs.openvfs") { "#{attributes.absolute_path.native} #{sync_item.type}" }

        case sync_item.type
        when :item_type_virtual_file_download
          attributes.state = :hydrating
        when :item_type_virtual_file, :item_type_virtual_file_dehydration
          Log.debug("sync.vfs.openvfs") { "updateMetadata for virtual file  #{sync_item.type}" }
          attributes.state = :de_hydrated
        when :item_type_file
          attributes.size = 0
          Log.debug("sync.vfs.openvfs") { "updateMetadata for #{sync_item.type}" }
          attributes.state = :hydrated
        when :item_type_directory
          Log.debug("sync.vfs.openvfs") { "updateMetadata for #{sync_item.type}" }
          attributes.state = :hydrated
        when :item_type_sym_link, :item_type_unsupported
          raise
        end

        result = set_placeholder_attributes(attributes, sync_item.modtime)

        if !result
          Log.error("sync.vfs.openvfs") { "Failed to update placeholder for #{file_path} #{result.error}" }

          return result.error
        end

        return :ok
      end
    end

    def slot_hydrate_job_finished
      hydration = qobject_cast < HydrationJob > (sender)
      target_path = FileSystem.to_filesystem_path(hydration.target_file_name)

      unless !target_path.empty
        raise
      end

      Log.info("sync.vfs.openvfs") { "Hydration Job finished for #{target_path.native}" }

      if std::filesystem::exists(target_path)
        item = OCC::SyncFileItem.from_sync_journal_file_record(hydration.record)
        item.type = :item_type_file
        inode = FileSystem.get_inode(target_path)

        if inode
          item.inode = inode.value
        else
          Log.warn("sync.vfs.openvfs") { "Failed to get inode for #{target_path.native}" }
        end

        result = this.params.journal.set_file_record(SyncJournalFileRecord.from_sync_file_item(item))

        if !result
          Log.warn("sync.vfs.openvfs") { "Error when setting the file record to the database #{result.error}" }
        else
          Log.info("sync.vfs.openvfs") { "Hydration succeeded #{target_path.native}" }
        end
      else
        Log.warn("sync.vfs.openvfs") { "Hydration succeeded but the file appears to be moved #{target_path.native}" }
      end

      hydration.delete_later
      @hydration_jobs.remove(hydration.file_id)
    end

    def create_placeholder(item)
      path = params.root / item.local_name

      if path.exists
        unless item.type == :item_type_virtual_file_dehydration
          raise
        end

        if (
          item.type == :item_type_virtual_file_dehydration &&
          FileSystem.file_changed(path, FileSystem::FileChangedInfo.from_sync_file_item(item))
        )
          return "Cannot dehydrate a placeholder because the file changed"
        end
      end

      file = QFile.new(path.get)

      if !file.open(:read_write | :truncate)
        return file.error_string
      end

      file.write("")
      file.close

      attributes = ::OpenVFS::PlaceHolderAttributes::create(
        path,
        item.etag.to_std_string,
        item.file_id.to_std_string,
        item.size
      )

      return set_placeholder_attributes(attributes, item.modtime)
    end

    def hydrate_file(file_id, target_path)
      Log.info("sync.vfs.openvfs") { "Requesting hydration for #{file_id}" }

      if @hydration_jobs.contains(file_id)
        Log.warn("sync.vfs.openvfs") { "Ignoring hydration request for running hydration for fileId #{file_id}" }

        return nil
      end

      attr = place_holder_attributes(target_path)

      if attr
        attr.state = :hydrating
        res = set_placeholder_attributes(attr)

        if !res
          Log.warn("sync.vfs.openvfs") { "Failed to set attributes for #{target_path} #{res.error}" }

          return nil
        end
      else
        Log.warn("sync.vfs.openvfs") { "Failed to get attributes for #{target_path}" }

        return nil
      end

      hydration = HydrationJob.new(this, file_id, QFile.new(target_path), nil)
      hydration.set_target_file(target_path)
      @hydration_jobs.insert(file_id, hydration)
      connect(hydration, HydrationJob.finished, this, OpenVFS.slot_hydrate_job_finished)

      connect(hydration, HydrationJob.error, this) do |error|
        Log.warn("sync.vfs.openvfs") { "Hydration failed #{error}" }
        @hydration_jobs.remove(hydration.file_id)
        hydration.delete_later
      end

      return hydration
    end

    def needs_metadata_update(item)
      path = params.root / item.local_name

      return (
        QFileInfo.exists(path.to_string) &&
        !place_holder_attributes(path)
      )
    end

    def is_dehydrated_placeholder(file_path)
      if QFileInfo.exists(file_path)
        return place_holder_attributes(file_path).state == :de_hydrated
      end

      return false
    end

    def stat_type_virtual_file(file_info)
      if file_info.type == :item_type_file
        attribs = place_holder_attributes(file_info.path)

        if attribs.state == :de_hydrated
          file_info.set_type(:item_type_virtual_file)

          if attribs.pin_state == convert_pin_state(:always_local)
            file_info.set_type(:item_type_virtual_file_download)
          end
        elsif attribs.pin_state == convert_pin_state(:online_only)
          file_info.set_type(:item_type_virtual_file_dehydration)
        end
      end

      Log.debug("sync.vfs.openvfs") { "#{file_info.path.native} #{Utility.enum_to_string(file_info.type)}" }

      return file_info
    end

    def set_pin_state(folder_path, state)
      local_path = params.root / folder_path
      Log.debug("sync.vfs.openvfs") { "#{local_path.to_string} #{state}" }
      attribs = place_holder_attributes(local_path)

      if !attribs
        return false
      end

      attribs.pin_state = convert_pin_state(state)

      if !set_placeholder_attributes(attribs)
        return false
      end

      return true
    end

    def pin_state(folder_path)
      loop do
        attributes = place_holder_attributes(params.root / relative_path)

        if !attributes
          Log.debug("sync.vfs.openvfs") { "Couldn't find pin state for placeholder file #{folder_path}" }

          return nil
        end

        if (
          attributes.pin_state != :inherited ||
          !relative_path.has_relative_path
        )
          return convert_pin_state(attributes.pin_state)
        end
      end
    end

    def availability(folder_path)
      attribs = place_holder_attributes(params.root / folder_path)

      if attribs
        case convert_pin_state(attribs.pin_state)
        when :always_local
          return :always_local
        when :online_only
          return :online_only
        when :inherited
          case attribs.state
          when :hydrated
            return :all_hydrated
          when :de_hydrated
            return :all_dehydrated
          when :hydrating
            return :mixed
          end

          return :mixed
        when :unspecified, :excluded
          return :mixed
        end
      else
        return :no_such_item
      end

      return :mixed
    end

    def file_status_changed(system_file_name, file_status)
      if file_status.tag == :status_excluded
        rel = FileSystem.path(system_file_name).lexically_relative(params.root)
        set_pin_state(rel.to_string, :excluded)

        return
      end

      if file_status.tag == :status_up_to_date
        attribs = place_holder_attributes(system_file_name)

        if (
          attribs &&
          attribs.pin_state == convert_pin_state(:excluded)
        )
          rel = FileSystem.path(system_file_name).lexically_relative(params.root)
          set_pin_state(rel.to_string, :inherited)
        end

        return
      end

      Log.debug("sync.vfs.openvfs") { "#{system_file_name} #{file_status}" }
    end
  end
end
