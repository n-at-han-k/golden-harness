// SPDX-License-Identifier: GPL-2.0-or-later
// SPDX-FileCopyrightText: 2025 Hannah von Reth <h.vonreth@opencloud.eu>

#include "libsync/globalconfig.h"


#include <QCoreApplication>
#include <QSettings>
#include <QUrl>

using namespace OCC;

QUrl GlobalConfig::serverUrl()
{
    auto url = getValue("Wizard/ServerUrl").toUrl();
    if (url.isEmpty()) {
        return QUrl();
    }
    return url;
}

QVariant GlobalConfig::getValue(QAnyStringView param, const QVariant &defaultValue)
{
    static const QSettings systemSettings = {
#ifdef Q_OS_MAC
        QStringLiteral("/Library/Preferences/%1.plist").arg(QCoreApplication::organizationDomain()), QSettings::NativeFormat
#elif defined(Q_OS_UNIX)
        QStringLiteral("/etc/%1/%1.conf").arg(QCoreApplication::applicationName()), QSettings::NativeFormat
#elif defined(Q_OS_WIN)
        QStringLiteral(R"(HKEY_LOCAL_MACHINE\Software\%1\%2)")
            .arg(QCoreApplication::applicationName(), QCoreApplication::applicationName()),
        QSettings::NativeFormat
#else
#error "Unsupported platform"
#endif
    };
    return systemSettings.value(param, defaultValue);
}

#ifdef Q_OS_WIN
QVariant GlobalConfig::getPolicySetting(QAnyStringView setting, const QVariant &defaultValue)
{
    // check for policies first and return immediately if a value is found.
    QVariant out = QSettings(QStringLiteral(R"(HKEY_CURRENT_USER\Software\Policies\%1\%2)")
                                 .arg(QCoreApplication::applicationName(), QCoreApplication::applicationName()),
        QSettings::NativeFormat)
                       .value(setting);

    if (!out.isValid()) {
        out = QSettings(QStringLiteral(R"(HKEY_LOCAL_MACHINE\Software\Policies\%1\%2)")
                            .arg(QCoreApplication::applicationName(), QCoreApplication::applicationName()),
            QSettings::NativeFormat)
                  .value(setting, defaultValue);
    }
    return out;
}
#endif
