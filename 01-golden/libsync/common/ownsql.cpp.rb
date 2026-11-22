#!/usr/bin/env ruby
#
# Copyright (C) by Klaas Freitag <freitag@owncloud.com>
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

require "qdatetime"
require "qdir"
require "qfile"
require "qfileinfo"
require "qstring"

require_relative "common/asserts"
require_relative "common/filesystembase"
require_relative "common/utility"

require_relative "ownsql"

require "sqlite3"

require "thread"

include Qt::Literals::StringLiterals
include std::chrono_literals

module OCC
  class SqlDatabase
    SQLITE_REPEAT_COUNT = 20
    def initialize
      @db = nil
      @err_id = 0
    end

    def finalize
      close
    end

    def is_open
      return @db != nil
    end

    def open_helper(filename, sqlite_flags)
      if is_open
        return true
      end

      sqlite_flags |= SQLITE_OPEN_NOMUTEX
      vfs = nil
      @err_id = sqlite3_open_v2(FileSystem.long_win_path(filename).to_utf8.const_data, @db, sqlite_flags, vfs)

      if (
        @err_id != SQLITE_OK &&
        @err_id != SQLITE_DONE &&
        @err_id != SQLITE_ROW
      )
        @error = QString.from_utf8(sqlite3_errmsg(@db))
      end

      if @err_id != SQLITE_OK
        Log.warn("sync.database.sql") { "Error: #{@error} for #{filename}" }

        if @err_id == SQLITE_CANTOPEN
          Log.warn("sync.database.sql") { "CANTOPEN extended errcode:  #{sqlite3_extended_errcode(@db)}" }
          Log.warn("sync.database.sql") { "CANTOPEN system errno:  #{sqlite3_system_errno(@db)}" }
        end

        close

        return false
      end

      if !@db
        Log.warn("sync.database.sql") { "Error: no database for #{filename}" }

        return false
      end

      sqlite3_busy_timeout(@db, 5000)

      return true
    end

    def check_db
      quick_check = SqlQuery.new(this)

      if quick_check.prepare("PRAGMA quick_check;", true) != SQLITE_OK
        Log.warn("sync.database.sql") { "Error preparing quick_check on database" }
        @err_id = quick_check.error_id
        @error = quick_check.error

        return :cant_prepare
      end

      if !quick_check.exec
        Log.warn("sync.database.sql") { "Error running quick_check on database" }
        @err_id = quick_check.error_id
        @error = quick_check.error

        return :cant_exec
      end

      quick_check.next
      result = quick_check.string_value(0)

      if result != "ok"
        Log.warn("sync.database.sql") { "quick_check returned failure: #{result}" }

        return :not_ok
      end

      return :ok
    end

    def open_or_create_read_write(filename)
      if is_open
        return true
      end

      if !open_helper(filename, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        return false
      end

      check_result = check_db

      if check_result != :ok
        close

        if check_result == :cant_prepare
          free_space = Utility.free_disk_space(QFileInfo.new(filename).dir.absolute_path)

          if free_space != -1 && free_space < 1000000
            Log.warn("sync.database.sql") { "Can't prepare consistency check and disk space is low: #{free_space}" }
          elsif @err_id == SQLITE_CANTOPEN
            Log.warn("sync.database.sql") { "Can't open db to prepare consistency check, aborting" }
          elsif @err_id == SQLITE_LOCKED || @err_id == SQLITE_BUSY
            Log.warn("sync.database.sql") { "Can't open db to prepare consistency check, the db is locked aborting #{@err_id} #{@error}" }
          end

          return false
        end

        Log.error("sync.database.sql") { "Consistency check failed, removing broken db #{filename}" }
        file_to_remove = QFile.new(filename)

        if !file_to_remove.remove
          Log.error("sync.database.sql") { "Failed to remove broken db #{filename} : #{file_to_remove.error_string}" }

          return false
        end

        return open_helper(filename, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
      end

      return true
    end

    def open_read_only(filename)
      if is_open
        return true
      end

      if !open_helper(filename, SQLITE_OPEN_READONLY)
        return false
      end

      if check_db != :ok
        Log.warn("sync.database.sql") { "Consistency check failed in readonly mode, giving up #{filename}" }
        close

        return false
      end

      return true
    end

    def error
      err = @error

      return err
    end

    def close
      if @db
        queries = @queries

        queries.each do |q|
          q.finish
        end

        @err_id = sqlite3_close(@db)

        if (
          @err_id != SQLITE_OK &&
          @err_id != SQLITE_DONE &&
          @err_id != SQLITE_ROW
        )
          @error = QString.from_utf8(sqlite3_errmsg(@db))
        end

        if @err_id != SQLITE_OK
          Log.warn("sync.database.sql") { "Closing database failed #{@error}" }
        end

        @db = nil
      end
    end

    def transaction
      if !@db
        return false
      end

      @err_id = sqlite3_exec(@db, "BEGIN", nil, nil, nil)

      if (
        @err_id != SQLITE_OK &&
        @err_id != SQLITE_DONE &&
        @err_id != SQLITE_ROW
      )
        @error = QString.from_utf8(sqlite3_errmsg(@db))
      end

      return @err_id == SQLITE_OK
    end

    def commit
      if !@db
        return false
      end

      @err_id = sqlite3_exec(@db, "COMMIT", nil, nil, nil)

      if (
        @err_id != SQLITE_OK &&
        @err_id != SQLITE_DONE &&
        @err_id != SQLITE_ROW
      )
        @error = QString.from_utf8(sqlite3_errmsg(@db))
      end

      return @err_id == SQLITE_OK
    end

    def sqlite_db
      return @db
    end
  end

  class SqlQuery
    def initialize(db)
      @sqldb = db
      @db = db.sqlite_db
    end

    def finalize
      if @stmt
        finish
      end
    end

    def initialize_with_db(sql, db)
      @sqldb = db
      @db = db.sqlite_db
      prepare(sql)
    end

    def prepare(sql, allow_failure)
      @sql = sql.trimmed

      if @stmt
        finish
      end

      if !@sql.is_empty
        (0...SQLITE_REPEAT_COUNT).each do |n|
          Log.debug("sync.database.sql") { "SQL prepare #{@sql} Try: #{n}" }
          @err_id = sqlite3_prepare_v2(@db, @sql.const_data, -1, @stmt, nil)

          if @err_id != SQLITE_OK
            Log.warn("sync.database.sql") { "SQL prepare failed #{@sql} #{QString.from_utf8(sqlite3_errmsg(@db))}" }

            if (@err_id == SQLITE_BUSY) || (@err_id == SQLITE_LOCKED)
              next
            end
          end

          break
        end

        if @err_id != SQLITE_OK
          @error = QString.from_utf8(sqlite3_errmsg(@db))
          Log.warn("sync.database.sql") { "Sqlite prepare statement error: #{@err_id} #{@error} in #{@sql}" }

          unless allow_failure
            raise
          end
        else
          unless @stmt
            raise
          end

          @sqldb.queries.insert(this)

          if lc_sql.is_debug_enabled
            @bound_values.resize(sqlite3_bind_parameter_count(@stmt))
            i = 1

            while i <= @bound_values.size
              name = QRegularExpression.escape(QString.from_utf8(sqlite3_bind_parameter_name(@stmt, i)))
              @bound_values[i - 1].name = QRegularExpression.new("(#{name}\b)")
              i += 1
            end
          end
        end
      end

      return @err_id
    end

    def starts_with_insensitive(a, b)
      return (
        a.size >= b.size &&
        qstrnicmp(a.const_data, b.const_data, b.size) == 0
      )
    end

    def is_select
      return starts_with_insensitive(@sql, "SELECT")
    end

    def is_pragma
      return starts_with_insensitive(@sql, "PRAGMA")
    end

    def exec
      if !@stmt
        Log.warn("sync.database.sql") { "Can't exec query, statement unprepared." }

        return false
      end

      if !is_select && !is_pragma
        (0...SQLITE_REPEAT_COUNT).each do |n|
          if lc_sql.is_debug_enabled
            if !@bound_values.is_empty
              query = QString.from_utf8(@sql)

              @bound_values.each do |v|
                query.replace(v.name, v.value)
              end

              actual_query = sqlite3_expanded_sql(@stmt)
              Log.debug("sync.database.sql") { "SQL exec: Estimated query: #{query} Actual query: #{QString.from_utf8(actual_query)} Try: #{n}" }
              sqlite3_free(actual_query)
            else
              Log.debug("sync.database.sql") { "SQL exec: #{@sql} Try: #{n}" }
            end
          end

          @err_id = sqlite3_step(@stmt)

          if @err_id != SQLITE_DONE && @err_id != SQLITE_ROW
            Log.warn("sync.database.sql") { "SQL exec failed #{@sql} #{QString.from_utf8(sqlite3_errmsg(@db))}" }

            if @err_id == SQLITE_LOCKED || @err_id == SQLITE_BUSY
              next
            end
          end

          break
        end

        if @err_id != SQLITE_DONE && @err_id != SQLITE_ROW
          @error = QString.from_utf8(sqlite3_errmsg(@db))
          Log.warn("sync.database.sql") { "Sqlite exec statement error: #{@err_id} #{@error} in #{@sql}" }

          if @err_id == SQLITE_IOERR
            Log.warn("sync.database.sql") { "IOERR extended errcode:  #{sqlite3_extended_errcode(@db)}" }
            Log.warn("sync.database.sql") { "IOERR system errno:  #{sqlite3_system_errno(@db)}" }
          end
        else
          Log.debug("sync.database.sql") { "Last exec affected #{num_rows_affected} rows." }
        end

        return @err_id == SQLITE_DONE
      end

      return true
    end

    def next
      first_step = !sqlite3_stmt_busy(@stmt)

      (0...SQLITE_REPEAT_COUNT).each do |n|
        @err_id = sqlite3_step(@stmt)

        if !(first_step && (@err_id == SQLITE_LOCKED || @err_id == SQLITE_BUSY))
          break
        end
      end

      result = NextResult.new
      result.ok = @err_id == SQLITE_ROW || @err_id == SQLITE_DONE
      result.has_data = @err_id == SQLITE_ROW

      if !result.ok
        @error = QString.from_utf8(sqlite3_errmsg(@db))
        Log.warn("sync.database.sql") { "Sqlite step statement error: #{@err_id} #{@error} in #{@sql}" }
      end

      return result
    end

    def bind_value_internal(pos, value)
      res = -1

      if !@stmt
        unless false
          raise
        end

        return
      end

      case value.type_id
      when :int, :bool
        res = sqlite3_bind_int(@stmt, pos, value.to_int)
      when :double
        res = sqlite3_bind_double(@stmt, pos, value.to_double)
      when :u_int, :long, :u_long, :long_long, :u_long_long
        res = sqlite3_bind_int64(@stmt, pos, value.to_long_long)
      when :q_string
        if !value.is_null
          str = value.const_data
          res = sqlite3_bind_text16(@stmt, pos, str.utf16, str.size * 0, SQLITE_TRANSIENT)
        else
          res = sqlite3_bind_null(@stmt, pos)
        end
      when :q_byte_array
        ba = value.to_byte_array
        res = sqlite3_bind_text(@stmt, pos, ba.const_data, ba.size, SQLITE_TRANSIENT)
      else
        Log.warn("sync.database.sql") { "Unsupported raw type detected #{value.type_id} #{value.type_name} #{value.meta_type.size_of} #{value}" }
      end

      if res != SQLITE_OK
        Log.warn("sync.database.sql") { "ERROR binding SQL value: #{value} error: #{res}" }
      end

      unless res == SQLITE_OK
        raise
      end
    end

    def null_value(index)
      return sqlite3_column_type(@stmt, index) == SQLITE_NULL
    end

    def string_value(index)
      return QString.from_utf16(sqlite3_column_text16(@stmt, index))
    end

    def int_value(index)
      return sqlite3_column_int(@stmt, index)
    end

    def int64_value(index)
      return sqlite3_column_int64(@stmt, index)
    end

    def ba_value(index)
      return QByteArray.new(sqlite3_column_blob(@stmt, index), sqlite3_column_bytes(@stmt, index))
    end

    def error
      return @error
    end

    def error_id
      return @err_id
    end

    def last_query
      return @sql
    end

    def num_rows_affected
      return sqlite3_changes(@db)
    end

    def finish
      if !@stmt
        return
      end

      @err_id = sqlite3_finalize(@stmt)

      if (
        @err_id != SQLITE_OK &&
        @err_id != SQLITE_DONE &&
        @err_id != SQLITE_ROW
      )
        @error = QString.from_utf8(sqlite3_errmsg(@db))
      end

      @stmt = nil

      if @sqldb
        @sqldb.queries.remove(this)
      end
    end

    def reset_and_clear_bindings
      if @stmt
        @err_id = sqlite3_reset(@stmt)

        if (
          @err_id != SQLITE_OK &&
          @err_id != SQLITE_DONE &&
          @err_id != SQLITE_ROW
        )
          @error = QString.from_utf8(sqlite3_errmsg(@db))
        end

        @err_id = sqlite3_clear_bindings(@stmt)

        if (
          @err_id != SQLITE_OK &&
          @err_id != SQLITE_DONE &&
          @err_id != SQLITE_ROW
        )
          @error = QString.from_utf8(sqlite3_errmsg(@db))
        end
      end
    end
  end
end
