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

require_relative "platform_unix"

require "qcoreapplication"
require "qdir"
require "qloggingcategory"

require "signal"
require "sys/resource"

module OCC
  class UnixPlatform
    def initialize(t)
      super(t)
      signal(SIGPIPE, SIG_IGN)
      set_limits_for_core_dumps
    end

    def finalize
    end

    def set_limits_for_core_dumps
      if !q_environment_variable_is_empty("OPENCLOUD_CORE_DUMP")
        core_limit.rlim_cur = RLIM_INFINITY
        core_limit.rlim_max = RLIM_INFINITY

        if setrlimit(RLIMIT_CORE, core_limit) < 0
          fprintf(stderr, "Unable to set core dump limit\n")
        else
          Log.info("gui.platform") { "Core dumps enabled" }
        end
      end
    end
  end
end
