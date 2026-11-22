#!/usr/bin/env ruby

require_relative "libsync/discoveryremoteinfo"

require_relative "libsync/common/checksums"

require "qcoreapplication"

include OCC
include Qt::Literals::StringLiterals

class RemoteInfo
  OCC::RemoteInfoData = Struct.new(
    :_name,
    :_etag,
    :_file_id,
    :_checksum_header,
    :_remote_perm,
    :_modtime,
    :_size,
    :_is_directory,
    :_vault_integrity_id,
    :_error,
    keyword_init: true
  )
  def initialize
    @d = (lambda do
      null_data = RemoteInfoData.new

      return null_data
    end).call
  end

  def initialize_with_map(file_name, map)
    @d = RemoteInfoData.new(file_name, map)
  end

  def name
    return d.name
  end

  def is_directory
    return d.is_directory
  end

  def etag
    return d.etag
  end

  def file_id
    return d.file_id
  end

  def checksum_header
    return d.checksum_header
  end

  def remote_perm
    return d.remote_perm
  end

  def modtime
    return d.modtime
  end

  def size
    return d.size
  end

  def error
    return d.error
  end

  def is_vault_file
    return !d.vault_integrity_id.is_empty
  end

  def is_valid
    return !d.name.is_null
  end
end
