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

require_relative "preparedsqlquerymanager"

require "sqlite3"

include OCC

class PreparedSqlQuery
  def initialize(query, ok)
    @query = query
    @ok = ok
  end

  def finalize
    @query.reset_and_clear_bindings
  end
end

class PreparedSqlQueryManager
  def get(key)
    query = @queries[key]

    unless query.stmt
      raise
    end

    unless !sqlite3_stmt_busy(query.stmt)
      raise
    end

    return query
  end

  def get_with_db(key, sql, db)
    query = @queries[key]

    unless !sqlite3_stmt_busy(query.stmt)
      raise
    end

    unless !query.sqldb || db == query.sqldb
      raise
    end

    if !query.stmt
      query.sqldb = db
      query.db = db.sqlite_db

      return [query, query.prepare(sql) == 0]
    end

    return query
  end
end
