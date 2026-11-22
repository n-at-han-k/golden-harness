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

require_relative "gui/scheduling/etagwatcher"

require_relative "accountstate"
require_relative "gui/folderman"
require_relative "libsync/configfile"
require_relative "libsync/graphapi/spacesmanager"
require_relative "libsync/syncengine"

include std::chrono_literals
include OCC

class ETagWatcher
  def initialize(folder_man, parent)
    super(parent)
    @folder_man = folder_man

    connect(folder_man, FolderMan.folder_list_changed, this) do
      intersection = nil

      @folder_man.folders.each do |f|
        if f.is_ready
          it = @last_etag_job.find(f)

          if it != @last_etag_job.cend
            intersection[f] = it.second
          else
            intersection.emplace(f, "")

            connect(f.sync_engine, SyncEngine.root_etag, this) do |etag, time|
              @last_etag_job[f] = etag
              f.account_state.tag_last_successfull_e_tag_request(time)
            end
          end
        end
      end

      @last_etag_job = intersection
    end
  end
end
