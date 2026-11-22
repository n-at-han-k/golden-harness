#!/usr/bin/env ruby

require_relative "libsync/localinfo"

require_relative "libsync/filesystem"

require "sys/stat"

include OCC

class LocalInfo
  OCC::LocalInfoData = Struct.new(
    :_path,
    :_name,
    :_type,
    :_modtime,
    :_size,
    :_inode,
    :_is_hidden,
    keyword_init: true
  )
  def initialize
    @d = (lambda do
      null_data = LocalInfoData.new

      return null_data
    end).call
  end

  def initialize_with_dirent(dirent)
    @d = LocalInfoData.new(dirent)
  end

  def initialize_with_path(path)
    super(std::filesystem::directory_entry.new(path))
  end

  def is_hidden
    return d.is_hidden
  end

  def name
    return d.name
  end

  def path
    return d.path
  end

  def modtime
    return d.modtime
  end

  def size
    return d.size
  end

  def inode
    return d.inode
  end

  def type
    return d.type
  end

  def set_type(type)
    d.type = type
  end

  def is_directory
    return d.type == :item_type_directory
  end

  def is_virtual_file
    return (
      d.type == :item_type_virtual_file ||
      d.type == :item_type_virtual_file_download
    )
  end

  def is_sym_link
    return d.type == :item_type_sym_link
  end

  def is_valid
    return !d.name.is_null
  end
end
