/*
 * Copyright (C) by Olivier Goffart <ogoffart@woboq.com>
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

#include "discovery.h"
#include "csync.h"
#include "owncloudpropagator.h"
#include "syncfileitem.h"

#include "csync_exclude.h"

#include "libsync/common/checksums.h"
#include "libsync/common/syncjournaldb.h"
#include "libsync/filesystem.h"


#include <algorithm>

#include <QFile>
#include <QFileInfo>
#include <QThreadPool>

namespace OCC {

Q_LOGGING_CATEGORY(lcDisco, "sync.discovery", QtInfoMsg)

void ProcessDirectoryJob::start()
{
    qCInfo(lcDisco) << u"STARTING" << _currentFolder._server << _qVueryServer << _currentFolder._local << _queryLocal;

    if (_queryServer == NormalQuery) {
        _serverJob = startAsyncServerQuery();
    } else {
        _serverQueryDone = true;
    }

    // Check whether a normal local query is even necessary
    if (_queryLocal == NormalQuery) {
        if (!_discoveryData->_shouldDiscoverLocaly(_currentFolder._local)
            && (_currentFolder._local == _currentFolder._original || !_discoveryData->_shouldDiscoverLocaly(_currentFolder._original))) {
            _queryLocal = ParentNotChanged;
        }
    }

    if (_queryLocal == NormalQuery) {
        startAsyncLocalQuery();
    } else {
        _localQueryDone = true;
    }

    if (_localQueryDone && _serverQueryDone) {
        process();
    }
}

void ProcessDirectoryJob::process()
{
    OC_ASSERT(_localQueryDone && _serverQueryDone);

    struct Entries
    {
        SyncJournalFileRecord dbEntry;
        RemoteInfo serverEntry;
        LocalInfo localEntry;
    };
    std::map<QString, Entries> entries;
    for (auto &e : _serverNormalQueryEntries) {
        entries[e.name()].serverEntry = std::move(e);
    }
    _serverNormalQueryEntries.clear();

    // fetch all the name from the DB
    if (!_discoveryData->_statedb->listFilesInPath(_currentFolder._original, [&](const SyncJournalFileRecord &rec) {
            auto &dbEntry = entries[rec.name()].dbEntry;
            dbEntry = rec;
        })) {
        dbError();
        return;
    }

    for (auto &e : _localNormalQueryEntries) {
        entries[e.name()].localEntry = std::move(e);
    }
    _localNormalQueryEntries.clear();

    //
    // Iterate over entries and process them
    //
    for (const auto &f : entries) {
        const auto &e = f.second;
        const PathTuple path = _currentFolder.addName(f.first);

        // If the filename starts with a . we consider it a hidden file
        // For windows, the hidden state is also discovered within the vio
        // local stat function.
        // Recall file shall not be ignored (#4420)
        const bool isHidden = [&] {
            return e.localEntry.isHidden() || f.first[0] == QLatin1Char('.');
        }();
        if (handleExcluded(path._target, e.localEntry.name(), e.localEntry.isDirectory() || e.serverEntry.isDirectory(), isHidden, e.localEntry.isSymLink(),
                e.serverEntry.isVaultFile())) {
            // the file only exists in the db
            if (!e.localEntry.isValid() && e.dbEntry.isValid()) {
                qCWarning(lcDisco) << u"Removing db entry for non existing ignored file:" << path._original;
                _discoveryData->_statedb->deleteFileRecord(path._original, true);
            }
            continue;
        }

        if (_queryServer == InBlackList || _discoveryData->isInSelectiveSyncBlackList(path._original)) {
            processBlacklisted(path, e.localEntry, e.dbEntry);
            continue;
        }
        processFile(std::move(path), e.localEntry, e.serverEntry, e.dbEntry);
    }
    QTimer::singleShot(0, _discoveryData, &DiscoveryPhase::scheduleMoreJobs);
}

} // namespace OCC
