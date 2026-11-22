#!/usr/bin/env ruby
#
# Copyright (C) by Erik Verbruggen <erik@verbruggen.consulting>
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

require_relative "platform"

require "qnetworkproxyfactory"

require_relative "platform_unix"

require_relative "configfile"

require "qdir"
require "libcrashreporter-handler/handler"

require "qfontdatabase"

module OCC
  class Platform
    def initialize(t)
      @type = t
    end

    def set_application(application)
      if ConfigFile.new.crash_reporter
        crash_handler = CrashReporter::Handler.new(
          QDir.temp_path,
          true,
          QStringLiteral("%1/", CRASHREPORTER_EXECUTABLE).arg(application.application_dir_path)
        )

        connect(application, QCoreApplication.about_to_quit, this) { delete crash_handler }
      end
    end

    def start_services
    end

    def type
      return @type
    end

    def create(t)
      unless QCoreApplication.instance == nil
        raise
      end

      QNetworkProxyFactory.set_use_system_configuration(true)

      return UnixPlatform.new(t)
    end
  end
end
