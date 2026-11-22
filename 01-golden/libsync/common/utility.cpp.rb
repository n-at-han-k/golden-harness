#!/usr/bin/env ruby
#
# Copyright (C) by Klaas Freitag <freitag@owncloud.com>
# Copyright (C) by Daniel Molkentin <danimo@owncloud.com>
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

require_relative "common/utility"
require_relative "common/asserts"
require_relative "common/filesystembase"
require_relative "common/version"
require_relative "libsync/filesystem"

require "qcollator"
require "qcoreapplication"
require "qdatetime"
require "qdir"
require "qfile"
require "qfileinfo"
require "qobject"
require "qprocess"
require "qrandomgenerator"
require "qregularexpression"
require "qsettings"
require "qstandardpaths"
require "qsysinfo"
require "qtextstream"
require "qthread"
require "qtimezone"
require "qurl"
require "quuid"

require "sys/statvfs"
require "sys/types"
require "unistd"

require "cstring"
require "math"

include Qt::Literals::StringLiterals
include std::chrono

module OCC
  module Utility
    PERIODS = [[QT_TRANSLATE_N_NOOP("Utility", "%n year(s)"), (24 * 3600) * 365], [QT_TRANSLATE_N_NOOP(
      "Utility",
      "%n month(s)"
    ), (24 * 3600) * 30], [QT_TRANSLATE_N_NOOP("Utility", "%n day(s)"), (24 * 3600)], [QT_TRANSLATE_N_NOOP(
      "Utility",
      "%n hour(s)"
    ), (1 * 3600)], [QT_TRANSLATE_N_NOOP("Utility", "%n minute(s)"), (1 * 60)], [QT_TRANSLATE_N_NOOP(
      "Utility",
      "%n second(s)"
    ), 1], [nil, nil]]

    FS_CASE_PRESERVING_OVERRIDE = Utility.is_windows || Utility.is_mac
    def r_f_c1123_pattern_c
      return "ddd, dd MMM yyyy HH:mm:ss 'GMT'"
    end

    def dir_tag
      return "eu.opencloud.spaces.app"
    end

    def uuid_tag
      return "eu.opencloud.spaces.account-uuid"
    end

    def octets_to_string(octets)
      unless octets >= 0
        raise
      end

      using namespace FileSystem::SizeLiterals;
      precision = 0

      if octets >= 1073741824
        precision = 2
      elsif octets >= 1048576
        precision = 1
      end

      return QLocale.new.formatted_data_size(octets, precision, :data_size_traditional_format)
    end

    def platform
      return "Linux"
    end

    def user_agent_string
      return "Mozilla/5.0 (#{platform}) mirall/#{OCC::Version.display_string} (#{q_app.application_name}, #{QSysInfo.product_type}-#{QSysInfo.kernel_version} ClientArchitecture: #{QSysInfo.build_cpu_architecture} OsArchitecture: #{Utility.current_cpu_arch})".to_latin1
    end

    def free_disk_space(path)
      if statvfs64(path.to_local8_bit.data, stat) == 0
        return stat.f_bavail * stat.f_frsize
      end

      return -1
    end

    def compact_format_double(value, prec, unit)
      locale = QLocale.system
      dec_point = locale.decimal_point
      str = locale.to_string(value, "f", prec)

      while str.ends_with("0") || str.ends_with(dec_point)
        if str.ends_with(dec_point)
          str.chop(1)

          break
        end

        str.chop(1)
      end

      if !unit.is_empty
        str += (" " + unit)
      end

      return str
    end

    def escape(in_)
      return in_.to_html_escaped
    end

    def fs_case_preserving
      return FS_CASE_PRESERVING_OVERRIDE
    end

    def file_names_equal(_fn1, _fn2)
      fd1 = QDir.new(fn1)
      fd2 = QDir.new(fn2)
      a = fd1.canonical_path
      b = fd2.canonical_path

      if fs_case_preserving
        re = (
          !a.is_empty &&
          QString.compare(a, b, :case_insensitive) == 0
        )
      else
        re = !a.is_empty && QString.compare(a, b, :case_sensitive) == 0
      end

      return re
    end

    def q_date_time_from_time_t(t)
      return QDateTime.from_m_secs_since_epoch(t * 1000)
    end

    def q_date_time_to_time_t(t)
      return t.to_m_secs_since_epoch / 1000
    end

    def duration_to_descriptive_string2(msecs)
      p = 0

      while PERIODS[p + 1].name && msecs < PERIODS[p].msec
        p += 1
      end

      first_part = PERIODS[p].description(msecs / PERIODS[p].msec)

      if !PERIODS[p + 1].name
        return first_part
      end

      second_part_num = q_round(msecs.count % PERIODS[p].msec.count / PERIODS[p + 1].msec.count)

      if second_part_num == 0
        return first_part
      end

      return QCoreApplication.translate("Utility", "%1 %2").arg(first_part, PERIODS[p + 1].description(second_part_num))
    end

    def duration_to_descriptive_string1(msecs)
      p = 0

      while PERIODS[p + 1].name && msecs < PERIODS[p].msec
        p += 1
      end

      return PERIODS[p].description(q_round(msecs.count / PERIODS[p].msec.count))
    end

    def file_name_for_gui_use(f_name)
      if is_mac
        n = f_name

        return n.replace(":", "/")
      end

      return f_name
    end

    def normalize_etag(etag)
      if etag.is_empty
        return nil
      end

      un_quote = lambda do
        if etag.starts_with(") && etag.ends_with(")
          etag = etag.mid(1)
          etag.chop(1)
        end
      end

      if etag.starts_with("W/")
        etag = etag.mid(2)
      end

      un_quote.call
      gzip_suffix = "-gzip"

      if etag.ends_with(gzip_suffix)
        etag.chop(gzip_suffix.size)
      end

      un_quote.call

      return etag.to_string
    end

    def platform_name
      return QSysInfo.pretty_product_name
    end

    def crash
      a = nil
      a = 1
    end

    def time_ago_in_words(dt, from)
      if from.is_valid
        now = from
      else
        now = QDateTime.current_date_time_utc
      end

      if dt.days_to(now) > 0
        return QObject.tr("%n day(s) ago", "", dt.days_to(now))
      end

      secs = dt.secs_to(now)

      if secs < 0
        return QObject.tr("in the future")
      end

      if floor(secs / 3600.0) > 0
        hours = floor(secs / 3600.0)

        return QObject.tr("%n hour(s) ago", "", hours)
      end

      minutes = q_round(secs / 60.0)

      if minutes == 0
        if secs < 5
          return QObject.tr("now")
        else
          return QObject.tr("less than a minute ago")
        end
      end

      return QObject.tr("%n minute(s) ago", "", minutes)
    end

    def sort_filenames(file_names)
      collator = QCollator.new
      collator.set_numeric_mode(true)
      collator.set_case_sensitivity(:case_insensitive)
      std::sort(file_names.begin, file_names.end, collator)
    end

    def concat_url_path_items(items, delimiter)
      items.each do |item|
        while item.ends_with("/")
          item.chop(1)
        end
      end

      return items.join(delimiter)
    end

    def concat_url_path(url, concat_path, query_items)
      path = url.path

      if !concat_path.is_empty
        if path.ends_with("/") && concat_path.starts_with("/")
          path.chop(1)
        elsif !path.ends_with("/") && !concat_path.starts_with("/")
          path += "/"
        end

        path += concat_path
      end

      unless !path.contains("//")
        raise
      end

      unless url.query.is_empty
        raise
      end

      tmp_url = url
      tmp_url.set_path(path)
      tmp_url.set_query(query_items)

      return tmp_url
    end

    def url_equal(url1, url2)
      if url1.path.is_empty
        url1.set_path("/")
      end

      if url2.path.is_empty
        url2.set_path("/")
      end

      return url1.matches(url2, :strip_trailing_slash | :normalize_path_segments)
    end

    def make_conflict_file_name(_fn, dt, user)
      conflict_file_name = fn
      dot_location = conflict_file_name.last_index_of(".")

      if dot_location <= conflict_file_name.last_index_of("/") + 1
        dot_location = conflict_file_name.size
      end

      conflict_marker = " (conflicted copy "

      if !user.is_empty
        user_name = sanitize_for_file_name(user).replace("(", "_").replace(")", "_")
        conflict_marker += user_name + " "
      end

      conflict_marker += dt.to_string("yyyy-MM-dd hhmmss") + ")"
      conflict_file_name.insert(dot_location, conflict_marker)

      return conflict_file_name
    end

    def is_conflict_file(name)
      bname = name.mid(name.last_index_of("/") + 1)

      if bname.contains("_conflict-")
        return true
      end

      if bname.contains("(conflicted copy")
        return true
      end

      return false
    end

    def conflict_file_base_name_from_pattern(conflict_name)
      start_old = conflict_name.last_index_of("_conflict-")
      start_new = conflict_name.last_index_of("(conflicted copy")

      if start_new > 0 && conflict_name[start_new - 1] == " "
        start_new -= 1
      end

      tag_start = q_max(start_old, start_new)

      if tag_start == -1
        return ""
      end

      tag_end = conflict_name.size
      dot = conflict_name.last_index_of(".")

      if dot > tag_start
        tag_end = dot
      end

      if tag_start == start_new
        paren = conflict_name.index_of(")", tag_start)

        if paren != -1
          tag_end = paren + 1
        end
      end

      return conflict_name.left(tag_start) + conflict_name.mid(tag_end)
    end

    def sanitize_for_file_name(name)
      invalid = "/?<>\\:*|\""
      result = ""
      result.reserve(name.size)

      name.each do |c|
        if (
          !invalid.contains(c) &&
          c.category != :other_control &&
          c.category != :other_format
        )
          result.append(c)
        end
      end

      return result
    end

    def app_image_location
      unless Utility.running_in_app_image
        raise
      end

      value = q_environment_variable("APPIMAGE")

      return value
    end

    def running_in_app_image
      return q_environment_variable_is_set("APPIMAGE")
    end

    def parse_rfc1123_date(date)
      if !date.is_empty
        out = QDateTime.from_string(date, RFC1123PatternC())

        unless out.is_valid
          raise
        end

        out.set_time_zone(QTimeZone.utc)

        return out
      end

      return nil
    end

    def format_rfc1123_date(date)
      return date.to_utc.to_string(RFC1123PatternC())
    end

    def current_cpu_arch
      return QSysInfo.current_cpu_architecture
    end

    def mark_directory_as_sync_root(path, account_uuid)
      old_tag = get_directory_sync_root_markings(path)

      if (
        old_uuid == account_uuid &&
        old_tag == QCoreApplication.organization_domain
      )
        return
      end

      unless old_tag.is_empty
        raise
      end

      unless old_uuid.is_null
        raise
      end

      result1 = FileSystem::Tags.set(path, dir_tag, QCoreApplication.organization_domain)

      if !result1
        Log.warn("sync.utility") { "Failed to set tag on \#{path}: \#{result1.error()}" }

        return
      end

      result2 = FileSystem::Tags.set(path, uuid_tag, account_uuid.to_string)

      if !result2
        Log.warn("sync.utility") { "Failed to set tag on \#{path}: \#{result2.error()}" }

        return
      end
    end

    def get_directory_sync_root_markings(path)
      existing_dir_tag = FileSystem::Tags.get(path, dir_tag)
      existing_uuid_tag = FileSystem::Tags.get(path, uuid_tag)

      if existing_dir_tag.has_value && existing_uuid_tag.has_value
        return [existing_dir_tag.value, QUuid.from_string(existing_uuid_tag.value)]
      end

      return nil
    end

    def unmark_directory_as_sync_root(path)
      if QFileInfo.exists(path)
        if !FileSystem::Tags.remove(path, dir_tag)
          Log.warn("sync.utility") { "Failed to remove tag on #{path}" }

          unless false
            raise
          end
        end

        if !FileSystem::Tags.remove(path, uuid_tag)
          Log.warn("sync.utility") { "Failed to remove uuid tag on #{path}" }

          unless false
            raise
          end
        end
      end
    end
  end
end

def <<(debug, in_)
  save = QDebugStateSaver.new(debug)
  debug.nospace
  h = duration_cast < hours > (in_)
  min = duration_cast < minutes > (in_ -= h)
  s = duration_cast < seconds > (in_ -= min)
  ms = duration_cast < milliseconds > (in_ -= s)

  return debug << "duration(" << h.count << "h, " << min.count << "min, " << s.count << "s, " << ms.count << "ms)"
end
