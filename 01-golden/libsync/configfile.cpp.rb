#!/usr/bin/env ruby
#
# Copyright (C) by Klaas Freitag <freitag@owncloud.com>
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

require_relative "configfile"

require "qcoreapplication"
require_relative "common/asserts"
require_relative "common/utility"
require_relative "common/version"
require_relative "libsync/globalconfig"
require_relative "logger"

require_relative "creds/abstractcredentials"

require_relative "csync_exclude"

require "qdir"
require "qfile"
require "qfileinfo"
require "qloggingcategory"
require "qoperatingsystemversion"
require "qsettings"
require "qstandardpaths"

require "chrono"

include std::chrono_literals
include Qt::Literals::StringLiterals

module OCC
  class ConfigFile
    _CONF_DIR = ""
    DEFAULT_REMOTE_POLL_INTERVAL = 30
    def initialize
      QSettings.set_default_format(:ini_format)
    end

    def milliseconds_value(setting, key, default_value)
      return chrono::milliseconds(setting.value(key, default_value.count).to_long_long)
    end

    def log_http_c
      return "logHttp"
    end

    def remote_poll_interval_c
      return "remotePollInterval"
    end

    def full_local_discovery_interval_c
      return "fullLocalDiscoveryInterval"
    end

    def crash_reporter_c
      return "crashReporter"
    end

    def skip_update_check_c
      return "skipUpdateCheck"
    end

    def update_check_interval_c
      return "updateCheckInterval"
    end

    def update_channel_c
      return "updateChannel"
    end

    def ui_language_c
      return "uiLanguage"
    end

    def timeout_c
      return "timeout"
    end

    def automatic_log_dir_c
      return "logToTemporaryLogDir"
    end

    def number_of_logs_to_keep_c
      return "numberOfLogsToKeep"
    end

    def client_version_c
      return "clientVersion"
    end

    def use_upload_limit_c
      return "BWLimit/useUploadLimit"
    end

    def use_download_limit_c
      return "BWLimit/useDownloadLimit"
    end

    def upload_limit_c
      return "BWLimit/uploadLimit"
    end

    def download_limit_c
      return "BWLimit/downloadLimit"
    end

    def pause_sync_when_metered_c
      return "pauseWhenMetered"
    end

    def move_to_trash_c
      return "moveToTrash"
    end

    def issues_widget_filter_c
      return "issuesWidgetFilter"
    end

    def exclude_file_name_c
      return "sync-exclude.lst"
    end

    def set_conf_dir(value)
      dir_path = value

      if dir_path.is_empty
        return false
      end

      fi = QFileInfo.new(dir_path)

      if !fi.exists
        QDir.new.mkpath(dir_path)
        fi.set_file(dir_path)
      end

      if fi.exists && fi.is_dir
        dir_path = fi.absolute_file_path
        Log.info("sync.configfile") { "Using custom config dir  #{dir_path}" }
        @conf_dir = dir_path

        return true
      end

      return false
    end

    def issues_widget_filter
      settings = make_q_settings

      if settings.contains(issues_widget_filter_c)
        return settings.value(issues_widget_filter_c).to_string_list
      end

      return nil
    end

    def set_issues_widget_filter(checked)
      settings = make_q_settings
      settings.set_value(issues_widget_filter_c, checked)
      settings.sync
    end

    def timeout
      settings = make_q_settings
      val = settings.value(timeout_c).to_int

      if val
        return std::chrono::seconds(val)
      else
        return (5 * 60)
      end
    end

    def config_path
      if _CONF_DIR.is_empty
        if Utility.is_windows
          @conf_dir = QStandardPaths.writable_location(:app_data_location)
        else
          @conf_dir = QStandardPaths.writable_location(:app_config_location)
        end
      end

      dir = _CONF_DIR

      if !dir.ends_with("/")
        dir.append("/")
      end

      return dir
    end

    def exclude_file(scope)
      case scope
      when :user_scope
        return config_path + exclude_file_name_c
      when :system_scope
        return ConfigFile.default_exclude_file
      end

      raise
    end

    def default_exclude_file
      named = q_environment_variable("OPENCLOUD_SYNC_EXCLUDE_FILE")

      if named.is_empty
        return OPENCLOUD_SYNC_EXCLUDE_FILE
      else
        return named
      end
    end

    def backup
      base_file = config_file
      version_string = client_version_with_build_number_string

      if !version_string.is_empty
        version_string.prepend("_")
      end

      backup_file = "#{base_file}.backup_#{QDateTime.current_date_time.to_string("yyyyMMdd_HHmmss")}#{version_string}"

      if !QFile.exists(backup_file)
        f = QFile.new(base_file)
        f.copy(backup_file)
      end

      return backup_file
    end

    def config_file
      return "#{config_path}#{QCoreApplication.application_name.to_lower}.cfg"
    end

    def make_q_settings
      return [config_file, :ini_format]
    end

    def make_q_settings_pointer
      return QSettings.new(make_q_settings)
    end

    def exists
      return QFileInfo.exists(config_file)
    end

    def remote_poll_interval(default_val)
      settings = make_q_settings
      default_poll_interval = DEFAULT_REMOTE_POLL_INTERVAL

      if default_val > chrono::seconds(5)
        default_poll_interval = default_val
      end

      remote_interval = milliseconds_value(settings, remote_poll_interval_c, default_poll_interval)

      if remote_interval < chrono::seconds(5)
        remote_interval = default_poll_interval
        Log.warn("sync.configfile") { "Remote Interval is less than 5 seconds, reverting to #{remote_interval.count}" }
      end

      return remote_interval
    end

    def full_local_discovery_interval
      settings = make_q_settings

      return milliseconds_value(settings, full_local_discovery_interval_c, (1 * 3600))
    end

    def update_check_interval
      settings = make_q_settings
      default_interval = chrono::hours(10)
      interval = milliseconds_value(settings, update_check_interval_c, default_interval)
      min_interval = chrono::minutes(5)

      if interval < min_interval
        Log.warn("sync.configfile") { "Update check interval less than five minutes, resetting to 5 minutes" }
        interval = min_interval
      end

      return interval
    end

    def skip_update_check
      fallback = get_value(skip_update_check_c, false)

      return fallback.to_bool
    end

    def set_skip_update_check(skip)
      settings = make_q_settings
      settings.set_value(skip_update_check_c, QVariant.new(skip))
      settings.sync
    end

    def update_channel
      settings = make_q_settings

      if OCC::Version.is_beta
        return settings.value(update_channel_c, "stable").to_string
      else
        return settings.value(update_channel_c, "beta").to_string
      end
    end

    def set_update_channel(channel)
      settings = make_q_settings
      settings.set_value(update_channel_c, channel)
    end

    def ui_language
      settings = make_q_settings

      return settings.value(ui_language_c, "").to_string
    end

    def set_ui_language(ui_language)
      settings = make_q_settings
      settings.set_value(ui_language_c, ui_language)
    end

    def get_value(param, default_value)
      setting = make_q_settings.value(param)

      if !setting.is_valid
        return GlobalConfig.get_value(param, default_value)
      end

      return setting
    end

    def set_value(key, value)
      settings = make_q_settings
      settings.set_value(key, value)
    end

    def use_upload_limit
      return get_value(use_upload_limit_c, 0).to_int
    end

    def use_download_limit
      return get_value(use_download_limit_c, 0).to_int
    end

    def set_use_upload_limit(val)
      set_value(use_upload_limit_c, val)
    end

    def set_use_download_limit(val)
      set_value(use_download_limit_c, val)
    end

    def upload_limit
      return get_value(upload_limit_c, 10).to_int
    end

    def download_limit
      return get_value(download_limit_c, 80).to_int
    end

    def set_upload_limit(kbytes)
      set_value(upload_limit_c, kbytes)
    end

    def set_download_limit(kbytes)
      set_value(download_limit_c, kbytes)
    end

    def pause_sync_when_metered
      return get_value(pause_sync_when_metered_c, false).to_bool
    end

    def set_pause_sync_when_metered(is_checked)
      set_value(pause_sync_when_metered_c, is_checked)
    end

    def move_to_trash
      return false
    end

    def set_move_to_trash(is_checked)
      set_value(move_to_trash_c, is_checked)
    end

    def crash_reporter
      settings = make_q_settings

      return settings.value(crash_reporter_c, true).to_bool
    end

    def set_crash_reporter(enabled)
      settings = make_q_settings
      settings.set_value(crash_reporter_c, enabled)
    end

    def automatic_log_dir
      settings = make_q_settings

      return settings.value(automatic_log_dir_c, false).to_bool
    end

    def set_automatic_log_dir(enabled)
      settings = make_q_settings
      settings.set_value(automatic_log_dir_c, enabled)
    end

    def automatic_delete_old_logs
      settings = make_q_settings

      return settings.value(number_of_logs_to_keep_c).to_int
    end

    def set_automatic_delete_old_logs(number)
      settings = make_q_settings
      settings.set_value(number_of_logs_to_keep_c, number)
    end

    def configure_http_logging(enable)
      if enable == std::nullopt
        enable = log_http
      end

      settings = make_q_settings
      settings.set_value(log_http_c, enable.value)
      rule = "sync.httplogger=true"

      if enable.value
        Logger.instance.add_log_rule(rule)
      else
        Logger.instance.remove_log_rule(rule)
      end
    end

    def log_http
      settings = make_q_settings

      return settings.value(log_http_c, false).to_bool
    end

    def client_version_with_build_number_string
      settings = make_q_settings

      return settings.value(client_version_c, "").to_string
    end

    def set_client_version_with_build_number_string(version)
      settings = make_q_settings
      settings.set_value(client_version_c, version)
    end

    def setup_default_exclude_file_paths(excluded_files)
      cfg = ConfigFile.new
      system_list = cfg.exclude_file(:system_scope)
      Log.info("sync.configfile") { "Adding system ignore list to csync: #{system_list}" }
      excluded_files.add_exclude_file_path(system_list)
      user_list = cfg.exclude_file(:user_scope)

      if QFile.exists(user_list)
        Log.info("sync.configfile") { "Adding user defined ignore list to csync: #{user_list}" }
        excluded_files.add_exclude_file_path(user_list)
      end
    end
  end
end
