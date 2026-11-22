#!/usr/bin/env ruby

require_relative "libsync/globalconfig"

require "qcoreapplication"
require "qsettings"
require "qurl"

include OCC

class GlobalConfig
  def server_url
    url = get_value("Wizard/ServerUrl").to_url

    if url.is_empty
      return QUrl.new
    end

    return url
  end

  def get_value(param, default_value)
    system_settings = ["/etc/#{QCoreApplication.application_name}.conf", :native_format]

    return system_settings.value(param, default_value)
  end
end
