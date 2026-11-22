/*
 * Copyright (C) by Dominik Schmidt <dev@dominik-schmidt.de>
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

#pragma once

#include "common/syncfilestatus.h"
#include "common/syncjournalfilerecord.h"
#include "libsync/accountfwd.h"
#include "syncfileitem.h"

#if defined(Q_OS_MAC)
#include "socketapisocket_mac.h"
#else
#include <QLocalServer>
using SocketApiServer = QLocalServer;
using SocketApiSocket = QLocalSocket;
#endif

class QUrl;
class QLocalSocket;

namespace OCC {

class SyncFileStatus;
class Folder;
class SocketListener;
class SocketApiJob;
class SocketApiJobV2;

Q_DECLARE_LOGGING_CATEGORY(lcSocketApi)

/**
 * @brief The SocketApi class
 * @ingroup gui
 */
class SocketApi : public QObject
{
    Q_OBJECT

public:
    explicit SocketApi(QObject *parent = nullptr);
    ~SocketApi() override;

    void startShellIntegration();

private Q_SLOTS:
    void slotNewConnection();
    void slotReadSocket();

private:
    // Helper structure for getting information on a file
    // based on its local path - used for nearly all remote
    // actions.
    struct FileData
    {
        static FileData get(const QString &localFile);

        Folder *folder = nullptr;
        // Absolute path of the file locally. (May be a virtual file)
        QString localPath;
        // Relative path of the file locally, as in the DB. (May be a virtual file)
        QString folderRelativePath;

        bool isSyncFolder() const;

        bool isValid() const;
    };

    Q_INVOKABLE void command_VERSION(const QString &argument, SocketListener *listener);

    Q_INVOKABLE void command_V2_HYDRATE_FILE(const QSharedPointer<SocketApiJobV2> &job) const;

    QString _socketPath;
    QMap<SocketApiSocket *, QSharedPointer<SocketListener>> _listeners;
    SocketApiServer _localServer;
};
}
