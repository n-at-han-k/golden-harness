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

require_relative "common/syncjournaldb"

require_relative "common/asserts"
require_relative "common/c_jhash"
require_relative "common/checksums"
require_relative "common/filesystembase"
require_relative "common/preparedsqlquerymanager"
require_relative "common/version"

require "qdir"
require "qelapsedtimer"
require "qfile"
require "qloggingcategory"
require "qstringlist"
require "qurl"

require "sqlite3"

require "cstring"

module OCC
  class SyncJournalDb
    SQLITE_IOERR_SHMMAP = SQLITE_IOERR | (21 << 8)
    def initialize(db_file_path, parent)
      super(parent)
      @db_file = db_file_path
      @transaction = 0
      @metadata_table_is_empty = false
      @journal_mode = default_journal_mode(@db_file)
    end

    def get_p_hash(file)
      h = nil
      len = file.length
      h = c_jhash64(file.data, len, 0)

      return h
    end

    def default_journal_mode(_db_path)
      return "WAL"
    end

    def make_db_name(local_path, infix)
      journal_path = ".sync_" + infix + ".db"
      file = QFile.new(QDir.new(local_path).file_path(journal_path))

      if file.exists
        return journal_path
      end

      if file.open(:read_write)
        file.close
        file.remove

        return journal_path
      end

      Log.warn("sync.database") { "Could not find a writable database path #{file.file_name} #{file.error_string}" }

      return journal_path
    end

    def db_is_too_new_for_client(db_file_path)
      db = SqlDatabase.new

      if !db.open_read_only(db_file_path)
        return false
      end

      version_query = SqlQuery.new("SELECT major, minor, patch FROM version;", db)

      if !version_query.next.has_data
        return false
      end

      db_major = version_query.int_value(0)

      return db_major > OCC::Version.version_with_build_number.major_version
    end

    def exists
      locker = QMutexLocker.new(@mutex)

      return !@db_file.is_empty && QFile.exists(@db_file)
    end

    def database_file_path
      return @db_file
    end

    def wal_checkpoint
      t = QElapsedTimer.new
      t.start
      pragma1 = SqlQuery.new(@db)
      pragma1.prepare("PRAGMA wal_checkpoint(FULL);")

      if pragma1.exec
        Log.debug("sync.database") { "took #{t.elapsed} msec" }
      end
    end

    def start_transaction
      if @transaction == 0
        if !@db.transaction
          Log.warn("sync.database") { "ERROR starting transaction: #{@db.error}" }

          return
        end

        @transaction = 1
      else
        Log.debug("sync.database") { "Database Transaction is running, not starting another one!" }
      end
    end

    def commit_transaction
      if @transaction == 1
        if !@db.commit
          Log.warn("sync.database") { "ERROR committing to the database: #{@db.error}" }

          return
        end

        @transaction = 0
      else
        Log.debug("sync.database") { "No database Transaction to commit" }
      end
    end

    def sql_fail(log, query)
      commit_transaction
      Log.warn("sync.database") { "SQL Error #{log} #{query.error}" }
      @db.close

      unless false
        raise
      end

      return false
    end

    def check_connect
      if @closed
        Log.warn("sync.database") { "#{__method__} after the db was closed" }

        return false
      end

      if autotest_fail_counter >= 0
        fail_now = autotest_fail_counter == 0
        autotest_fail_counter -= 1

        if fail_now
          Log.info("sync.database") { "Error Simulated" }

          return false
        end
      end

      if @db.is_open
        return true
      end

      if @db_file.is_empty
        Log.warn("sync.database") { "Database filename #{@db_file} is empty" }

        return false
      end

      if !@db.open_or_create_read_write(@db_file)
        error = @db.error
        Log.warn("sync.database") { "Error opening the db: #{error}" }

        return false
      end

      if !QFile.exists(@db_file)
        Log.warn("sync.database") { "Database file #{@db_file} does not exist" }

        return false
      end

      pragma1 = SqlQuery.new(@db)
      pragma1.prepare("SELECT sqlite_version();")

      if !pragma1.exec
        return sql_fail("SELECT sqlite_version()", pragma1)
      else
        pragma1.next
        Log.info("sync.database") { "sqlite3 version #{pragma1.string_value(0)}" }
      end

      pragma1.prepare("PRAGMA locking_mode=EXCLUSIVE;")

      if !pragma1.exec
        return sql_fail("Set PRAGMA locking_mode", pragma1)
      else
        pragma1.next
        Log.info("sync.database") { "sqlite3 locking_mode= #{pragma1.string_value(0)}" }
      end

      pragma1.prepare("PRAGMA journal_mode=" + @journal_mode + ";")

      if !pragma1.exec
        return sql_fail("Set PRAGMA journal_mode", pragma1)
      else
        pragma1.next
        Log.info("sync.database") { "sqlite3 journal_mode= #{pragma1.string_value(0)}" }
      end

      synchronous_mode = "FULL"

      if QString.from_utf8(@journal_mode).compare("wal", :case_insensitive) == 0
        synchronous_mode = "NORMAL"
      end

      pragma1.prepare("PRAGMA synchronous = " + synchronous_mode + ";")

      if !pragma1.exec
        return sql_fail("Set PRAGMA synchronous", pragma1)
      else
        Log.info("sync.database") { "sqlite3 synchronous= #{synchronous_mode}" }
      end

      pragma1.prepare("PRAGMA case_sensitive_like = ON;")

      if !pragma1.exec
        return sql_fail("Set PRAGMA case_sensitivity", pragma1)
      end

      query = SqlQuery.new(@db)
      query.prepare("DROP INDEX IF EXISTS metadata_parent;")

      if !query.exec
        return sql_fail("updateMetadataTableStructure: remove index metadata_parent", query)
      end

      parent_hash = lambda do |ctx, _, argv|
        text = sqlite3_value_text(argv[0])
        last_slash = std::strrchr(text, "/")

        if !last_slash
          last_slash = text
        end

        sqlite3_result_int64(ctx, c_jhash64(text, last_slash - text, 0))
      end

      sqlite3_create_function(
        @db.sqlite_db,
        "parent_hash",
        1,
        SQLITE_UTF8 | SQLITE_DETERMINISTIC,
        nil,
        parent_hash,
        nil,
        nil
      )

      start_transaction
      create_query = SqlQuery.new(@db)

      create_query.prepare(
        "CREATE TABLE IF NOT EXISTS metadata(" \
        "phash INTEGER(8)," \
        "path VARCHAR(4096)," \
        "inode INTEGER," \
        "modtime INTEGER(8)," \
        "type INTEGER," \
        "md5 VARCHAR(32)," \
        "PRIMARY KEY(phash)" \
        ");"
      )

      if !create_query.exec
        if (
          @journal_mode != "DELETE" &&
          create_query.error_id == SQLITE_IOERR &&
          sqlite3_extended_errcode(@db.sqlite_db) == SQLITE_IOERR_SHMMAP
        )
          Log.warn("sync.database") { "IO error SHMMAP on table creation, attempting with DELETE journal mode" }
          @journal_mode = "DELETE"
          commit_transaction
          @db.close

          return check_connect
        end

        return sql_fail("Create table metadata", create_query)
      end

      create_query.prepare(
        "CREATE TABLE IF NOT EXISTS downloadinfo(" \
        "path VARCHAR(4096)," \
        "tmpfile VARCHAR(4096)," \
        "etag VARCHAR(32)," \
        "errorcount INTEGER," \
        "PRIMARY KEY(path)" \
        ");"
      )

      if !create_query.exec
        return sql_fail("Create table downloadinfo", create_query)
      end

      if !create_upload_info
        return false
      end

      create_query.prepare(
        "CREATE TABLE IF NOT EXISTS blacklist (" \
        "path VARCHAR(4096)," \
        "lastTryEtag VARCHAR[32]," \
        "lastTryModtime INTEGER[8]," \
        "retrycount INTEGER," \
        "errorstring VARCHAR[4096]," \
        "PRIMARY KEY(path)" \
        ");"
      )

      if !create_query.exec
        return sql_fail("Create table blacklist", create_query)
      end

      create_query.prepare(
        "CREATE TABLE IF NOT EXISTS selectivesync (" \
        "path VARCHAR(4096)," \
        "type INTEGER" \
        ");"
      )

      if !create_query.exec
        return sql_fail("Create table selectivesync", create_query)
      end

      create_query.prepare(
        "CREATE TABLE IF NOT EXISTS checksumtype(" \
        "id INTEGER PRIMARY KEY," \
        "name TEXT UNIQUE" \
        ");"
      )

      if !create_query.exec
        return sql_fail("Create table checksumtype", create_query)
      end

      create_query.prepare(
        "CREATE TABLE IF NOT EXISTS conflicts(" \
        "path TEXT PRIMARY KEY," \
        "baseFileId TEXT," \
        "baseEtag TEXT," \
        "baseModtime INTEGER" \
        ");"
      )

      if !create_query.exec
        return sql_fail("Create table conflicts", create_query)
      end

      create_query.prepare(
        "CREATE TABLE IF NOT EXISTS version(" \
        "major INTEGER(8)," \
        "minor INTEGER(8)," \
        "patch INTEGER(8)," \
        "custom VARCHAR(256)" \
        ");"
      )

      if !create_query.exec
        return sql_fail("Create table version", create_query)
      end

      force_remote_discovery = false
      version_query = SqlQuery.new("SELECT major, minor, patch FROM version;", @db)

      if !version_query.next.has_data
        force_remote_discovery = true
        create_query.prepare("INSERT INTO version VALUES (?1, ?2, ?3, ?4);")
        segments = OCC::Version.version_with_build_number.segments

        (0...segments.size).each do |i|
          create_query.bind_value(i + 1, segments[i])
        end

        if !create_query.exec
          return sql_fail("Update version", create_query)
        end
      else
        major = version_query.int_value(0)
        minor = version_query.int_value(1)
        patch = version_query.int_value(2)

        if (
          major == 1 &&
          minor == 8 &&
          (
            patch == 0 ||
            patch == 1
          )
        )
          Log.info("sync.database") { "possibleUpgradeFromMirall_1_8_0_or_1 detected!" }
          force_remote_discovery = true
        end

        if major == 2 && minor < 5
          Log.info("sync.database") { "upgrade from client < 2.5.0 detected! forcing remote discovery" }
          force_remote_discovery = true
        end

        if QVersionNumber.new(major, minor, patch) != OCC::Version.version
          create_query.prepare(
            "UPDATE version SET major=?1, minor=?2, patch =?3, custom=?4 " \
            "WHERE major=?5 AND minor=?6 AND patch=?7;"
          )

          segments = OCC::Version.version_with_build_number.segments

          (0...segments.size).each do |i|
            create_query.bind_value(i + 1, segments[i])
          end

          create_query.bind_value(5, major)
          create_query.bind_value(6, minor)
          create_query.bind_value(7, patch)

          if !create_query.exec
            return sql_fail("Update version", create_query)
          end
        end
      end

      commit_internal("checkConnect")
      rc = update_database_structure

      if !rc
        Log.warn("sync.database") { "Failed to update the database structure!" }
      end

      if force_remote_discovery
        force_remote_discovery_next_sync_locked
      end

      delete_download_info = @query_manager.get(
        :delete_download_info_query,
        "DELETE FROM downloadinfo WHERE path=?1",
        @db
      )

      if !delete_download_info
        return sql_fail("prepare _deleteDownloadInfoQuery", delete_download_info)
      end

      delete_upload_info_query = @query_manager.get(
        :delete_upload_info_query,
        "DELETE FROM uploadinfo WHERE path=?1",
        @db
      )

      if !delete_upload_info_query
        return sql_fail("prepare _deleteUploadInfoQuery", delete_upload_info_query)
      end

      sql = "SELECT lastTryEtag, lastTryModtime, retrycount, errorstring, lastTryTime, ignoreDuration, renameTarget, errorCategory, requestId " \
            "FROM blacklist WHERE path=?1"

      if Utility.fs_case_preserving
        sql += " COLLATE NOCASE"
      end

      get_error_blacklist_query = @query_manager.get(:get_error_blacklist_query, sql, @db)

      if !get_error_blacklist_query
        return sql_fail("prepare _getErrorBlacklistQuery", get_error_blacklist_query)
      end

      commit_internal("checkConnect End", false)
      @metadata_table_is_empty = get_file_record_count == 0
      FileSystem.set_file_hidden(database_file_path, true)
      FileSystem.set_file_hidden(database_file_path + "-wal", true)
      FileSystem.set_file_hidden(database_file_path + "-shm", true)
      FileSystem.set_file_hidden(database_file_path + "-journal", true)

      return rc
    end

    def close
      locker = QMutexLocker.new(@mutex)
      Log.info("sync.database") { "Closing DB #{@db_file}" }
      commit_transaction
      @db.close
      clear_etag_storage_filter
      @metadata_table_is_empty = false
      @closed = true
    end

    def allow_reopen
      unless @closed
        raise
      end

      @closed = false
    end

    def update_database_structure
      if !update_metadata_table_structure
        return false
      end

      if !update_error_blacklist_table_structure
        return false
      end

      return true
    end

    def update_metadata_table_structure
      columns = table_columns("metadata")
      re = true

      if columns.is_empty
        return false
      end

      if columns.index_of("fileid") == -1
        query = SqlQuery.new(@db)
        query.prepare("ALTER TABLE metadata ADD COLUMN fileid VARCHAR(128);")

        if !query.exec
          sql_fail("updateMetadataTableStructure: Add column fileid", query)
          re = false
        end

        query.prepare("CREATE INDEX metadata_file_id ON metadata(fileid);")

        if !query.exec
          sql_fail("updateMetadataTableStructure: create index fileid", query)
          re = false
        end

        commit_internal("update database structure: add fileid col")
      end

      if columns.index_of("remotePerm") == -1
        query = SqlQuery.new(@db)
        query.prepare("ALTER TABLE metadata ADD COLUMN remotePerm VARCHAR(128);")

        if !query.exec
          sql_fail("updateMetadataTableStructure: add column remotePerm", query)
          re = false
        end

        commit_internal("update database structure (remotePerm)")
      end

      if columns.index_of("filesize") == -1
        query = SqlQuery.new(@db)
        query.prepare("ALTER TABLE metadata ADD COLUMN filesize BIGINT;")

        if !query.exec
          sql_fail("updateDatabaseStructure: add column filesize", query)
          re = false
        end

        commit_internal("update database structure: add filesize col")
      end

      query = SqlQuery.new(@db)
      query.prepare("CREATE INDEX IF NOT EXISTS metadata_inode ON metadata(inode);")

      if !query.exec
        sql_fail("updateMetadataTableStructure: create index inode", query)
        re = false
      end

      commit_internal("update database structure: add inode index")
      query = SqlQuery.new(@db)
      query.prepare("CREATE INDEX IF NOT EXISTS metadata_path ON metadata(path);")

      if !query.exec
        sql_fail("updateMetadataTableStructure: create index path", query)
        re = false
      end

      commit_internal("update database structure: add path index")
      query = SqlQuery.new(@db)
      query.prepare("CREATE INDEX IF NOT EXISTS metadata_parent ON metadata(parent_hash(path));")

      if !query.exec
        sql_fail("updateMetadataTableStructure: create index parent", query)
        re = false
      end

      commit_internal("update database structure: add parent index")

      if columns.index_of("ignoredChildrenRemote") == -1
        query = SqlQuery.new(@db)
        query.prepare("ALTER TABLE metadata ADD COLUMN ignoredChildrenRemote INT;")

        if !query.exec
          sql_fail("updateMetadataTableStructure: add ignoredChildrenRemote column", query)
          re = false
        end

        commit_internal("update database structure: add ignoredChildrenRemote col")
      end

      if columns.index_of("contentChecksum") == -1
        query = SqlQuery.new(@db)
        query.prepare("ALTER TABLE metadata ADD COLUMN contentChecksum TEXT;")

        if !query.exec
          sql_fail("updateMetadataTableStructure: add contentChecksum column", query)
          re = false
        end

        commit_internal("update database structure: add contentChecksum col")
      end

      if columns.index_of("contentChecksumTypeId") == -1
        query = SqlQuery.new(@db)
        query.prepare("ALTER TABLE metadata ADD COLUMN contentChecksumTypeId INTEGER;")

        if !query.exec
          sql_fail("updateMetadataTableStructure: add contentChecksumTypeId column", query)
          re = false
        end

        commit_internal("update database structure: add contentChecksumTypeId col")
      end

      if columns.index_of("hasDirtyPlaceholder") == -1
        add_dirty_query = SqlQuery.new(@db)
        add_dirty_query.prepare("ALTER TABLE metadata ADD COLUMN hasDirtyPlaceholder BOOLEAN;")

        if !add_dirty_query.exec
          sql_fail("updateMetadataTableStructure: add hasDirtyPlaceholder column", add_dirty_query)
          re = false
        end

        dirty_index = SqlQuery.new(@db)
        dirty_index.prepare("CREATE INDEX hasDirtyPlaceholderIndex ON metadata(path) WHERE hasDirtyPlaceholder=TRUE;")

        if !dirty_index.exec
          sql_fail("updateMetadataTableStructure: add index on hasDirtyPlaceholder column", dirty_index)
          re = false
        end

        commit_internal("update database structure: add hasDirtyPlaceholder col")
      end

      conflicts_columns = table_columns("conflicts")

      if conflicts_columns.is_empty
        return false
      end

      if !conflicts_columns.contains("basePath")
        query = SqlQuery.new(@db)
        query.prepare("ALTER TABLE conflicts ADD COLUMN basePath TEXT;")

        if !query.exec
          sql_fail("updateMetadataTableStructure: add basePath column", query)
          re = false
        end
      end

      return re
    end

    def update_error_blacklist_table_structure
      columns = table_columns("blacklist")
      re = true

      if columns.is_empty
        return false
      end

      if columns.index_of("lastTryTime") == -1
        query = SqlQuery.new(@db)
        query.prepare("ALTER TABLE blacklist ADD COLUMN lastTryTime INTEGER(8);")

        if !query.exec
          sql_fail("updateBlacklistTableStructure: Add lastTryTime fileid", query)
          re = false
        end

        query.prepare("ALTER TABLE blacklist ADD COLUMN ignoreDuration INTEGER(8);")

        if !query.exec
          sql_fail("updateBlacklistTableStructure: Add ignoreDuration fileid", query)
          re = false
        end

        commit_internal("update database structure: add lastTryTime, ignoreDuration cols")
      end

      if columns.index_of("renameTarget") == -1
        query = SqlQuery.new(@db)
        query.prepare("ALTER TABLE blacklist ADD COLUMN renameTarget VARCHAR(4096);")

        if !query.exec
          sql_fail("updateBlacklistTableStructure: Add renameTarget", query)
          re = false
        end

        commit_internal("update database structure: add renameTarget col")
      end

      if columns.index_of("errorCategory") == -1
        query = SqlQuery.new(@db)
        query.prepare("ALTER TABLE blacklist ADD COLUMN errorCategory INTEGER(8);")

        if !query.exec
          sql_fail("updateBlacklistTableStructure: Add errorCategory", query)
          re = false
        end

        commit_internal("update database structure: add errorCategory col")
      end

      if columns.index_of("requestId") == -1
        query = SqlQuery.new(@db)
        query.prepare("ALTER TABLE blacklist ADD COLUMN requestId VARCHAR(36);")

        if !query.exec
          sql_fail("updateBlacklistTableStructure: Add requestId", query)
          re = false
        end

        commit_internal("update database structure: add errorCategory col")
      end

      query = SqlQuery.new(@db)
      query.prepare("CREATE INDEX IF NOT EXISTS blacklist_index ON blacklist(path collate nocase);")

      if !query.exec
        sql_fail("updateErrorBlacklistTableStructure: create index blacklit", query)
        re = false
      end

      return re
    end

    def table_columns(table)
      columns = []

      if !check_connect
        return columns
      end

      query = SqlQuery.new("PRAGMA table_info('" + table + "');", @db)

      if !query.exec
        return columns
      end

      while query.next.has_data
        columns.append(query.ba_value(1))
      end

      Log.debug("sync.database") { "Columns in the current journal: #{columns}" }

      return columns
    end

    def set_file_record(record)
      locker = QMutexLocker.new(@mutex)
      utf8_path = record.path.to_utf8
      etag = record.etag.to_utf8

      if !@etag_storage_filter.is_empty
        prefix = utf8_path + "/"

        @etag_storage_filter.each do |it|
          if it.starts_with(prefix)
            Log.info("sync.database") { "Filtered writing the etag of #{prefix} because it is a prefix of #{it}" }
            etag = "_invalid_"

            break
          end
        end
      end

      Log.info("sync.database") { "Updating file record: #{record} with etag #{etag}" }

      unless !record.remote_perm.is_null
        raise
      end

      unless record.inode != 0
        raise
      end

      if check_connect
        phash = get_p_hash(utf8_path)
        remote_perm = record.remote_perm.to_db_value
        checksum_header = ChecksumHeader.parse_checksum_header(record.checksum_header)
        content_checksum_type_id = map_checksum_type(checksum_header.type)

        query = @query_manager.get(
          :set_file_record_query,
          "INSERT OR REPLACE INTO metadata " \
          "(phash, path, inode, modtime, type, md5, fileid, remotePerm, filesize, ignoredChildrenRemote, " \
          "contentChecksum, contentChecksumTypeId, hasDirtyPlaceholder) " \
          "VALUES (?1 , ?2, ?3 , ?4 , ?5 , ?6 , ?7,  ?8 , ?9 , ?10, ?11, ?12, ?13);",
          @db
        )

        if !query
          return query.error
        end

        i = 1
        query.bind_value(i, phash)
        i += 1
        query.bind_value(i, utf8_path)
        i += 1
        query.bind_value(i, record.inode)
        i += 1
        query.bind_value(i, record.modtime)
        i += 1
        query.bind_value(i, record.type)
        i += 1
        query.bind_value(i, etag)
        i += 1
        query.bind_value(i, record.file_id)
        i += 1
        query.bind_value(i, remote_perm)
        i += 1
        query.bind_value(i, record.size)
        i += 1
        query.bind_value(i, record.server_has_ignored_files)
        i += 1
        query.bind_value(i, checksum_header.checksum)
        i += 1
        query.bind_value(i, content_checksum_type_id)
        i += 1
        query.bind_value(i, record.has_dirty_placeholder)

        if !query.exec
          return query.error
        end

        @metadata_table_is_empty = false

        return nil
      else
        Log.warn("sync.database") { "Failed to connect database." }

        return "Failed to connect database."
      end
    end

    def delete_file_record(filename, recursively)
      locker = QMutexLocker.new(@mutex)

      if check_connect
        query = @query_manager.get(:delete_file_record_phash, "DELETE FROM metadata WHERE phash=?1", @db)

        if !query
          return false
        end

        phash = get_p_hash(filename.to_utf8)
        query.bind_value(1, phash)

        if !query.exec
          return false
        end

        if recursively
          query = @query_manager.get(
            :delete_file_record_recursively,
            "DELETE FROM metadata WHERE (path > (?1||'/') AND path < (?1||'0'))",
            @db
          )

          if !query
            return false
          end

          query.bind_value(1, filename)

          if !query.exec
            return false
          end
        end

        return true
      else
        Log.warn("sync.database") { "Failed to connect database." }

        return false
      end
    end

    def get_file_record(filename)
      unless !QDir.is_absolute_path(filename)
        raise
      end

      locker = QMutexLocker.new(@mutex)

      if @metadata_table_is_empty
        return nil
      end

      if !check_connect
        return "Not connected"
      end

      if !filename.is_empty
        query = @query_manager.get(:get_file_record_query, SyncJournalFileRecord.query + "WHERE phash=?1", @db)

        if !query
          return "Failed to create query"
        end

        query.bind_value(1, get_p_hash(filename.to_utf8))

        if !query.exec
          close

          return "Failed to execute query"
        end

        next_row = query.next

        if !next_row.ok
          err = query.error
          Log.warn("sync.database") { "No journal entry found for #{filename} Error: #{err}" }
          close

          return err
        end

        if next_row.has_data
          return SyncJournalFileRecord.from_sql_query(query)
        end
      end

      return "No file name provided"
    end

    def get_file_record_by_inode(inode)
      locker = QMutexLocker.new(@mutex)

      if inode == 0 || @metadata_table_is_empty
        return nil
      end

      if !check_connect
        return "Not connected"
      end

      query = @query_manager.get(:get_file_record_query_by_inode, SyncJournalFileRecord.query + "WHERE inode=?1", @db)

      if !query
        return "Failed to create query"
      end

      query.bind_value(1, inode)

      if !query.exec
        return "Failed to execute query"
      end

      next_row = query.next

      if !next_row.ok
        return query.error
      end

      if next_row.has_data
        return SyncJournalFileRecord.from_sql_query(query)
      end

      return nil
    end

    def get_file_records_by_file_id(file_id, row_callback)
      locker = QMutexLocker.new(@mutex)

      if file_id.is_empty || @metadata_table_is_empty
        return true
      end

      if !check_connect
        return false
      end

      query = @query_manager.get(
        :get_file_record_query_by_file_id,
        SyncJournalFileRecord.query + "WHERE fileid=?1",
        @db
      )

      if !query
        return false
      end

      query.bind_value(1, file_id)

      if !query.exec
        return false
      end

      while true
        next_row = query.next

        if !next_row.ok
          return false
        end

        if !next_row.has_data
          break
        end

        row_callback.call(SyncJournalFileRecord.from_sql_query(query))
      end

      return true
    end

    def get_files_below_path(path, row_callback)
      locker = QMutexLocker.new(@mutex)

      if @metadata_table_is_empty
        return true
      end

      if !check_connect
        return false
      end

      exec = lambda do |query|
        if !query.exec
          return false
        end

        while true
          next_row = query.next

          if !next_row.ok
            return false
          end

          if !next_row.has_data
            break
          end

          row_callback.call(SyncJournalFileRecord.from_sql_query(query))
        end

        return true
      end

      if path.is_empty
        query = @query_manager.get(:get_all_files_query, SyncJournalFileRecord.query + "ORDER BY path||'/' ASC", @db)

        if !query
          return false
        end

        return exec.call(query)
      else
        query = @query_manager.get(
          :get_files_below_path_query,
          SyncJournalFileRecord.query + "WHERE (path > (?1||'/') AND path < (?1||'0')) ORDER BY path||'/' ASC",
          @db
        )

        if !query
          return false
        end

        query.bind_value(1, path.to_utf8)

        return exec.call(query)
      end
    end

    def list_files_in_path(path, row_callback)
      locker = QMutexLocker.new(@mutex)

      if @metadata_table_is_empty
        return true
      end

      if !check_connect
        return false
      end

      query = @query_manager.get(
        :list_files_in_path_query,
        SyncJournalFileRecord.query + "WHERE parent_hash(path) = ?1 ORDER BY path||'/' ASC",
        @db
      )

      if !query
        return false
      end

      query.bind_value(1, get_p_hash(path.to_utf8))

      if !query.exec
        return false
      end

      while true
        next_row = query.next

        if !next_row.ok
          return false
        end

        if !next_row.has_data
          break
        end

        rec = SyncJournalFileRecord.from_sql_query(query)

        if (
          !rec.path.starts_with(path) ||
          rec.path.index_of("/", path.size + 1) > 0
        )
          Log.warn("sync.database") { "hash collision #{path} #{rec.path}" }

          next
        end

        row_callback.call(rec)
      end

      return true
    end

    def get_file_record_count
      locker = QMutexLocker.new(@mutex)
      query = SqlQuery.new(@db)
      query.prepare("SELECT COUNT(*) FROM metadata")

      if !query.exec
        return -1
      end

      if query.next.has_data
        count = query.int_value(0)

        return count
      end

      return -1
    end

    def update_file_record_checksum(filename, content_checksum, content_checksum_type)
      locker = QMutexLocker.new(@mutex)
      Log.info("sync.database") { "Updating file checksum #{filename} #{content_checksum} #{content_checksum_type}" }
      phash = get_p_hash(filename.to_utf8)

      if !check_connect
        Log.warn("sync.database") { "Failed to connect database." }

        return false
      end

      checksum_type_id = map_checksum_type(content_checksum_type)

      query = @query_manager.get(
        :set_file_record_checksum_query,
        "UPDATE metadata" \
        " SET contentChecksum = ?2, contentChecksumTypeId = ?3" \
        " WHERE phash == ?1;",
        @db
      )

      if !query
        return false
      end

      query.bind_value(1, phash)
      query.bind_value(2, content_checksum)
      query.bind_value(3, checksum_type_id)

      return query.exec
    end

    def has_hydrated_or_dehydrated_files(filename)
      locker = QMutexLocker.new(@mutex)

      if !check_connect
        return nil
      end

      query = @query_manager.get(
        :count_dehydrated_files_query,
        "SELECT DISTINCT type FROM metadata" \
        " WHERE ((path == ?1 OR (path > (?1||'/') AND path < (?1||'0'))) OR ?1 == '');",
        @db
      )

      if !query
        return nil
      end

      query.bind_value(1, filename)

      if !query.exec
        return nil
      end

      result = HasHydratedDehydrated.new

      while true
        next_row = query.next

        if !next_row.ok
          return nil
        end

        if !next_row.has_data
          break
        end

        type = query.int_value(0)

        if (
          type == :item_type_file ||
          type == :item_type_virtual_file_dehydration
        )
          result.has_hydrated = true
        end

        if (
          type == :item_type_virtual_file ||
          type == :item_type_virtual_file_download
        )
          result.has_dehydrated = true
        end
      end

      return result
    end

    def to_download_info(query, res)
      ok = true
      res.tmpfile = query.string_value(0)
      res.etag = query.ba_value(1)
      res.error_count = query.int_value(2)
      res.valid = ok
    end

    def delete_batch(query, entries, name)
      if entries.is_empty
        return true
      end

      Log.debug("sync.database") { "Removing stale #{name} entries: #{entries.join(", ")}" }

      entries.each do |entry|
        query.reset_and_clear_bindings
        query.bind_value(1, entry)

        if !query.exec
          return false
        end
      end

      return true
    end

    def get_download_info(file)
      locker = QMutexLocker.new(@mutex)
      res = DownloadInfo.new

      if check_connect
        query = @query_manager.get(
          :get_download_info_query,
          "SELECT tmpfile, etag, errorcount FROM downloadinfo WHERE path=?1",
          @db
        )

        if !query
          return res
        end

        query.bind_value(1, file)

        if !query.exec
          return res
        end

        if query.next.has_data
          to_download_info(query, res)
        end
      end

      return res
    end

    def set_download_info(file, i)
      locker = QMutexLocker.new(@mutex)

      if !check_connect
        return
      end

      if i.valid
        query = @query_manager.get(
          :set_download_info_query,
          "INSERT OR REPLACE INTO downloadinfo " \
          "(path, tmpfile, etag, errorcount) " \
          "VALUES ( ?1 , ?2, ?3, ?4 )",
          @db
        )

        if !query
          return
        end

        query.bind_value(1, file)
        query.bind_value(2, i.tmpfile)
        query.bind_value(3, i.etag)
        query.bind_value(4, i.error_count)
        query.exec
      else
        query = @query_manager.get(:delete_download_info_query)
        query.bind_value(1, file)
        query.exec
      end
    end

    def get_and_delete_stale_download_infos(keep)
      empty_result = []
      locker = QMutexLocker.new(@mutex)

      if !check_connect
        return empty_result
      end

      superfluous_paths = []
      deleted_entries = []
      query = SqlQuery.new(@db)
      query.prepare("SELECT tmpfile, etag, errorcount, path FROM downloadinfo")

      if !query.exec
        return empty_result
      end

      while query.next.has_data
        file = query.string_value(3)

        if !keep.contains(file)
          superfluous_paths.append(file)
          info = DownloadInfo.new
          to_download_info(query, info)
          deleted_entries.append(info)
        end
      end

      query = @query_manager.get(:delete_download_info_query)

      if !delete_batch(query, superfluous_paths, "downloadinfo")
        return empty_result
      end

      return deleted_entries
    end

    def download_info_count
      re = 0
      locker = QMutexLocker.new(@mutex)

      if check_connect
        query = SqlQuery.new("SELECT count(*) FROM downloadinfo", @db)

        if !query.exec
          sql_fail("Count number of downloadinfo entries failed", query)
        end

        if query.next.has_data
          re = query.int_value(0)
        end
      end

      return re
    end

    def get_upload_info(file)
      locker = QMutexLocker.new(@mutex)

      if !check_connect
        return nil
      end

      query = @query_manager.get(
        :get_upload_info_query,
        "SELECT size, modtime, contentChecksum, url FROM uploadinfo WHERE path=?1",
        @db
      )

      if !query
        return nil
      end

      query.bind_value(1, file)

      if !query.exec
        return nil
      end

      res = UploadInfo.new

      if query.next.has_data
        index = 0
        res.path = file
        res.size = query.int64_value(index)
        index += 1
        res.modtime = query.int64_value(index)
        index += 1
        res.content_checksum = query.ba_value(index)
        index += 1
        res.url = QUrl.from_encoded(query.ba_value(index))
        index += 1
        res.valid = true
      end

      return res
    end

    def get_upload_infos
      locker = QMutexLocker.new(@mutex)

      query = @query_manager.get(
        :get_all_upload_info_query,
        "SELECT size, modtime, contentChecksum, path, url FROM uploadinfo",
        @db
      )

      if !query
        return nil
      end

      if !query.exec
        return nil
      end

      res = []

      while query.next.has_data
        info = UploadInfo.new
        index = 0
        info.size = query.int64_value(index)
        index += 1
        info.modtime = query.int64_value(index)
        index += 1
        info.content_checksum = query.ba_value(index)
        index += 1
        info.path = query.string_value(index)
        index += 1
        info.url = QUrl.from_encoded(query.ba_value(index))
        index += 1
        info.valid = true
        res.push_back(info)
      end

      return res
    end

    def set_upload_info(file, i)
      locker = QMutexLocker.new(@mutex)

      if !check_connect
        return
      end

      if i.valid
        unless i.url.is_valid
          raise
        end

        query = @query_manager.get(
          :set_upload_info_query,
          "INSERT OR REPLACE INTO uploadinfo " \
          "(path, size, modtime, contentChecksum, url) " \
          "VALUES ( ?1 , ?2, ?3 , ?4 , ?5 )",
          @db
        )

        if !query
          return
        end

        index = 1
        query.bind_value(index, file)
        index += 1
        query.bind_value(index, i.size)
        index += 1
        query.bind_value(index, i.modtime)
        index += 1
        query.bind_value(index, i.content_checksum)
        index += 1
        query.bind_value(index, i.url.to_encoded)

        if !query.exec
          return
        end
      else
        query = @query_manager.get(:delete_upload_info_query)
        query.bind_value(1, file)

        if !query.exec
          return
        end
      end
    end

    def delete_stale_upload_infos(keep)
      locker = QMutexLocker.new(@mutex)

      if !check_connect
        return nil
      end

      query = SqlQuery.new(@db)
      query.prepare("SELECT path FROM uploadinfo")

      if !query.exec
        return false
      end

      superfluous_paths = []

      while query.next.has_data
        file = query.string_value(0)

        if !keep.contains(file)
          superfluous_paths.append(file)
        end
      end

      Log.debug("sync.database") { "#{__method__} Keep: #{keep} Removing Stale: #{superfluous_paths}" }
      delete_upload_info_query = @query_manager.get(:delete_upload_info_query)
      delete_batch(delete_upload_info_query, superfluous_paths, "uploadinfo")

      return true
    end

    def error_blacklist_entry(file)
      locker = QMutexLocker.new(@mutex)
      entry = SyncJournalErrorBlacklistRecord.new

      if file.is_empty
        return entry
      end

      if check_connect
        query = @query_manager.get(:get_error_blacklist_query)
        query.bind_value(1, file)

        if query.exec
          if query.next.has_data
            entry.last_try_etag = query.ba_value(0)
            entry.last_try_modtime = query.int64_value(1)
            entry.retry_count = query.int_value(2)
            entry.error_string = query.string_value(3)
            entry.last_try_time = query.int64_value(4)
            entry.ignore_duration = query.int64_value(5)
            entry.rename_target = query.string_value(6)
            entry.error_category = query.int_value(7)
            entry.request_id = query.ba_value(8)
            entry.file = file
          end
        end
      end

      return entry
    end

    def delete_stale_error_blacklist_entries(keep)
      locker = QMutexLocker.new(@mutex)

      if !check_connect
        return false
      end

      query = SqlQuery.new(@db)
      query.prepare("SELECT path FROM blacklist")

      if !query.exec
        return false
      end

      superfluous_paths = []

      while query.next.has_data
        file = query.string_value(0)

        if !keep.contains(file)
          superfluous_paths.append(file)
        end
      end

      del_query = SqlQuery.new(@db)
      del_query.prepare("DELETE FROM blacklist WHERE path = ?")

      return delete_batch(del_query, superfluous_paths, "blacklist")
    end

    def error_black_list_entry_count
      re = 0
      locker = QMutexLocker.new(@mutex)

      if check_connect
        query = SqlQuery.new("SELECT count(*) FROM blacklist", @db)

        if !query.exec
          sql_fail("Count number of blacklist entries failed", query)
        end

        if query.next.has_data
          re = query.int_value(0)
        end
      end

      return re
    end

    def wipe_error_blacklist
      locker = QMutexLocker.new(@mutex)

      if check_connect
        query = SqlQuery.new(@db)
        query.prepare("DELETE FROM blacklist")

        if !query.exec
          sql_fail("Deletion of whole blacklist failed", query)

          return -1
        end

        return query.num_rows_affected
      end

      return -1
    end

    def wipe_error_blacklist_entry(relative_file)
      if relative_file.is_empty
        return
      end

      unless QFileInfo.new(relative_file).is_relative
        raise
      end

      locker = QMutexLocker.new(@mutex)

      if check_connect
        query = SqlQuery.new(@db)
        query.prepare("DELETE FROM blacklist WHERE path=?1")
        query.bind_value(1, relative_file)

        if !query.exec
          sql_fail("Deletion of blacklist item failed.", query)
        end
      end
    end

    def wipe_error_blacklist_entry_with_category(relative_file, category)
      if relative_file.is_empty
        return
      end

      unless QFileInfo.new(relative_file).is_relative
        raise
      end

      locker = QMutexLocker.new(@mutex)

      if check_connect
        query = SqlQuery.new(@db)
        query.prepare("DELETE FROM blacklist WHERE path=?1 AND errorCategory=?2")
        query.bind_value(1, relative_file)
        query.bind_value(2, category)

        if !query.exec
          sql_fail("Deletion of blacklist item failed.", query)
        end
      end
    end

    def wipe_error_blacklist_category(category)
      locker = QMutexLocker.new(@mutex)

      if check_connect
        query = SqlQuery.new(@db)
        query.prepare("DELETE FROM blacklist WHERE errorCategory=?1")
        query.bind_value(1, category)

        if !query.exec
          sql_fail("Deletion of blacklist category failed.", query)
        end
      end
    end

    def set_error_blacklist_entry(item)
      locker = QMutexLocker.new(@mutex)

      Log.info("sync.database") {
        "Setting blacklist entry for #{item.file} #{item.retry_count} #{item.error_string} #{item.last_try_time} #{item.ignore_duration}" \
          " #{item.last_try_modtime} #{item.last_try_etag} #{item.rename_target} #{item.error_category}"
      }

      if !check_connect
        return
      end

      query = @query_manager.get(
        :set_error_blacklist_query,
        "INSERT OR REPLACE INTO blacklist " \
        "(path, lastTryEtag, lastTryModtime, retrycount, errorstring, lastTryTime, ignoreDuration, renameTarget, errorCategory, requestId) " \
        "VALUES ( ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
        @db
      )

      if !query
        return
      end

      query.bind_value(1, item.file)
      query.bind_value(2, item.last_try_etag)
      query.bind_value(3, item.last_try_modtime)
      query.bind_value(4, item.retry_count)
      query.bind_value(5, item.error_string)
      query.bind_value(6, item.last_try_time)
      query.bind_value(7, item.ignore_duration)
      query.bind_value(8, item.rename_target)
      query.bind_value(9, item.error_category)
      query.bind_value(10, item.request_id)
      query.exec
    end

    def get_selective_sync_list(type, ok)
      result = Set.new

      unless ok
        raise
      end

      locker = QMutexLocker.new(@mutex)

      if !check_connect
        ok = false

        return result
      end

      query = @query_manager.get(:get_selective_sync_list_query, "SELECT path FROM selectivesync WHERE type=?1", @db)

      if !query
        ok = false

        return result
      end

      query.bind_value(1, type)

      if !query.exec
        ok = false

        return result
      end

      while true
        next_row = query.next

        if !next_row.ok
          ok = false

          return result
        end

        if !next_row.has_data
          break
        end

        entry = query.string_value(0)

        if !entry.ends_with("/")
          entry.append("/")
        end

        result.insert(entry)
      end

      ok = true

      return result
    end

    def set_selective_sync_list(type, list)
      locker = QMutexLocker.new(@mutex)

      if !check_connect
        return
      end

      start_transaction
      del_query = SqlQuery.new("DELETE FROM selectivesync WHERE type == ?1", @db)
      del_query.bind_value(1, type)

      if !del_query.exec
        Log.warn("sync.database") { "SQL error when deleting selective sync list #{list} #{del_query.error}" }
      end

      ins_query = SqlQuery.new("INSERT INTO selectivesync VALUES (?1, ?2)", @db)

      list.each do |path|
        ins_query.reset_and_clear_bindings
        ins_query.bind_value(1, path)
        ins_query.bind_value(2, type)

        if !ins_query.exec
          Log.warn("sync.database") { "SQL error when inserting into selective sync #{type} #{path} #{del_query.error}" }
        end
      end

      commit_internal("setSelectiveSyncList")
    end

    def avoid_renames_on_next_sync(path)
      locker = QMutexLocker.new(@mutex)

      if !check_connect
        return
      end

      query = SqlQuery.new(@db)
      query.prepare("UPDATE metadata SET fileid = '', inode = '0' WHERE (path == ?1 OR (path > (?1||'/') AND path < (?1||'0')))")
      query.bind_value(1, path)
      query.exec
      schedule_path_for_remote_discovery(path)
    end

    def schedule_path_for_remote_discovery(file_name)
      locker = QMutexLocker.new(@mutex)

      if !check_connect
        return
      end

      argument = file_name

      if argument.ends_with("/")
        argument.chop(1)
      end

      query = SqlQuery.new(@db)
      query.prepare("UPDATE metadata SET md5='_invalid_' WHERE (?1 == path OR (?1 > (path||'/') AND ?1 < (path||'0'))) AND type == 2;")
      query.bind_value(1, argument)
      query.exec
      argument.append("/")
      @etag_storage_filter.append(argument)
    end

    def clear_etag_storage_filter
      @etag_storage_filter.clear
    end

    def force_remote_discovery_next_sync
      locker = QMutexLocker.new(@mutex)

      if !check_connect
        return
      end

      force_remote_discovery_next_sync_locked
    end

    def force_remote_discovery_next_sync_locked
      Log.info("sync.database") { "Forcing remote re-discovery by deleting folder Etags" }
      delete_remote_folder_etags_query = SqlQuery.new(@db)
      delete_remote_folder_etags_query.prepare("UPDATE metadata SET md5='_invalid_' WHERE type=2;")
      delete_remote_folder_etags_query.exec
    end

    def get_checksum_type(checksum_type_id)
      locker = QMutexLocker.new(@mutex)

      if !check_connect
        return ""
      end

      query = @query_manager.get(:get_checksum_type_query, "SELECT name FROM checksumtype WHERE id=?1", @db)

      if !query
        return nil
      end

      query.bind_value(1, checksum_type_id)

      if !query.exec
        return ""
      end

      if !query.next.has_data
        Log.warn("sync.database") { "No checksum type mapping found for #{checksum_type_id}" }

        return ""
      end

      return query.ba_value(0)
    end

    def map_checksum_type(checksum_type)
      if checksum_type == :parse_error || checksum_type == :none
        return 0
      end

      it = @checksym_type_cache.const_find(checksum_type)

      if it != @checksym_type_cache.cend
        return it
      end

      type_name = Utility.enum_to_string(checksum_type).to_utf8

      query = @query_manager.get(
        :insert_checksum_type_query,
        "INSERT OR IGNORE INTO checksumtype (name) VALUES (?1)",
        @db
      )

      if !query
        return 0
      end

      query.bind_value(1, type_name)

      if !query.exec
        return 0
      end

      query = @query_manager.get(:get_checksum_type_id_query, "SELECT id FROM checksumtype WHERE UPPER(name)=?1", @db)

      if !query
        return 0
      end

      query.bind_value(1, type_name)

      if !query.exec
        return 0
      end

      if !query.next.has_data
        Log.warn("sync.database") { "No checksum type mapping found for #{checksum_type}" }

        return 0
      end

      value = query.int_value(0)
      @checksym_type_cache[checksum_type] = value

      return value
    end

    def set_conflict_record(record)
      locker = QMutexLocker.new(@mutex)

      if !check_connect
        return
      end

      query = @query_manager.get(
        :set_conflict_record_query,
        "INSERT OR REPLACE INTO conflicts " \
        "(path, baseFileId, baseModtime, baseEtag, basePath) " \
        "VALUES (?1, ?2, ?3, ?4, ?5);",
        @db
      )

      unless query
        raise
      end

      query.bind_value(1, record.path)
      query.bind_value(2, record.base_file_id)
      query.bind_value(3, record.base_modtime)
      query.bind_value(4, record.base_etag)
      query.bind_value(5, record.initial_base_path)

      unless query.exec
        raise
      end
    end

    def conflict_record(path)
      entry = ConflictRecord.new
      locker = QMutexLocker.new(@mutex)

      if !check_connect
        return entry
      end

      query = @query_manager.get(
        :get_conflict_record_query,
        "SELECT baseFileId, baseModtime, baseEtag, basePath FROM conflicts WHERE path=?1;",
        @db
      )

      unless query
        raise
      end

      query.bind_value(1, path)

      unless query.exec
        raise
      end

      if !query.next.has_data
        return entry
      end

      entry.path = path
      entry.base_file_id = query.ba_value(0)
      entry.base_modtime = query.int64_value(1)
      entry.base_etag = query.ba_value(2)
      entry.initial_base_path = query.ba_value(3)

      return entry
    end

    def delete_conflict_record(path)
      locker = QMutexLocker.new(@mutex)

      if !check_connect
        return
      end

      query = @query_manager.get(:delete_conflict_record_query, "DELETE FROM conflicts WHERE path=?1;", @db)

      unless query
        raise
      end

      query.bind_value(1, path)

      unless query.exec
        raise
      end
    end

    def conflict_record_paths
      locker = QMutexLocker.new(@mutex)

      if !check_connect
        return nil
      end

      query = SqlQuery.new(@db)
      query.prepare("SELECT path FROM conflicts")

      unless query.exec
        raise
      end

      paths = []

      while query.next.has_data
        paths.append(query.ba_value(0))
      end

      return paths
    end

    def conflict_file_base_name(conflict_name)
      conflict = conflict_record(conflict_name.to_utf8)
      result = ""

      if conflict.is_valid
        get_file_records_by_file_id(conflict.base_file_id) do |record|
          if !record.path.is_empty
            result = record.path
          end
        end
      end

      if result.is_empty
        result = Utility.conflict_file_base_name_from_pattern(conflict_name)
      end

      return result
    end

    def clear_file_table
      lock = QMutexLocker.new(@mutex)
      query = SqlQuery.new(@db)
      query.prepare("DELETE FROM metadata;")
      query.exec
    end

    def commit(context, start_trans)
      lock = QMutexLocker.new(@mutex)
      commit_internal(context, start_trans)
    end

    def commit_if_needed_and_start_new_transaction(context)
      lock = QMutexLocker.new(@mutex)

      if @transaction == 1
        commit_internal(context, true)
      else
        start_transaction
      end
    end

    def open
      lock = QMutexLocker.new(@mutex)

      return check_connect
    end

    def is_open
      lock = QMutexLocker.new(@mutex)

      return @db.is_open
    end

    def commit_internal(context, start_trans)
      if start_trans
        Log.debug("sync.database") { "Transaction commit #{context} and starting new transaction" }
      else
        Log.debug("sync.database") { "Transaction commit #{context} " }
      end

      commit_transaction

      if start_trans
        start_transaction
      end
    end

    def finalize
      close
    end

    def get_file_records_with_dirty_placeholders
      locker = QMutexLocker.new(@mutex)

      if is_open
        query = @query_manager.get(
          :get_file_reocrds_with_dirty_placeholders_query,
          SyncJournalFileRecord.query + "WHERE hasDirtyPlaceholder=TRUE",
          @db
        )

        if !query
          return nil
        end

        if !query.exec
          return nil
        end

        out = []

        while query.next.has_data
          out.append(SyncJournalFileRecord.from_sql_query(query))
        end

        return out
      end

      return nil
    end

    def create_upload_info
      create_query = SqlQuery.new(
        "CREATE TABLE IF NOT EXISTS uploadinfo(" \
        "path VARCHAR(4096)," \
        "size INTEGER(8)," \
        "modtime INTEGER(8)," \
        "contentChecksum TEXT," \
        "url TEXT, " \
        "PRIMARY KEY(path)" \
        ");",
        @db
      )

      if !create_query.exec
        return sql_fail("Create table uploadinfo", create_query)
      end

      return true
    end

    class DownloadInfo
      def ==(other)
        return (
          @error_count == other.error_count &&
          @etag == other.etag &&
          @tmpfile == other.tmpfile &&
          @valid == other.valid
        )
      end
    end

    class UploadInfo
      def ==(other)
        return (
          @modtime == other.modtime &&
          @valid == other.valid &&
          @size == other.size &&
          @content_checksum == other.content_checksum
        )
      end
    end
  end
end
