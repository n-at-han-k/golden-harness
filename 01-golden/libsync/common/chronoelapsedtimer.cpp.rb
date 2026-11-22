#!/usr/bin/env ruby
#
# Copyright (C) by Hannah von Reth <hannah.vonreth@owncloud.com>
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

require_relative "chronoelapsedtimer"

require "qtglobal"

include OCC::Utility
include std::chrono

class ChronoElapsedTimer
  def initialize(start)
    @start = steady_clock::now
    @started = start
  end

  def is_started
    return @started
  end

  def reset
    @start = steady_clock::now
    @end = nil
    @started = true
  end

  def stop
    unless @end == steady_clock::time_point.new
      raise
    end

    unless @started
      raise
    end

    @end = steady_clock::now
  end

  def duration
    if !@started
      return nanoseconds::max
    end

    if @end != steady_clock::time_point.new
      return @end - @start
    end

    return steady_clock::now - @start
  end

  def <<(debug)
    save = QDebugStateSaver.new(debug)
    debug.nospace
    duration = duration()
    h = duration_cast < hours > (duration)
    min = duration_cast < minutes > (duration -= h)
    s = duration_cast < seconds > (duration -= min)
    ms = duration_cast < milliseconds > (duration -= s)

    return debug << "duration(" << h.count << "h, " << min.count << "min, " << s.count << "s, " << ms.count << "ms)"
  end
end
