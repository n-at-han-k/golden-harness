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

require_relative "vfs_off"

require_relative "filesystem"
require_relative "syncfileitem"

include OCC

class VfsOff
  def initialize(parent)
    super(parent)
  end

  def mode
    return :off
  end

  def stop
  end

  def unregister_folder
  end

  def socket_api_pin_state_actions_shown
    return false
  end

  def create_placeholder(_)
    return nil
  end

  def needs_metadata_update(_)
    return false
  end

  def is_dehydrated_placeholder(_)
    return false
  end

  def set_pin_state(_, _)
    return true
  end

  def pin_state(_)
    return :always_local
  end

  def availability(_)
    return :always_local
  end

  def stat_type_virtual_file(file_info)
    return file_info
  end

  def start_impl(_)
    started
  end

  def update_metadata(item, file_path, _replaces_file)
    if !item.is_directory
      is_read_only = (
        !item.remote_perm.is_null &&
        !item.remote_perm.has_permission(:can_write)
      )

      FileSystem.set_file_read_only_weak(file_path, is_read_only)
    end

    return :ok
  end

  def file_status_changed(_, _)
  end
end
