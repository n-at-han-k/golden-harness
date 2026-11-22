#!/usr/bin/env ruby
#
# Copyright (C) by Olivier Goffart <ogoffart@woboq.com>
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

require_relative "syncoptions"
require_relative "common/utility"

require "qregularexpression"

include OCC

class SyncOptions
  def initialize(vfs)
    @vfs = vfs
  end

  def finalize
  end

  def file_regex
    return @file_regex
  end

  def set_file_pattern(pattern)
    set_path_pattern("(^|/|\\\\)" + pattern + "$")
  end

  def set_path_pattern(pattern)
    if Utility.fs_case_preserving
      @file_regex.set_pattern_options(:case_insensitive_option)
    else
      @file_regex.set_pattern_options(:no_pattern_option)
    end

    @file_regex.set_pattern(pattern)
  end
end
