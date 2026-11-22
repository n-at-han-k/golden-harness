/*
 * Copyright (C) by Erik Verbruggen <erik@verbruggen.consulting>
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

#include "platform_win.h"

#ifdef Q_OS_WIN
#include "common/utility_win.h"
#endif

#include <QGuiApplication>
#include <QLoggingCategory>

namespace OCC {

Q_LOGGING_CATEGORY(lcPlatform, "sync.platform.windows")

WinPlatform::WinPlatform(Type t)
    : Platform(t)
{
    QGuiApplication::setHighDpiScaleFactorRoundingPolicy(Qt::HighDpiScaleFactorRoundingPolicy::PassThrough);
}

WinPlatform::~WinPlatform()
{
}

void WinPlatform::setApplication(QCoreApplication *application)
{
    Platform::setApplication(application);
    // Ensure OpenSSL config file is only loaded from app directory
    const QString opensslConf = QCoreApplication::applicationDirPath() + QStringLiteral("/openssl.cnf");
    qputenv("OPENSSL_CONF", opensslConf.toLocal8Bit());
}

void OCC::WinPlatform::startServices()
{
}

} // namespace OCC
