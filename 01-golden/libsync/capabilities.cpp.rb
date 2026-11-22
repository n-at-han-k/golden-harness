#!/usr/bin/env ruby
#
# Copyright (C) by Roeland Jago Douma <roeland@famdouma.nl>
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

require_relative "capabilities"

require "qdebug"
require "qvariantmap"

include std::chrono
include Qt::Literals::StringLiterals

module OCC
  class Capabilities
    def initialize(url, capabilities)
      @capabilities = capabilities
      @file_sharing_capabilities = @capabilities.value("files_sharing").to_map
      @file_sharing_public_capabilities = @file_sharing_capabilities.value("public", nil).to_map
      @tus_support = @capabilities.value("files").to_map.value("tus_support").to_map
      @spaces = @capabilities.value("spaces").to_map
      @status = @capabilities.value("core").to_map.value("status").to_map
      @check_for_updates = @capabilities.value("core").to_map.value("check_for_updates", true).to_bool

      @app_providers = AppProviders.find_version(
        url,
        @capabilities.value("files").to_map.value("app_providers").to_list,
        QVersionNumber.new([1, 1, 0])
      )

      @files_sharing = @file_sharing_capabilities
      @migration = @capabilities.value("migration").to_map
    end

    def raw
      return @capabilities
    end

    def ==(other)
      return raw == other.raw
    end

    def share_api
      return @file_sharing_capabilities.value("api_enabled", true).to_bool
    end

    def share_public_link
      return (
        share_api &&
        @file_sharing_public_capabilities.value("enabled", true).to_bool
      )
    end

    def share_public_link_allow_upload
      return @file_sharing_public_capabilities.value("upload").to_bool
    end

    def share_public_link_supports_upload_only
      return @file_sharing_public_capabilities.value("supports_upload_only").to_bool
    end

    def get_enforce_password_capability(file_sharing_public_capabilities, name)
      value = file_sharing_public_capabilities["password"].to_map["enforced_for"].to_map[name]

      if !value.is_valid
        return file_sharing_public_capabilities["password"].to_map["enforced"].to_bool
      end

      return value.to_bool
    end

    def share_public_link_enforce_password_for_read_only
      return get_enforce_password_capability(@file_sharing_public_capabilities, "read_only")
    end

    def share_public_link_enforce_password_for_read_write
      return get_enforce_password_capability(@file_sharing_public_capabilities, "read_write")
    end

    def share_public_link_enforce_password_for_upload_only
      return get_enforce_password_capability(@file_sharing_public_capabilities, "upload_only")
    end

    def share_public_link_default_expire
      return @file_sharing_public_capabilities.value("expire_date").to_map.value("enabled").to_bool
    end

    def share_public_link_default_expire_date_days
      return @file_sharing_public_capabilities.value("expire_date").to_map.value("days").to_int
    end

    def share_public_link_enforce_expire_date
      return @file_sharing_public_capabilities.value("expire_date").to_map.value("enforced").to_bool
    end

    def share_public_link_multiple
      return @file_sharing_public_capabilities.value("multiple").to_bool
    end

    def share_resharing
      return @file_sharing_capabilities.value("resharing").to_bool
    end

    def default_permissions
      return @file_sharing_capabilities.value("default_permissions", 1).to_int
    end

    def remote_poll_interval
      return duration_cast < seconds > (milliseconds(@capabilities.value("core").to_map.value("pollinterval").to_int))
    end

    def notifications_available
      return (
        @capabilities.contains("notifications") &&
        @capabilities.value("notifications").to_map.contains("ocs-endpoints")
      )
    end

    def is_valid
      return !@capabilities.is_empty
    end

    def supported_checksum_types
      list = []
      supported_types = @capabilities.value("checksums").to_map.value("supportedTypes").to_list

      supported_types.each do |t|
        list.push_back(CheckSums.from_byte_array(t.to_byte_array))
      end

      return list
    end

    def preferred_upload_checksum_type
      return CheckSums.from_byte_array(@capabilities.value("checksums").to_map.value("preferredUploadType", "SHA1").to_byte_array)
    end

    def upload_checksum_type
      preferred = preferred_upload_checksum_type

      if preferred != :parse_error
        return preferred
      end

      supported = supported_checksum_types

      if !supported.is_empty
        return supported.first
      end

      return :parse_error
    end

    def status
      return @status
    end

    def check_for_updates
      return @check_for_updates
    end

    def tus_support
      return @tus_support
    end

    def spaces_support
      return @spaces
    end

    def private_link_property_available
      return @capabilities.value("files").to_map.value("privateLinks").to_bool
    end

    def private_link_details_param_available
      return @capabilities.value("files").to_map.value("privateLinksDetailsParam").to_bool
    end

    def http_error_codes_that_reset_failing_chunked_uploads
      list = []
      error_codes = @capabilities.value("dav").to_map.value("httpErrorCodesThatResetFailingChunkedUploads").to_list

      error_codes.each do |t|
        list.push_back(t.to_int)
      end

      return list
    end

    def invalid_filename_regex
      return @capabilities["dav"].to_map["invalidFilenameRegex"].to_string
    end

    def upload_conflict_files
      return @capabilities["uploadConflictFiles"].to_bool
    end

    def versioning_enabled
      return @capabilities.value("files").to_map.value("versioning").to_bool
    end

    def blacklisted_files
      return @capabilities.value("files").to_map.value("blacklisted_files").to_string_list
    end
  end

  module Status
    def initialize(status)
      legacy_version = QVersionNumber.from_string(status.value("version").to_string)
      legacy_version_string = status.value("versionstring").to_string
      edition = status.value("edition").to_string
      productname = status.value("productname").to_string
      product = status.value("product").to_string
      productversion = status.value("productversion").to_string
    end

    def version
      if productversion.is_empty
        return legacy_version
      else
        return QVersionNumber.from_string(productversion)
      end
    end

    def version_string
      if productversion.is_empty
        return legacy_version_string
      else
        return productversion
      end
    end
  end

  module TusSupport
    def initialize(tus_support)
      if tus_support.is_empty
        return
      end

      version = QVersionNumber.from_string(tus_support.value("version").to_string)
      resumable = QVersionNumber.from_string(tus_support.value("resumable").to_string)
      extensions = tus_support.value("extension").to_string.split(",", :skip_empty_parts)

      max_chunk_size = tus_support.value("max_chunk_size").value < quint64 >
        http_method_override = tus_support.value("http_method_override").to_string
    end

    def is_valid
      return !version.is_null
    end
  end

  module SpaceSupport
    def initialize(spaces_support)
      if spaces_support.is_empty
        return
      end

      enabled = spaces_support.value("enabled").to_bool
      version = QVersionNumber.from_string(spaces_support.value("version").to_string)
    end

    def is_valid
      return !version.is_null
    end
  end

  module AppProviders
    def initialize(base_url, app_providers)
      @enabled = app_providers.value("enabled").to_bool
      @version = QVersionNumber.from_string(app_providers.value("version").to_string)
      @apps_url = base_url.resolved(app_providers.value("apps_url").to_url)
      @open_url = base_url.resolved(app_providers.value("open_url").to_url)
      @new_url = base_url.resolved(app_providers.value("new_url").to_url)
      @open_web_url = base_url.resolved(app_providers.value("open_web_url").to_url)
    end
  end

  class Capabilities
    def app_providers
      return @app_providers
    end
  end

  module AppProviders
    def find_version(base_url, list, v)
      it = std::find_if(list.cbegin, list.cend, lambda do |it|
        return QVersionNumber.from_string(it.to_map.value("version").to_string) == v
      end)

      if it != list.cend
        return Capabilities::AppProviders.new(base_url, it.to_map)
      else
        return Capabilities::AppProviders.new
      end
    end
  end

  class Capabilities
    def files_sharing
      return @files_sharing
    end
  end

  module FilesSharing
    def initialize(files_sharing)
      @sharing_roles = files_sharing.value("sharing_roles", false).to_bool
    end
  end

  module Migration
    def initialize(data)
      spaces = data.value("space_migration").to_map
      space_migration.enabled = spaces.value("enabled").to_bool
      space_migration.endpoint = spaces.value("endpoint").to_string
    end
  end

  class Capabilities
    def migration
      return @migration
    end
  end
end
