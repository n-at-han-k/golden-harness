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

require_relative "jsonjob"

require_relative "account"
require_relative "common/utility"

require "qjsondocument"
require "qloggingcategory"
require "qnetworkreply"

include OCC

class JsonJob
  def finalize
  end

  def finished
    if reply.error != :no_error
      Log.warn("sync.networkjob.jsonapi") { "Network error:  #{this} #{error_string}" }
    else
      parse(reply.read_all)
    end

    SimpleNetworkJob.finished
  end

  def parse(data)
    doc = QJsonDocument.from_json(data, @parse_error)

    if @parse_error.error != :no_error || doc.is_null
      Log.warn("sync.networkjob.jsonapi") { "invalid JSON! #{data} #{@parse_error.error_string}" }
    else
      @data = doc.object
    end
  end

  def parse_error
    return @parse_error
  end

  def data
    return @data
  end
end

class JsonApiJob
  def initialize(account, path, verb, arguments, req, parent)
    super(account, account.url, path, verb, arguments, req, parent)
    @request.set_raw_header("OCS-APIREQUEST", "true")
    q = query
    q.add_query_item("format", "json")
    set_query(q)
  end

  def initialize_with_parent(account, path, arguments, req, parent)
    super(account, path, "GET", arguments, req, parent)
  end

  def ocs_status
    return @ocs_status
  end

  def parse(raw_data)
    rex = QRegularExpression.new("<statuscode>(\\d+)</statuscode>")
    match = rex.match(QString.from_utf8(raw_data))

    if match.has_match
      @ocs_status = match.captured(1).to_int
    else
      JsonJob.parse(raw_data)

      if parse_error.error == :no_error
        if data.contains("ocs")
          meta = data.value("ocs").to_object.value("meta").to_object
          @ocs_status = meta.value("statuscode").to_int
          @ocs_message = meta.value("message").to_string
        else
          @ocs_message = parse_error.error_string
        end
      end
    end
  end

  def ocs_message
    return @ocs_message
  end

  def ocs_success
    return ocs_status == 100 || ocs_status == 200
  end
end
