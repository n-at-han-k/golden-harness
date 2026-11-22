#!/usr/bin/env ruby
#
#
# Copyright (C) by Duncan Mac-Vicar P. <duncan@kde.org>
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

require "qtglobal"

require "qcoreapplication"

require_relative "accountmanager"
require_relative "accountstate"
require_relative "gui/folderman"
require_relative "gui/networkinformation"
require_relative "libsync/configfile"
require_relative "libsync/platform"

require_relative "common/version"
require_relative "libsync/logger"

require_relative "updater/updater"

require "qcommandlineparser"
require "qlibraryinfo"
require "qtimer"

require "iostream"

include Qt::Literals::StringLiterals
include std::chrono_literals
include OCC

module OCC
  CommandLineOptions = Struct.new(
    :show,
    :quit_instance,
    :log_dir,
    :log_file,
    :log_flush,
    :log_debug,
    :debug_mode,
    keyword_init: true
  )
  def display_help_text(t)
    Logger.instance.attache_to_console
    std::cout << q_utf8_printable(t) << std::endl
  end

  def parse_options(arguments)
    parser = QCommandLineParser.new
    description_text = ""
    description_text_stream = QTextStream.new(description_text)

    description_text_stream << QCoreApplication.translate(
      "CommandLine",
      "%1 version %2\r\nFile synchronization desktop utility."
    ).arg(
      QCoreApplication.application_name,
      OCC::Version.display_string
    ) << Qt.endl << Qt.endl << Qt.endl << QCoreApplication.translate(
      "CommandLine",
      "For more information, see %1",
      "link to homepage"
    ).arg("https://www.opencloud.eu")

    parser.set_application_description(description_text)
    help_option = parser.add_help_option
    version_option = parser.add_version_option

    add_option = lambda do |option|
      parser.add_option(option)

      return option
    end

    show_settings_legacy_option = QCommandLineOption.new("showsettings", "Hidden legacy option")
    show_settings_legacy_option.set_flags(:hidden_from_help)
    parser.add_option(show_settings_legacy_option)

    show_option = add_option.call([["s", "show"], QCoreApplication.translate(
      "CommandLine",
      "Start with the main window visible, or if it is already running, bring it to the front. By default, the client launches in the background."
    )])

    quit_instance_option = add_option.call([["q", "quit"], QCoreApplication.translate(
      "CommandLine",
      "Quit the running instance."
    )])

    log_file_option = add_option.call(["logfile", QCoreApplication.translate(
      "CommandLine",
      "Write log to file (use - to write to stdout)."
    ), "filename"])

    log_dir_option = add_option.call(["logdir", QCoreApplication.translate(
      "CommandLine",
      "Write each sync log output in a new file in folder."
    ), "name"])

    log_flush_option = add_option.call(["logflush", QCoreApplication.translate(
      "CommandLine",
      "Flush the log file after every write."
    )])

    log_debug_option = add_option.call(["logdebug", QCoreApplication.translate(
      "CommandLine",
      "Output debug-level messages in the log."
    )])

    debug_option = add_option.call(["debug", QCoreApplication.translate("CommandLine", "Enable debug mode.")])

    add_option.call(["cmd", QCoreApplication.translate(
      "CommandLine",
      "Forward all arguments to the cmd client. This argument must be the first."
    )])

    parser.process(arguments)
    out = CommandLineOptions.new

    if (
      parser.is_set(show_option) ||
      parser.is_set(show_settings_legacy_option)
    )
      out.show = true
    end

    if parser.is_set(quit_instance_option)
      out.quit_instance = true
    end

    if parser.is_set(log_file_option)
      out.log_file = parser.value(log_file_option)
    end

    if parser.is_set(log_dir_option)
      if parser.is_set(log_file_option)
        display_help_text(QCoreApplication.translate("CommandLine", "--logfile and --logdir are mutually exclusive"))
        std::exit(1)
      end

      out.log_dir = parser.value(log_dir_option)
    end

    if parser.is_set(log_flush_option)
      out.log_flush = true
    end

    if parser.is_set(log_debug_option)
      out.log_debug = true
    end

    if parser.is_set(debug_option)
      out.log_debug = true
      out.debug_mode = true
    end

    return out
  end

  def show_downgrade_dialog
    Log.warn("gui.main") {
      "#{QCoreApplication.translate(
        "version check",
        "Some settings were configured in newer versions of this client " \
        "and use features that are not available in this version"
      )}"
    }

    QTimer.single_shot(0, q_app, QCoreApplication.quit)
  end

  def check_client_version
    config_file = ConfigFile.new
    config_version = QVersionNumber.from_string(config_file.client_version_with_build_number_string)
    client_version = OCC::Version.version_with_build_number

    if config_version == client_version
      return true
    end

    if client_version.major_version < config_version.major_version
      show_downgrade_dialog

      return false
    end

    config_file.backup
    config_file.set_client_version_with_build_number_string(OCC::Version.version_with_build_number.to_string)

    return true
  end

  def setup_logging(options)
    logger = Logger.instance
    logger.install
    logger.set_log_flush(options.log_flush)

    if !options.log_dir.is_empty
      logger.set_log_dir(options.log_dir)
    end

    if !options.log_file.is_empty
      unless options.log_dir.is_empty
        raise
      end

      logger.set_log_file(options.log_file)
    end

    logger.set_log_debug(options.log_debug)

    Log.info("gui.main") {
      "################## #{QCoreApplication.application_name} locale: #{QLocale.system.name}" \
        "version: #{Version.display_string}"
    }

    Log.info("gui.main") { "Arguments: #{q_app.arguments}" }
  end

  def init(arguments)
    platform = Platform.create(:terminal)
    argc = 1
    name = "openvfs-rb"
    argv = [name, nil]
    app = QCoreApplication.new(argc, argv)
    app.set_application_version(Version.display_string)
    options = parse_options(arguments)

    if !check_client_version
      return -1
    end

    setup_logging(options)
    NetworkInformation.instance
    platform.set_application(app)
    folder_manager = FolderMan.create_instance

    if !AccountManager.instance.restore
      Log.error("gui.main") { "Could not read the account settings, quitting" }

      return -1
    end

    AccountManager.instance.accounts.each do |account_state|
      QObject.connect(
        account_state.data,
        AccountState.is_connected_changed,
        FolderMan.instance,
        FolderMan.slot_is_connected_changed
      )

      account_state.check_connectivity
    end

    if !FolderMan.instance.load_folders.has_value
      Log.error("gui.main") { "Database downgrade detected, quitting" }

      return -1
    end

    platform.start_services
    folder_manager.set_sync_enabled(true)

    return app.exec
  end
end
