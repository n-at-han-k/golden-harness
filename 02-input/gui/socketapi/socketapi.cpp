/*
 * Copyright (C) by Dominik Schmidt <dev@dominik-schmidt.de>
 * Copyright (C) by Klaas Freitag <freitag@owncloud.com>
 * Copyright (C) by Roeland Jago Douma <roeland@famdouma.nl>
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

#include "socketapi.h"
#include "socketapi_p.h"


#include "accountmanager.h"
#include "common/asserts.h"
#include "common/depreaction.h"
#include "common/syncjournalfilerecord.h"
#include "common/version.h"
#include "filesystem.h"
#include "folder.h"
#include "folderman.h"
#include "guiutility.h"
#include "syncengine.h"
#include "syncfileitem.h"
#include "vfs/hydrationjob.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QLocalSocket>
#include <QMetaMethod>
#include <QMetaObject>
#include <QScopedPointer>
#include <QUrl>
#include <array>


#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>


#ifdef Q_OS_MAC
#endif


// This is the version that is returned when the client asks for the VERSION.
// The first number should be changed if there is an incompatible change that breaks old clients.
// The second number should be changed when there are new features.
#define MIRALL_SOCKET_API_VERSION "1.1"

namespace OCC {

Q_LOGGING_CATEGORY(lcSocketApi, "gui.socketapi", QtInfoMsg)

void SocketListener::sendMessage(const QString &message, bool doWait) const
{
    if (!socket) {
        qCInfo(lcSocketApi) << u"Not sending message to dead socket:" << message;
        return;
    }

    qCInfo(lcSocketApi) << u"Sending SocketAPI message -->" << message << u"to" << socket;
    QString localMessage = message;
    if (!localMessage.endsWith(QLatin1Char('\n'))) {
        localMessage.append(QLatin1Char('\n'));
    }

    QByteArray bytesToSend = localMessage.toUtf8();
    qint64 sent = socket->write(bytesToSend);
    if (doWait) {
        socket->waitForBytesWritten(1000);
    }
    if (sent != bytesToSend.length()) {
        qCWarning(lcSocketApi) << u"Could not send all data on socket for " << localMessage;
    }
}

SocketApi::SocketApi(QObject *parent)
    : QObject(parent)
{
    qRegisterMetaType<SocketListener *>("SocketListener*");
    qRegisterMetaType<QSharedPointer<SocketApiJob>>("QSharedPointer<SocketApiJob>");
    qRegisterMetaType<QSharedPointer<SocketApiJobV2>>("QSharedPointer<SocketApiJobV2>");

    _socketPath = Utility::socketApiSocketPath();

    // Remove any old socket that might be lying around:
    SocketApiServer::removeServer(_socketPath);

    // Create the socket path:
    if (!Utility::isMac()) {
        // Not on macOS: there the directory is there, and created for us by the sandboxing
        // environment, because we belong to an App Group.
        QFileInfo info(_socketPath);
        if (!info.dir().exists()) {
            bool result = info.dir().mkpath(QStringLiteral("."));
            qCDebug(lcSocketApi) << u"creating" << info.dir().path() << result;
            if (result) {
                QFile::setPermissions(_socketPath, QFile::Permissions(QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner));
            }
        }
    }

    // Wire up the server instance to us, so we can accept new connections:
    connect(&_localServer, &SocketApiServer::newConnection, this, &SocketApi::slotNewConnection);
}

SocketApi::~SocketApi()
{
    qCDebug(lcSocketApi) << u"dtor";
    _localServer.close();
    // All remaining sockets will be destroyed with _localServer, their parent
    OC_ASSERT(_listeners.isEmpty() || _listeners.first()->socket->parent() == &_localServer);
    _listeners.clear();
}

void SocketApi::startShellIntegration()
{
    // Start listeneing:
    if (_localServer.listen(_socketPath)) {
        qCInfo(lcSocketApi) << u"server started, listening at " << _socketPath;
    } else {
        qCWarning(lcSocketApi) << u"can't start server" << _socketPath;
    }

    // Now we're ready to start the native shell integration:
    Utility::startShellIntegration();
}

void SocketApi::slotNewConnection()
{
    // Note that on macOS this is not actually a line-based QIODevice, it's a SocketApiSocket which is our
    // custom message based macOS IPC.
    SocketApiSocket *socket = _localServer.nextPendingConnection();

    if (!socket) {
        return;
    }
    qCInfo(lcSocketApi) << u"New connection" << socket;
    connect(socket, &SocketApiSocket::readyRead, this, &SocketApi::slotReadSocket);
    connect(socket, &SocketApiSocket::disconnected, this, [socket] {
        qCInfo(lcSocketApi) << u"Lost connection " << socket;
        // will trigger destroyed in the next execution of the main loop
        // a direct removal can cause issues when iterating on _listeners
        socket->deleteLater();
    });
    connect(socket, &SocketApiSocket::destroyed, this, [socket, this] {
        _listeners.remove(socket);
    });
    OC_ASSERT(socket->readAll().isEmpty());

    auto listener = QSharedPointer<SocketListener>::create(socket);
    _listeners.insert(socket, listener);
}

void SocketApi::slotReadSocket()
{
    SocketApiSocket *socket = qobject_cast<SocketApiSocket *>(sender());
    OC_ENFORCE(socket);

    // Find the SocketListener
    //
    // It's possible for the disconnected() signal to be triggered before
    // the readyRead() signals are received - in that case there won't be a
    // valid listener. We execute the handler anyway, but it will work with
    // a SocketListener that doesn't send any messages.
    static auto invalidListener = QSharedPointer<SocketListener>::create(nullptr);
    const auto listener = _listeners.value(socket, invalidListener);
    while (socket->canReadLine()) {
        // Make sure to normalize the input from the socket to
        // make sure that the path will match, especially on OS X.
        QString line = QString::fromUtf8(socket->readLine()).normalized(QString::NormalizationForm_C);
        // Note: do NOT use QString::trimmed() here! That will also remove any trailing spaces (which _are_ part of the filename)!
        line.chop(1); // remove the '\n'

        qCInfo(lcSocketApi) << u"Received SocketAPI message <--" << line << u"from" << socket;
        const int argPos = line.indexOf(QLatin1Char(':'));
        const QString command = line.mid(0, argPos).toUpper();
        const int indexOfMethod = [&] {
            QByteArray functionWithArguments = QByteArrayLiteral("command_");
            if (command.startsWith(QLatin1String("ASYNC_"))) {
                functionWithArguments += command.toUtf8() + QByteArrayLiteral("(QSharedPointer<SocketApiJob>)");
            } else if (command.startsWith(QLatin1String("V2/"))) {
                functionWithArguments += QByteArrayLiteral("V2_") + command.mid(3).toUtf8() + QByteArrayLiteral("(QSharedPointer<SocketApiJobV2>)");
            } else {
                functionWithArguments += command.toUtf8() + QByteArrayLiteral("(QString,SocketListener*)");
            }
            Q_ASSERT(staticMetaObject.normalizedSignature(functionWithArguments.constData()) == functionWithArguments);
            const auto out = staticMetaObject.indexOfMethod(functionWithArguments.constData());
            if (out == -1) {
                listener->sendError(QStringLiteral("Function %1 not found").arg(QString::fromUtf8(functionWithArguments)));
            }
            OC_ASSERT(out != -1);
            return out;
        }();

        const auto argument = argPos != -1 ? line.mid(argPos + 1) : QString();
        if (command.startsWith(QLatin1String("ASYNC_"))) {
            auto arguments = argument.split(QLatin1Char('|'));
            if (arguments.size() != 2) {
                listener->sendError(QStringLiteral("argument count is wrong"));
                return;
            }

            auto json = QJsonDocument::fromJson(arguments[1].toUtf8()).object();

            auto jobId = arguments[0];

            auto socketApiJob = QSharedPointer<SocketApiJob>(new SocketApiJob(jobId, listener, json), &QObject::deleteLater);
            if (indexOfMethod != -1) {
                staticMetaObject.method(indexOfMethod)
                    .invoke(this, Qt::QueuedConnection,
                        Q_ARG(QSharedPointer<SocketApiJob>, socketApiJob));
            } else {
                qCWarning(lcSocketApi) << u"The command is not supported by this version of the client:" << command << u"with argument:" << argument;
                socketApiJob->reject(QStringLiteral("command not found"));
            }
        } else if (command.startsWith(QLatin1String("V2/"))) {
            QJsonParseError error;
            const auto json = QJsonDocument::fromJson(argument.toUtf8(), &error).object();
            if (error.error != QJsonParseError::NoError) {
                qCWarning(lcSocketApi()) << u"Invalid json" << argument << error.errorString();
                listener->sendError(error.errorString());
                return;
            }
            auto socketApiJob = QSharedPointer<SocketApiJobV2>::create(listener, command, json);
            if (indexOfMethod != -1) {
                staticMetaObject.method(indexOfMethod)
                    .invoke(this, Qt::QueuedConnection,
                        Q_ARG(QSharedPointer<SocketApiJobV2>, socketApiJob));
            } else {
                qCWarning(lcSocketApi) << u"The command is not supported by this version of the client:" << command << u"with argument:" << argument;
                socketApiJob->failure(QStringLiteral("command not found"));
            }
        } else {
            if (indexOfMethod != -1) {
                // to ensure that listener is still valid we need to call it with Qt::DirectConnection
                OC_ASSERT(thread() == QThread::currentThread())
                staticMetaObject.method(indexOfMethod).invoke(this, Qt::DirectConnection, Q_ARG(QString, argument), Q_ARG(SocketListener *, listener.data()));
            }
        }
    }
}


void SocketApi::command_VERSION(const QString &, SocketListener *listener)
{
    listener->sendMessage(QStringLiteral("VERSION:%1:%2:%3").arg(OCC::Version::versionWithBuildNumber().toString(),
                                                                 QStringLiteral(MIRALL_SOCKET_API_VERSION),
                                                                 QString::number(qApp->applicationPid())));
}

void SocketApi::command_V2_HYDRATE_FILE(const QSharedPointer<SocketApiJobV2> &job) const
{
    const auto &arguments = job->arguments();

    const QByteArray fileId = arguments[QStringLiteral("fileId")].toString().toUtf8();
    const QString targetPath = arguments[QStringLiteral("file")].toString();

    auto fileData = FileData::get(targetPath);

    if (fileData.folder) {
        HydrationJob *hydJob = fileData.folder->vfs().hydrateFile(fileId, targetPath);

        if (hydJob) {
            connect(hydJob, &HydrationJob::finished, this, [job, hydJob] {
                job->success({{QStringLiteral("status"), QStringLiteral("OK")}});
                hydJob->deleteLater();
            });
            connect(hydJob, &HydrationJob::error, this, [job, hydJob](const QString& err) {
                job->success({{QStringLiteral("status"), QStringLiteral("ERROR")}, {QStringLiteral("error"), err}});
                hydJob->deleteLater();
            });
            hydJob->start();
        } else {
            qCDebug(lcSocketApi) << "Hydration job for" << fileId << "already running";
        }
    } else {
        job->failure(QStringLiteral("cannot hydrate unknown file"));
    }
}

SocketApi::FileData SocketApi::FileData::get(const QString &localFile)
{
    FileData data;

    data.localPath = QDir::cleanPath(localFile);
    if (data.localPath.endsWith(QLatin1Char('/')))
        data.localPath.chop(1);

    data.folder = FolderMan::instance()->folderForPath(data.localPath, &data.folderRelativePath);
    if (!data.folder)
        return data;
    return data;
}

bool OCC::SocketApi::FileData::isSyncFolder() const
{
    return folderRelativePath.isEmpty();
}

bool SocketApi::FileData::isValid() const
{
    return folder;
}

void SocketApiJob::resolve(const QString &response)
{
    _socketListener->sendMessage(QStringLiteral("RESOLVE|") + _jobId + QLatin1Char('|') + response);
}

void SocketApiJob::resolve(const QJsonObject &response)
{
    resolve(QString::fromUtf8(QJsonDocument { response }.toJson()));
}

void SocketApiJob::reject(const QString &response)
{
    _socketListener->sendMessage(QStringLiteral("REJECT|") + _jobId + QLatin1Char('|') + response);
}

SocketApiJobV2::SocketApiJobV2(const QSharedPointer<SocketListener> &socketListener, const QString &command, const QJsonObject &arguments)
    : _socketListener(socketListener)
    , _command(command)
    , _jobId(arguments[QStringLiteral("id")].toString())
    , _arguments(arguments[QStringLiteral("arguments")].toObject())
{
    OC_ASSERT(!_jobId.isEmpty());
}

void SocketApiJobV2::success(const QJsonObject &response) const
{
    doFinish(response);
}

void SocketApiJobV2::failure(const QString &error) const
{
    doFinish({ { QStringLiteral("error"), error } });
}

void SocketApiJobV2::doFinish(const QJsonObject &obj) const
{
    QJsonObject data { { QStringLiteral("id"), _jobId }, { QStringLiteral("arguments"), obj } };
    if (!_warning.isEmpty()) {
        data[QStringLiteral("warning")] = _warning;
    }
    _socketListener->sendMessage(_command + QStringLiteral("_RESULT:") + QString::fromUtf8(QJsonDocument(data).toJson(QJsonDocument::Compact)));
    Q_EMIT finished();
}

QString SocketApiJobV2::warning() const
{
    return _warning;
}

void SocketApiJobV2::setWarning(const QString &warning)
{
    _warning = warning;
}

} // namespace OCC
