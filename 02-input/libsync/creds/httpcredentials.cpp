/*
 * Copyright (C) by Klaas Freitag <freitag@kde.org>
 * Copyright (C) by Krzesimir Nowak <krzesimir@endocode.com>
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
#include "creds/httpcredentials.h"

#include "accessmanager.h"
#include "account.h"
#include "configfile.h"
#include "creds/credentialmanager.h"
#include "syncengine.h"

#include <QAuthenticator>
#include <QLoggingCategory>
#include <QNetworkInformation>
#include <QNetworkReply>
#include <QTimer>

#include <chrono>

using namespace std::chrono_literals;

Q_LOGGING_CATEGORY(lcHttpCredentials, "sync.credentials.http", QtInfoMsg)

namespace {
constexpr int TokenRefreshMaxRetries = 3;

auto refreshTokenKeyC()
{
    return QStringLiteral("http/oauthtoken");
}
}

namespace OCC {

// Duration of the timeout when there is one error, this can be applied `TokenRefreshMaxRetries` times
std::chrono::seconds HttpCredentials::TokenRefreshDefaultTimeoutOneError =  30s;

class HttpCredentialsAccessManager : public AccessManager
{
    Q_OBJECT
public:
    HttpCredentialsAccessManager(const HttpCredentials *cred, QObject *parent = nullptr)
        : AccessManager(parent)
        , _cred(cred)
    {
    }

protected:
    QNetworkReply *createRequest(Operation op, const QNetworkRequest &request, QIODevice *outgoingData) override
    {
        QNetworkRequest req(request);
        if (!req.attribute(HttpCredentials::DontAddCredentialsAttribute).toBool()) {
            if (_cred && !_cred->_accessToken.isEmpty()) {
                // Headless callers may store an already complete Authorization header, for example
                // a Basic credential against a server that enables HTTP Basic authentication.
                const QString &token = _cred->_accessToken;
                const QByteArray header = token.startsWith(QLatin1String("Basic "), Qt::CaseInsensitive)
                        || token.startsWith(QLatin1String("Bearer "), Qt::CaseInsensitive)
                    ? token.toUtf8()
                    : "Bearer " + token.toUtf8();
                req.setRawHeader("Authorization", header);
            }
        }
        return AccessManager::createRequest(op, req, outgoingData);
    }

private:
    // The credentials object dies along with the account, while the QNAM might
    // outlive both.
    QPointer<const HttpCredentials> _cred;
};

HttpCredentials::HttpCredentials(const QString &accessToken)
    : _accessToken(accessToken)
    , _ready(true)
{
}

AccessManager *HttpCredentials::createAM() const
{
    AccessManager *am = new HttpCredentialsAccessManager(this);

    connect(am, &QNetworkAccessManager::authenticationRequired,
        this, &HttpCredentials::slotAuthentication);

    return am;
}

bool HttpCredentials::ready() const
{
    return _ready;
}

void HttpCredentials::fetchFromKeychain()
{
    _wasFetched = true;

    if (_ready) {
        Q_EMIT fetched();
    } else {
        fetchFromKeychainHelper();
    }
}

void HttpCredentials::fetchFromKeychainHelper()
{
    auto job = _account->credentialManager()->get(refreshTokenKeyC());
    connect(job, &CredentialJob::finished, this, [job, this] {
        auto handleError = [job, this] {
            qCWarning(lcHttpCredentials) << u"Could not retrieve client password from keychain" << job->errorString();

            // we come here if the password is empty or any other keychain
            // error happend.

            _fetchErrorString = job->error() != QKeychain::EntryNotFound ? job->errorString() : QString();

            _accessToken.clear();
            _ready = false;
            Q_EMIT fetched();
        };
        if (job->error() != QKeychain::NoError) {
            handleError();
            return;
        }
        const auto data = job->data().toString();
        if (OC_ENSURE(!data.isEmpty())) {
            _accessToken = data;
            _ready = true;
            // deferred: callers emit this from inside checkConnectivity(), which would
            // otherwise re-enter and start a second ConnectionValidator
            QTimer::singleShot(0, this, [this] { Q_EMIT fetched(); });
        } else {
            handleError();
        }
    });
}

void HttpCredentials::checkCredentials(QNetworkReply *reply)
{
    // The function is called in order to determine whether we need to ask the user for a password
    // if we are using OAuth, we already started a refresh in slotAuthentication, at least in theory, ensure the auth is started.
    // If the refresh fails, we are going to Q_EMIT authenticationFailed ourselves
    if (reply->error() == QNetworkReply::AuthenticationRequiredError) {
        slotAuthentication(reply, nullptr);
    }
}

void HttpCredentials::slotAuthentication(QNetworkReply *reply, QAuthenticator *authenticator)
{
    qCDebug(lcHttpCredentials) << Q_FUNC_INFO << reply;
    if (!_ready)
        return;
    Q_UNUSED(authenticator)
    // Because of issue #4326, we need to set the login and password manually at every requests
    // Thus, if we reach this signal, those credentials were invalid and we terminate.
    qCWarning(lcHttpCredentials) << u"Stop request: Authentication failed for " << reply->url().toString() << reply->request().rawHeader("Original-Request-ID");

}

void HttpCredentials::invalidateToken()
{
    qCWarning(lcHttpCredentials) << u"Invalidating the credentials";

    if (!_accessToken.isEmpty()) {
        _previousPassword = _accessToken;
    }
    _accessToken = QString();
    _ready = false;

    // clear the session cookie.
    _account->clearCookieJar();

    if (!_refreshToken.isEmpty()) {
        // Only invalidate the access_token (_password) but keep the _refreshToken in the keychain
        // (when coming from forgetSensitiveData, the _refreshToken is cleared)
        return;
    }

    _account->credentialManager()->clear(QStringLiteral("http"));
    // let QNAM forget about the password
    // This needs to be done later in the event loop because we might be called (directly or
    // indirectly) from QNetworkAccessManagerPrivate::authenticationRequired, which itself
    // is a called from a BlockingQueuedConnection from the Qt HTTP thread. And clearing the
    // cache needs to synchronize again with the HTTP thread.
    QTimer::singleShot(0, _account, &Account::clearAMCache);
}

void HttpCredentials::forgetSensitiveData()
{
    // need to be done before invalidateToken, so it actually deletes the refresh_token from the keychain
    _refreshToken.clear();

    invalidateToken();
    _previousPassword.clear();
}

void HttpCredentials::persist()
{
    // write secrets to the keychain
    // _refreshToken should only be empty when we are logged out...
    if (!_refreshToken.isEmpty()) {
        _account->credentialManager()->set(refreshTokenKeyC(), _refreshToken);
    }
}

} // namespace OCC

#include "httpcredentials.moc"
