/*
 *
 * Copyright (C) by Duncan Mac-Vicar P. <duncan@kde.org>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
 * or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
 * for more details.
 */
#include <QtGlobal>

#include <QCoreApplication>

#include "accountmanager.h"
#include "accountstate.h"
#include "gui/folderman.h"
#include "gui/networkinformation.h"
#include "libsync/configfile.h"
#include "libsync/platform.h"

#include "common/version.h"
#include "libsync/logger.h"


#ifdef WITH_AUTO_UPDATER
#include "updater/updater.h"
#endif

#include <QCommandLineParser>
#include <QLibraryInfo>
#include <QTimer>
#ifdef Q_OS_WIN
#include <qt_windows.h>
#endif

#include <iostream>

using namespace Qt::Literals::StringLiterals;
using namespace std::chrono_literals;

using namespace OCC;

Q_LOGGING_CATEGORY(lcMain, "gui.main", QtInfoMsg)

namespace {
inline auto msgParseOptionsC()
{
    return QStringLiteral("MSG_PARSEOPTIONS:");
}

// Helpers for displaying messages. Note that there is probably no console on Windows.
void displayHelpText(const QString &t)
{
    Logger::instance()->attacheToConsole();
    std::cout << qUtf8Printable(t) << std::endl;
}

struct CommandLineOptions
{
    bool show = false;
    bool quitInstance = false;

    QString logDir;
    QString logFile;
    bool logFlush = false;
    bool logDebug = false;

    bool debugMode = false;
};

CommandLineOptions parseOptions(const QStringList &arguments)
{
    QCommandLineParser parser;

    QString descriptionText;
    QTextStream descriptionTextStream(&descriptionText);

    descriptionTextStream
        << QCoreApplication::translate("CommandLine", "%1 version %2\r\nFile synchronization desktop utility.")
               .arg(QCoreApplication::applicationName(), OCC::Version::displayString())
        << Qt::endl
        << Qt::endl
        << Qt::endl
        << QCoreApplication::translate("CommandLine", "For more information, see %1", "link to homepage").arg(QStringLiteral("https://www.opencloud.eu"));

    parser.setApplicationDescription(descriptionText);

    auto helpOption = parser.addHelpOption();
    auto versionOption = parser.addVersionOption();

    // this little snippet saves a few lines below
    auto addOption = [&parser](const QCommandLineOption &option) {
        parser.addOption(option);
        return option;
    };

    auto showSettingsLegacyOption = QCommandLineOption{{QStringLiteral("showsettings")}, QStringLiteral("Hidden legacy option")};
    showSettingsLegacyOption.setFlags(QCommandLineOption::HiddenFromHelp);
    parser.addOption(showSettingsLegacyOption);

    auto showOption = addOption({{QStringLiteral("s"), QStringLiteral("show")},
        QCoreApplication::translate("CommandLine",
            "Start with the main window visible, or if it is already running, bring it to the front. By default, the client launches in the background.")});
    auto quitInstanceOption = addOption({{QStringLiteral("q"), QStringLiteral("quit")}, QCoreApplication::translate("CommandLine", "Quit the running instance.")});
    auto logFileOption = addOption(
        {QStringLiteral("logfile"), QCoreApplication::translate("CommandLine", "Write log to file (use - to write to stdout)."), QStringLiteral("filename")});
    auto logDirOption = addOption(
        {QStringLiteral("logdir"), QCoreApplication::translate("CommandLine", "Write each sync log output in a new file in folder."), QStringLiteral("name")});
    auto logFlushOption = addOption({QStringLiteral("logflush"), QCoreApplication::translate("CommandLine", "Flush the log file after every write.")});
    auto logDebugOption = addOption({QStringLiteral("logdebug"), QCoreApplication::translate("CommandLine", "Output debug-level messages in the log.")});
    auto debugOption = addOption({QStringLiteral("debug"), QCoreApplication::translate("CommandLine", "Enable debug mode.")});
    addOption({QStringLiteral("cmd"), QCoreApplication::translate("CommandLine", "Forward all arguments to the cmd client. This argument must be the first.")});

    parser.process(arguments);

    CommandLineOptions out;
    if (parser.isSet(showOption) || parser.isSet(showSettingsLegacyOption)) {
        out.show = true;
    }
    if (parser.isSet(quitInstanceOption)) {
        out.quitInstance = true;
    }
    if (parser.isSet(logFileOption)) {
        out.logFile = parser.value(logFileOption);
    }
    if (parser.isSet(logDirOption)) {
        if (parser.isSet(logFileOption)) {
            displayHelpText(QCoreApplication::translate("CommandLine", "--logfile and --logdir are mutually exclusive"));
            std::exit(1);
        }
        out.logDir = parser.value(logDirOption);
    }
    if (parser.isSet(logFlushOption)) {
        out.logFlush = true;
    }
    if (parser.isSet(logDebugOption)) {
        out.logDebug = true;
    }
    if (parser.isSet(debugOption)) {
        out.logDebug = true;
        out.debugMode = true;
    }

    return out;
}

void showDowngradeDialog()
{
    qCWarning(lcMain) << QCoreApplication::translate("version check",
        "Some settings were configured in newer versions of this client "
        "and use features that are not available in this version");
    QTimer::singleShot(0, qApp, &QCoreApplication::quit);
}

/**
 * Check if the last version used to write the config file differs from the current version.
 * If the current version is newer, update the config file with our current version. If the
 * current version is older, refuse to do anything: this is a downgrade, and it is too risky to
 * assume that things might work "just fine".
 */
bool checkClientVersion()
{
    ConfigFile configFile;

    // Did the client version change?
    // (The client version is adjusted further down)
    auto configVersion = QVersionNumber::fromString(configFile.clientVersionWithBuildNumberString());
    auto clientVersion = OCC::Version::versionWithBuildNumber();

    if (configVersion == clientVersion) {
        // no config backup needed
        return true;
    }

    // We allow downgrades as long as the major version stays the same.
    if (clientVersion.majorVersion() < configVersion.majorVersion()) {
        // We refuse to downgrade, too much can go wrong.
        showDowngradeDialog();
        return false;
    }

    // We're okay to continue. The settings will be updated in other parts, but here we bump the
    // version we store in the config file.
    configFile.backup();
    configFile.setClientVersionWithBuildNumberString(OCC::Version::versionWithBuildNumber().toString());
    return true;
}

void setupLogging(const CommandLineOptions &options)
{
    // might be called from second instance
    auto logger = Logger::instance();
    logger->install();
    // call setLogFlush first, other log settings might already imply flushing
    // so setting it false in the end will have undesired results.
    logger->setLogFlush(options.logFlush);

    if (!options.logDir.isEmpty()) {
        logger->setLogDir(options.logDir);
    }
    if (!options.logFile.isEmpty()) {
        Q_ASSERT(options.logDir.isEmpty());
        logger->setLogFile(options.logFile);
    }
    logger->setLogDebug(options.logDebug);

    qCInfo(lcMain) << u"##################" << QCoreApplication::applicationName() << u"locale:" << QLocale::system().name()
                   << u"version:" << Version::displayString();
    qCInfo(lcMain) << u"Arguments:" << qApp->arguments();
}

} // Anonymous namespace

namespace OCC {
int init(const QStringList &arguments)
{
    {
        // Create a `Platform` instance so it can set-up/tear-down stuff for us, and do any
        // initialisation that needs to be done before creating a QApplication
        const auto platform = Platform::create(Platform::Type::Terminal);

        // Create the (Q)Application instance:
        static int argc = 1;
        static char name[] = "openvfs-rb";
        static char *argv[] = {name, nullptr};
        QCoreApplication app(argc, argv);
        app.setApplicationVersion(Version::displayString());

        // parse the arguments before we handle singleApplication
        // errors and help/version need to be handled in this instance
        const auto options = parseOptions(arguments);

        // Check if the user upgraded or downgraded. We do this as early as possible, to detect
        // a possible downgrade.
        if (!checkClientVersion()) {
            return -1;
        }

        setupLogging(options);
        NetworkInformation::instance(); //

        platform->setApplication(&app);

        auto folderManager = FolderMan::createInstance();

        if (!AccountManager::instance()->restore()) {
            qCCritical(lcMain) << u"Could not read the account settings, quitting";
            return -1;
        }

        // The UI's Application object normally connects restored accounts to FolderMan and starts
        // their connectivity checks. The headless bootstrap has to do both here.
        for (const auto &accountState : AccountManager::instance()->accounts()) {
            QObject::connect(accountState.data(), &AccountState::isConnectedChanged, FolderMan::instance(), &FolderMan::slotIsConnectedChanged);
            accountState->checkConnectivity();
        }

        // Setup the folders. This includes a downgrade-detection, in which case the return value
        // is empty. Note that the value 0 (zero) is a valid return value (non-empty), in which case
        // the dialog is not shown.
        if (!FolderMan::instance()->loadFolders().has_value()) {
            // Empty return value: there was a downgrade detected on one of the databases
            qCCritical(lcMain) << u"Database downgrade detected, quitting";
            return -1;
        }

        platform->startServices();

        // Enable syncing. We cannot do this earlier, because the UI needs to be set up in order to
        // show sync errors. We also want to wait for the auto-updater to finish, in case it needs
        // to install an update.
        folderManager->setSyncEnabled(true);

        return app.exec();
    }
}
} // namespace OCC
