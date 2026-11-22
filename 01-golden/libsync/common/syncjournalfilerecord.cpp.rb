#!/usr/bin/env ruby
#
# Copyright (C) by Klaas Freitag <freitag@owncloud.com>
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

require_relative "libsync/common/syncjournalfilerecord"

require_relative "libsync/common/utility"
require_relative "libsync/filesystem"
require_relative "libsync/syncfileitem"

include Qt::Literals::StringLiterals
include OCC

class SyncJournalErrorBlacklistRecord
  OCC::SyncJournalFileRecordData = Struct.new(
    :_path,
    :_inode,
    :_modtime,
    :_type,
    :_etag,
    :_file_id,
    :_file_size,
    :_remote_perm,
    :_server_has_ignored_files,
    :_has_dirty_placeholder,
    :_checksum_header,
    :_error,
    keyword_init: true
  )
  def is_valid
    return (
      !@file.is_empty &&
      (!@last_try_etag.is_empty || @last_try_modtime != 0) &&
      @last_try_time > 0
    )
  end
end

class SyncJournalFileRecord
  def initialize
    @d = (lambda do
      null_data = QExplicitlySharedDataPointer.new(SyncJournalFileRecordData.new)

      return null_data
    end).call
  end

  def initialize_with_type(path, type)
    @d = SyncJournalFileRecordData.new
    d.path = path
    d.type = type
  end

  def validate_record
    unless d != SyncJournalFileRecord.new.d
      raise
    end

    unless !remote_perm.is_null
      raise
    end

    unless inode != 0
      raise
    end

    unless d.modtime.has_value
      raise
    end

    unless !file_id.is_empty
      raise
    end

    unless type != :item_type_unsupported
      raise
    end

    return true
  end

  def initialize_with_error(error)
    @d = SyncJournalFileRecordData.new
    d.error = error
  end

  def query
    return "SELECT path, inode, modtime, type, md5, fileid, remotePerm, filesize," \
           " ignoredChildrenRemote, contentchecksumtype.name || ':' || contentChecksum," \
           " hasDirtyPlaceholder" \
           " FROM metadata" \
           " LEFT JOIN checksumtype as contentchecksumtype ON metadata.contentChecksumTypeId == contentchecksumtype.id "
  end

  def from_sql_query(query)
    rec = SyncJournalFileRecord.new(QString.from_utf8(query.ba_value(0)), query.int_value(3))
    rec.d.inode = query.int64_value(1)
    rec.d.modtime = query.int64_value(2)
    rec.d.etag = QString.from_utf8(query.ba_value(4))
    rec.d.file_id = query.ba_value(5)
    rec.d.remote_perm = OCC::RemotePermissions.from_db_value(query.ba_value(6))
    rec.d.file_size = query.int64_value(7)
    rec.d.server_has_ignored_files = (query.int_value(8) > 0)
    rec.d.checksum_header = query.ba_value(9)
    rec.d.has_dirty_placeholder = query.int_value(10)
    Log.debug("sync.syncjournalfilerecord") { "Restored from db: #{rec}" }

    unless rec.validate_record
      raise
    end

    return rec
  end

  def from_sync_file_item(sync_file)
    rec = SyncJournalFileRecord.new(sync_file.destination, sync_file.type)
    rec.d.modtime = sync_file.modtime

    if rec.d.type == :item_type_virtual_file_download
      rec.d.type = :item_type_file
    end

    if rec.d.type == :item_type_virtual_file_dehydration
      rec.d.type = :item_type_virtual_file
    end

    rec.d.etag = sync_file.etag
    rec.d.file_id = sync_file.file_id
    rec.d.file_size = sync_file.size
    rec.d.inode = sync_file.inode
    rec.d.remote_perm = sync_file.remote_perm
    rec.d.server_has_ignored_files = sync_file.server_has_ignored_files
    rec.d.checksum_header = sync_file.checksum_header

    unless rec.validate_record
      raise
    end

    return rec
  end

  def is_valid
    return !has_error && !d.path.is_empty
  end

  def mod_date_time
    return Utility.q_date_time_from_time_t(modtime)
  end

  def is_directory
    return d.type == :item_type_directory
  end

  def is_file
    return (
      d.type == :item_type_file ||
      d.type == :item_type_virtual_file_dehydration
    )
  end

  def is_virtual_file
    return (
      d.type == :item_type_virtual_file ||
      d.type == :item_type_virtual_file_download
    )
  end

  def path
    return d.path
  end

  def name
    return path.mid(path.last_index_of("/") + 1)
  end

  def etag
    return d.etag
  end

  def file_id
    return d.file_id
  end

  def remote_perm
    return d.remote_perm
  end

  def checksum_header
    return d.checksum_header
  end

  def modtime
    return d.modtime.value_or(0)
  end

  def size
    return d.file_size
  end

  def inode
    return d.inode
  end

  def type
    return d.type
  end

  def has_dirty_placeholder
    return d.has_dirty_placeholder
  end

  def set_dirty_placeholder(b)
    d.detach
    d.has_dirty_placeholder = b
  end

  def server_has_ignored_files
    return d.server_has_ignored_files
  end

  def error
    return d.error
  end

  def has_error
    return !d.error.is_empty
  end
end

module OCC
  class SyncJournalFileRecord
    def <<(debug)
      saver = QDebugStateSaver.new(debug)
      debug.nospace << "SyncJournalFileRecord("

      if has_error
        debug << "Error: " << error
      else
        debug << "path: " << path << ", inode: " << inode << ", modtime: " << modtime << ", type: " << type << ", etag: " << etag << ", fileId: " << file_id << ", remotePerm: " << remote_perm.to_string << ", size: " << size << ", checksum: " << checksum_header << ", serverHasIgnoredFiles: " << server_has_ignored_files << ", hasDirtyPlaceholder: " << has_dirty_placeholder
      end

      return debug << ")"
    end
  end

  class SyncJournalFileRecord
    def ==(other)
      return (
        path == other.path &&
        inode == other.inode &&
        modtime == other.modtime &&
        type == other.type &&
        etag == other.etag &&
        file_id == other.file_id &&
        size == other.size &&
        remote_perm == other.remote_perm &&
        server_has_ignored_files == other.server_has_ignored_files &&
        checksum_header == other.checksum_header
      )
    end
  end
end
