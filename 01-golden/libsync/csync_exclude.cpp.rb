#!/usr/bin/env ruby
#
# libcsync -- a library to sync a directory with another
#
# Copyright (c) 2008-2013 by Andreas Schneider <asn@cryptomilk.org>
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

require_relative "libsync/csync_exclude"

require_relative "common/filesystembase"
require_relative "common/utility"
require_relative "common/version"

require "qfile"
require "qfileinfo"
require "qstring"

include Qt::Literals::StringLiterals
include OCC

class ExcludedFiles
  def initialize
    @client_version = OCC::Version.version
    @wildcards_match_slash = Utility.is_windows
  end

  def csync_exclude_expand_escapes(input)
    o = 0
    line = input.data
    len = input.size
    i = 0

    while i < len
      if line[i] == "\\"
        case line[i + 1]
        when "'"
          line[o] = "'"
          o += 1
        when "\""
          line[o] = "\""
          o += 1
        when "?"
          line[o] = "?"
          o += 1
        when "#"
          line[o] = "#"
          o += 1
        when "a"
          line[o] = "\a"
          o += 1
        when "b"
          line[o] = "\b"
          o += 1
        when "f"
          line[o] = "\f"
          o += 1
        when "n"
          line[o] = "\n"
          o += 1
        when "r"
          line[o] = "\r"
          o += 1
        when "t"
          line[o] = "\t"
          o += 1
        when "v"
          line[o] = "\v"
          o += 1
        else
          line[o] = line[i]
          o += 1
          line[o] = line[i + 1]
          o += 1
        end

        i += 1
      else
        line[o] = line[i]
        o += 1
      end

      i += 1
    end

    input.resize(o)
  end

  def _csync_excluded_common(path, exclude_conflict_files)
    bname = path
    last_slash = path.last_index_of("/")

    if last_slash >= 0
      bname = path.mid(last_slash + 1)
    end

    blen = bname.size

    if blen > 254
      return CSYNC_FILE_EXCLUDE_LONG_FILENAME
    end

    if (
      exclude_conflict_files &&
      OCC::Utility.is_conflict_file(path)
    )
      return CSYNC_FILE_EXCLUDE_CONFLICT
    end

    return CSYNC_NOT_EXCLUDED
  end

  def finalize
  end

  def add_exclude_file_path(path)
    @exclude_files.insert(path)
  end

  def set_exclude_conflict_files(onoff)
    @exclude_conflict_files = onoff
  end

  def add_manual_exclude(expr)
    @manual_excludes.append(expr)
    @all_excludes.append(expr)
    prepare
  end

  def clear_manual_excludes
    @manual_excludes.clear
    reload_exclude_files
  end

  def set_wildcards_match_slash(onoff)
    @wildcards_match_slash = onoff
    prepare
  end

  def set_client_version(version)
    @client_version = version
  end

  def reload_exclude_files
    @all_excludes.clear
    success = true

    @exclude_files.each do |file|
      f = QFile.new(file)

      if !f.open(:read_only)
        success = false

        next
      end

      while !f.at_end
        line = f.read_line.trimmed

        if line.starts_with("#!version")
          if !version_directive_keep_next_line(line)
            f.read_line
          end
        end

        if line.is_empty || line.starts_with("#")
          next
        end

        csync_exclude_expand_escapes(line)
        @all_excludes.append(QString.from_utf8(line))
      end
    end

    @all_excludes.append(@manual_excludes)
    prepare

    return success
  end

  def version_directive_keep_next_line(directive)
    if !directive.starts_with("#!version")
      return true
    end

    args = directive.split(" ")

    if args.size != 3
      return true
    end

    op = args[1]
    arg_versions = args[2].split(".")

    if arg_versions.size != 3
      return true
    end

    arg_version = QVersionNumber.new(arg_versions[0].to_int, arg_versions[1].to_int, arg_versions[2].to_int)

    if op == "<="
      return @client_version <= arg_version
    end

    if op == "<"
      return @client_version < arg_version
    end

    if op == ">"
      return @client_version > arg_version
    end

    if op == ">="
      return @client_version >= arg_version
    end

    if op == "=="
      return @client_version == arg_version
    end

    return true
  end

  def is_excluded(file_path, base_path, exclude_hidden)
    unless !file_path.is_empty
      raise
    end

    unless !base_path.is_empty
      raise
    end

    is_child = FileSystem.is_child_path_of2(file_path, base_path)

    if is_child == :is_no_child
      return true
    end

    if is_child & :is_equal
      return false
    end

    file_info = QFileInfo.new(file_path.to_string)

    if !file_info.exists
      if exclude_hidden && file_info.file_name.starts_with(".")
        return true
      end

      return is_excluded(file_info.path, base_path, exclude_hidden)
    end

    if exclude_hidden
      fi = file_info

      while fi.file_path.size > base_path.size
        if fi.is_hidden
          return true
        end

        fi = QFileInfo.new(fi.path)
      end
    end

    type = :item_type_file

    if file_info.is_dir
      type = :item_type_directory
    end

    return is_excluded_remote(file_path, base_path, exclude_hidden, type)
  end

  def is_excluded_remote(file_path, base_path, exclude_hidden, type)
    unless !file_path.is_empty
      raise
    end

    unless !base_path.is_empty
      raise
    end

    is_child = FileSystem.is_child_path_of2(file_path, base_path)

    if is_child == :is_no_child
      return true
    end

    if is_child & :is_equal
      return false
    end

    relative_path = file_path.mid(base_path.size)

    unless !relative_path.is_empty
      raise
    end

    if relative_path.ends_with("/")
      relative_path.chop(1)
    end

    if exclude_hidden
      if (
        relative_path.starts_with(".") ||
        relative_path.contains("/.")
      )
        return true
      end
    end

    return full_pattern_match(relative_path, type) != CSYNC_NOT_EXCLUDED
  end

  def traversal_pattern_match(path, filetype)
    match = _csync_excluded_common(path, @exclude_conflict_files)

    if match != CSYNC_NOT_EXCLUDED
      return match
    end

    if @all_excludes.is_empty
      return CSYNC_NOT_EXCLUDED
    end

    bname_str = path
    last_slash = path.last_index_of("/")

    if last_slash >= 0
      bname_str = path.mid(last_slash + 1)
    end

    m = QRegularExpressionMatch.new

    if filetype == :item_type_directory
      m = @bname_traversal_regex_dir.match_view(bname_str)
    else
      m = @bname_traversal_regex_file.match_view(bname_str)
    end

    if !m.has_match
      return CSYNC_NOT_EXCLUDED
    end

    if m.captured_start("exclude") != -1
      return CSYNC_FILE_EXCLUDE_LIST
    elsif m.captured_start("excluderemove") != -1
      return CSYNC_FILE_SILENTLY_EXCLUDED
    end

    path_str = path

    if filetype == :item_type_directory
      m = @full_traversal_regex_dir.match_view(path_str)
    else
      m = @full_traversal_regex_file.match_view(path_str)
    end

    if m.has_match
      if m.captured_start("exclude") != -1
        return CSYNC_FILE_EXCLUDE_LIST
      elsif m.captured_start("excluderemove") != -1
        return CSYNC_FILE_SILENTLY_EXCLUDED
      end
    end

    return CSYNC_NOT_EXCLUDED
  end

  def full_pattern_match(p, filetype)
    match = _csync_excluded_common(p, @exclude_conflict_files)

    if match != CSYNC_NOT_EXCLUDED
      return match
    end

    if @all_excludes.is_empty
      return CSYNC_NOT_EXCLUDED
    end

    m = QRegularExpressionMatch.new

    if filetype == :item_type_directory
      m = @full_regex_dir.match_view(p)
    else
      m = @full_regex_file.match_view(p)
    end

    if m.has_match
      if m.captured_start("exclude") != -1
        return CSYNC_FILE_EXCLUDE_LIST
      elsif m.captured_start("excluderemove") != -1
        return CSYNC_FILE_SILENTLY_EXCLUDED
      end
    end

    return CSYNC_NOT_EXCLUDED
  end

  def convert_to_regexp_syntax(exclude, wildcards_match_slash)
    regex = ""
    i = 0
    chars_to_escape = 0

    flush = lambda do
      regex.append(QRegularExpression.escape(exclude.mid(i - chars_to_escape, chars_to_escape)))
      chars_to_escape = 0
    end

    len = exclude.size

    while i < len
      case exclude[i].unicode
      when "*"
        flush.call

        if wildcards_match_slash
          regex.append(".*")
        else
          regex.append("[^/]*")
        end
      when "?"
        flush.call

        if wildcards_match_slash
          regex.append(".")
        else
          regex.append("[^/]")
        end
      when "["
        flush.call
        j = i + 1

        while j < len
          if exclude[j] == "]"
            break
          end

          if j != len - 1 && exclude[j] == "\\" && exclude[j + 1] == "]"
            j += 1
          end

          j += 1
        end

        if j == len
          regex.append("\\[")
        else
          bracket_expr = exclude.mid(i, j - i + 1)

          if bracket_expr.starts_with("[!")
            bracket_expr[1] = "^"
          end

          regex.append(bracket_expr)
          i = j
        end
      when "\\"
        flush.call

        if i == len - 1
          regex.append("\\\\")
        else
          case exclude[i + 1].unicode
          when "*", "?", "[", "\\"
            regex.append(QRegularExpression.escape(exclude.mid(i + 1, 1)))
          else
            chars_to_escape += 2
          end

          i += 1
        end
      else
        chars_to_escape += 1
      end

      i += 1
    end

    flush.call

    return regex
  end

  def extract_bname_trigger(exclude, wildcards_match_slash)
    pattern = exclude.mid(exclude.last_index_of("/") + 1)

    if !wildcards_match_slash
      return pattern
    end

    is_wildcard = lambda do |c|
      return c == "*" || c == "?"
    end

    i = pattern.size - 1

    while i >= 0 && is_wildcard.call(pattern[i])
      i -= 1
    end

    while i >= 0 && !is_wildcard.call(pattern[i])
      i -= 1
    end

    pattern = pattern.mid(i + 1)

    if i >= 0
      pattern.prepend("*")
    end

    return pattern
  end

  def prepare
    full_file_dir_keep = ""
    full_file_dir_remove = ""
    full_dir_keep = ""
    full_dir_remove = ""
    bname_file_dir_keep = ""
    bname_file_dir_remove = ""
    bname_dir_keep = ""
    bname_dir_remove = ""
    bname_trigger_file_dir = ""
    bname_trigger_dir = ""

    regex_append = lambda do |file_dir_pattern, dir_pattern, append_me, dir_only|
      if dir_only
        pattern = dir_pattern
      else
        pattern = file_dir_pattern
      end

      if !pattern.is_empty
        pattern.append("|")
      end

      pattern.append(append_me)
    end

    @all_excludes.each do |exclude|
      if exclude[0] == "\n"
        next
      end

      if exclude[0] == "\r"
        next
      end

      match_dir_only = exclude.ends_with("/")

      if match_dir_only
        exclude = exclude.left(exclude.size - 1)
      end

      remove_excluded = exclude[0] == "]"

      if remove_excluded
        exclude = exclude.mid(1)
      end

      full_path = exclude.contains("/")

      if remove_excluded
        bname_file_dir = bname_file_dir_remove
      else
        bname_file_dir = bname_file_dir_keep
      end

      if remove_excluded
        bname_dir = bname_dir_remove
      else
        bname_dir = bname_dir_keep
      end

      if remove_excluded
        full_file_dir = full_file_dir_remove
      else
        full_file_dir = full_file_dir_keep
      end

      if remove_excluded
        full_dir = full_dir_remove
      else
        full_dir = full_dir_keep
      end

      regex_exclude = convert_to_regexp_syntax(exclude, @wildcards_match_slash)

      if !full_path
        regex_append.call(bname_file_dir, bname_dir, regex_exclude, match_dir_only)
      else
        regex_append.call(full_file_dir, full_dir, regex_exclude, match_dir_only)
        bname_exclude = extract_bname_trigger(exclude, @wildcards_match_slash)
        regex_bname = convert_to_regexp_syntax(bname_exclude, true)
        regex_append.call(bname_trigger_file_dir, bname_trigger_dir, regex_bname, match_dir_only)
      end
    end

    empty_match_nothing = lambda do |pattern|
      if pattern.is_empty
        pattern = "a^"
      end
    end

    empty_match_nothing.call(full_file_dir_keep)
    empty_match_nothing.call(full_file_dir_remove)
    empty_match_nothing.call(full_dir_keep)
    empty_match_nothing.call(full_dir_remove)
    empty_match_nothing.call(bname_file_dir_keep)
    empty_match_nothing.call(bname_file_dir_remove)
    empty_match_nothing.call(bname_dir_keep)
    empty_match_nothing.call(bname_dir_remove)
    empty_match_nothing.call(bname_trigger_file_dir)
    empty_match_nothing.call(bname_trigger_dir)

    @bname_traversal_regex_file.set_pattern(
      "^(?P<exclude>#{bname_file_dir_keep})$|" \
      "^(?P<excluderemove>#{bname_file_dir_remove})$|" \
      "^(?P<trigger>#{bname_trigger_file_dir})$"
    )

    @bname_traversal_regex_dir.set_pattern(
      "^(?P<exclude>#{bname_file_dir_keep}|#{bname_dir_keep})$|" \
      "^(?P<excluderemove>#{bname_file_dir_remove}|#{bname_dir_remove})$|" \
      "^(?P<trigger>#{bname_trigger_file_dir}|#{bname_trigger_dir})$"
    )

    @full_traversal_regex_file.set_pattern(
      "^(?P<exclude>#{full_file_dir_keep})(?:$|/)" \
      "|" \
      "^(?P<excluderemove>#{full_file_dir_remove})(?:$|/)"
    )

    @full_traversal_regex_dir.set_pattern(
      "^(?P<exclude>#{full_file_dir_keep}|#{full_dir_keep})(?:$|/)" \
      "|" \
      "^(?P<excluderemove>#{full_file_dir_remove}|#{full_dir_remove})(?:$|/)"
    )

    @full_regex_file.set_pattern(
      "(?P<exclude>" \
      "^(?:#{full_file_dir_keep})(?:$|/)|" \
      "(?:^|/)(?:#{bname_file_dir_keep})(?:$|/)|" \
      "(?:^|/)(?:#{bname_dir_keep})/)" \
      "|" \
      "(?P<excluderemove>" \
      "^(?:#{full_file_dir_remove})(?:$|/)|" \
      "(?:^|/)(?:#{bname_file_dir_remove})(?:$|/)|" \
      "(?:^|/)(?:#{bname_dir_remove})/)"
    )

    @full_regex_dir.set_pattern(
      "(?P<exclude>" \
      "^(?:#{full_file_dir_keep}|#{full_dir_keep})(?:$|/)|" \
      "(?:^|/)(?:#{bname_file_dir_keep}|#{bname_dir_keep})(?:$|/))" \
      "|" \
      "(?P<excluderemove>" \
      "^(?:#{full_file_dir_remove}|#{full_dir_remove})(?:$|/)|" \
      "(?:^|/)(?:#{bname_file_dir_remove}|#{bname_dir_remove})(?:$|/))"
    )

    pattern_options = :no_pattern_option

    if OCC::Utility.fs_case_preserving
      pattern_options |= :case_insensitive_option
    end

    @bname_traversal_regex_file.set_pattern_options(pattern_options)
    @bname_traversal_regex_file.optimize
    @bname_traversal_regex_dir.set_pattern_options(pattern_options)
    @bname_traversal_regex_dir.optimize
    @full_traversal_regex_file.set_pattern_options(pattern_options)
    @full_traversal_regex_file.optimize
    @full_traversal_regex_dir.set_pattern_options(pattern_options)
    @full_traversal_regex_dir.optimize
    @full_regex_file.set_pattern_options(pattern_options)
    @full_regex_file.optimize
    @full_regex_dir.set_pattern_options(pattern_options)
    @full_regex_dir.optimize
  end
end
