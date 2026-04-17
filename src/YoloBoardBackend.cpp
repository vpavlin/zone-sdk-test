#include "YoloBoardBackend.h"
#ifdef LOGOS_CORE_AVAILABLE
#  include "logos_api.h"
#  include "logos_api_client.h"
#endif

#include <QDebug>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QFileInfo>
#include <QFileDialog>
#include <QThread>
#include <QCoreApplication>

// Derive Ed25519 channel ID from signing key using OpenSSL EVP.
#include <openssl/evp.h>
#include <cstdlib>
static QString deriveChannelId(const QString& signingKeyHex) {
    QByteArray keyBytes = QByteArray::fromHex(signingKeyHex.toLatin1());
    if (keyBytes.size() != 32) return {};
    EVP_PKEY* pkey = EVP_PKEY_new_raw_private_key(
        EVP_PKEY_ED25519, nullptr,
        reinterpret_cast<const unsigned char*>(keyBytes.constData()), 32);
    if (!pkey) return {};
    unsigned char pub[32];
    size_t pubLen = 32;
    EVP_PKEY_get_raw_public_key(pkey, pub, &pubLen);
    EVP_PKEY_free(pkey);
    if (pubLen != 32) return {};
    return QString::fromLatin1(QByteArray(reinterpret_cast<const char*>(pub), 32).toHex());
}

const char* YoloBoardBackend::kZoneModuleName = "liblogos_zone_sequencer_module";
const char* YoloBoardBackend::kZoneObjectName = "liblogos_zone_sequencer_module";
const char* YoloBoardBackend::kStorageModuleName = "storage_module";

// ── Named-channel helpers ─────────────────────────────────────────────────────

// Encode a short name as "logos:yolo:<name>" zero-padded to 32 bytes, hex-encoded.
// Returns {} if the resulting string would exceed 32 bytes.
QString YoloBoardBackend::encodeChannelName(const QString& name) {
    static const QByteArray prefix = QByteArrayLiteral("logos:yolo:");
    QByteArray raw = prefix + name.toUtf8();
    if (raw.size() > 32) return {};
    raw = raw.leftJustified(32, '\0');
    return QString::fromLatin1(raw.toHex());
}

// Decode a 64-char hex channel ID: if it encodes "logos:yolo:<name>", return "<name>".
// Otherwise return "".
QString YoloBoardBackend::decodeChannelName(const QString& hexId) {
    QByteArray bytes = QByteArray::fromHex(hexId.toLatin1());
    if (bytes.size() != 32) return {};
    static const QByteArray prefix = QByteArrayLiteral("logos:yolo:");
    if (!bytes.startsWith(prefix)) return {};
    QByteArray name = bytes.mid(prefix.size());
    // Strip trailing NUL padding
    int end = name.size();
    while (end > 0 && name[end - 1] == '\0') --end;
    return QString::fromUtf8(name.left(end));
}

QString YoloBoardBackend::channelDisplayName(const QString& channelId) const {
    QString name = decodeChannelName(channelId);
    if (!name.isEmpty()) return name;
    if (channelId.length() > 12)
        return channelId.left(12) + "…";
    return channelId;
}

// ── Media helpers ────────────────────────────────────────────────────────────

QString YoloBoardBackend::mediaCacheDir() const {
    if (m_dataDir.isEmpty()) return {};
    return m_dataDir + "/media_cache";
}

QString YoloBoardBackend::mediaCachePath(const QString& cid) const {
    QString dir = mediaCacheDir();
    if (dir.isEmpty()) return {};
    return dir + "/" + cid;
}

QVariantMap YoloBoardBackend::parseMessagePayload(const QString& data) {
    QString trimmed = data.trimmed();
    if (!trimmed.startsWith('{')) {
        return {{"text", data}, {"media", QVariantList{}}};
    }
    QJsonDocument doc = QJsonDocument::fromJson(data.toUtf8());
    if (!doc.isObject()) {
        return {{"text", data}, {"media", QVariantList{}}};
    }
    QJsonObject obj = doc.object();
    if (!obj.contains("v")) {
        return {{"text", data}, {"media", QVariantList{}}};
    }

    QVariantMap result;
    result["text"] = obj["text"].toString();
    QVariantList media;
    for (const QJsonValue& m : obj["media"].toArray()) {
        QJsonObject mo = m.toObject();
        QVariantMap entry;
        entry["cid"]  = mo["cid"].toString();
        entry["type"] = mo["type"].toString();
        entry["name"] = mo["name"].toString();
        entry["size"] = mo["size"].toInt();
        media.append(entry);
    }
    result["media"] = media;
    return result;
}

QString YoloBoardBackend::pendingAttachmentPreview() const {
    if (m_pendingAttachment.isEmpty()) return {};
    return QFileInfo(m_pendingAttachment).fileName();
}

// ── Disk cache ────────────────────────────────────────────────────────────────

QString YoloBoardBackend::cacheFilePath(const QString& channelId) const {
    if (m_dataDir.isEmpty()) return {};
    return m_dataDir + "/cache/" + channelId + ".json";
}

void YoloBoardBackend::loadCacheForChannel(const QString& channelId) {
    QString path = cacheFilePath(channelId);
    if (path.isEmpty()) return;
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return;
    QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
    if (!doc.isArray()) return;

    QVariantList& existing = m_messages[channelId];
    QSet<QString> seenIds;
    for (const QVariant& v : existing)
        seenIds.insert(v.toMap().value("id").toString());

    QVariantList loaded;
    for (const QJsonValue& val : doc.array()) {
        QJsonObject obj = val.toObject();
        QString id = obj["block_id"].toString();
        if (id.isEmpty() || seenIds.contains(id)) continue;
        QVariantMap msg;
        msg["id"]        = id;
        msg["data"]      = obj["text"].toString();
        msg["channel"]   = channelId;
        msg["isOwn"]     = (channelId == m_ownChannelId);
        msg["timestamp"] = obj["timestamp"].toString();
        msg["pending"]   = false;
        msg["failed"]    = false;
        QVariantMap parsed = parseMessagePayload(msg["data"].toString());
        msg["displayText"] = parsed["text"];
        msg["media"]       = parsed["media"];
        loaded.append(msg);
        seenIds.insert(id);
    }
    // Prepend cached (older) messages before any already in memory
    if (!loaded.isEmpty()) {
        existing = loaded + existing;
        if (channelId == currentChannelId()) emit messagesChanged();
    }
}

void YoloBoardBackend::saveCacheForChannel(const QString& channelId) {
    QString path = cacheFilePath(channelId);
    if (path.isEmpty()) return;
    QDir().mkpath(QFileInfo(path).absolutePath());

    const QVariantList& msgs = m_messages.value(channelId);
    QJsonArray arr;
    int start = qMax(0, msgs.size() - kMaxCachedMsgs);
    for (int i = start; i < msgs.size(); ++i) {
        QVariantMap m = msgs[i].toMap();
        if (m.value("pending", false).toBool()) continue;
        if (m.value("failed",  false).toBool()) continue;
        QJsonObject obj;
        obj["block_id"]  = m["id"].toString();
        obj["text"]      = m["data"].toString();
        obj["timestamp"] = m["timestamp"].toString();
        obj["pending"]   = false;
        obj["failed"]    = false;
        arr.append(obj);
    }
    QFile f(path);
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        f.write(QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

// ── Subscription persistence ──────────────────────────────────────────────────

void YoloBoardBackend::saveSubscriptions() {
    saveSubscriptionsJson();
}

void YoloBoardBackend::loadSubscriptions() {
    loadSubscriptionsJson();
}

void YoloBoardBackend::saveSubscriptionsJson() {
    if (m_dataDir.isEmpty()) return;
    QString path = m_dataDir + "/subscriptions.json";
    QJsonArray arr;
    for (const QString& ch : m_channels)
        if (ch != m_ownChannelId)
            arr.append(ch);
    QFile f(path);
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate))
        f.write(QJsonDocument(arr).toJson(QJsonDocument::Compact));
}

void YoloBoardBackend::loadSubscriptionsJson() {
    if (m_dataDir.isEmpty()) return;
    QString path = m_dataDir + "/subscriptions.json";
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return;
    QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
    if (!doc.isArray()) return;
    bool changed = false;
    for (const QJsonValue& val : doc.array()) {
        QString ch = val.toString();
        if (ch.isEmpty() || m_channels.contains(ch)) continue;
        m_channels.append(ch);
        m_unreadCounts[ch] = 0;
        loadCacheForChannel(ch);
        startBackfill(ch);
        changed = true;
    }
    if (changed) emit channelsChanged();
}

// ── File-based key and channel loading ───────────────────────────────────────

bool YoloBoardBackend::loadKeyFromFile() {
    if (m_dataDir.isEmpty()) return false;
    QString path = m_dataDir + "/sequencer.key";
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return false;
    QByteArray raw = f.readAll();
    if (raw.size() != 32) return false;
    m_signingKey = QString::fromLatin1(raw.toHex());
    return true;
}

bool YoloBoardBackend::loadChannelFromFile() {
    if (m_dataDir.isEmpty()) return false;
    QString path = m_dataDir + "/channel.id";
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return false;
    QByteArray raw = f.readAll();
    if (raw.size() != 32) return false;
    m_ownChannelId = QString::fromLatin1(raw.toHex());
    return true;
}

// ── Constructor / destructor ──────────────────────────────────────────────────

YoloBoardBackend::YoloBoardBackend(LogosAPI* logosAPI, QObject* parent)
    : QObject(parent)
    , m_logosAPI(logosAPI)
{
    m_pollTimer = new QTimer(this);
    m_pollTimer->setInterval(kPollIntervalMs);
    connect(m_pollTimer, &QTimer::timeout, this, &YoloBoardBackend::pollMessages);

    // m_zoneClient is initialized lazily in initZoneSequencer() to avoid
    // blocking the constructor while the module is still starting up.
    m_nam = new QNetworkAccessManager(this);
    setStatus("Waiting for configuration...");

    loadSettings();
}

YoloBoardBackend::~YoloBoardBackend() {
    // Signal liveness flag first so any already-running background lambda
    // aborts before it touches member state through a dangling `this`.
    m_alive->store(false);

    // Stop the poll timer so no new background tasks are enqueued
    m_pollTimer->stop();

    // Cancel all running backfills
    for (auto& cancelled : m_backfillCancelled)
        cancelled->store(true);

    // Cancel any in-flight publishes
    for (auto* w : m_publishWatchers) {
        w->cancel();
        w->waitForFinished();
        delete w;
    }
    m_publishWatchers.clear();

    // Wait until all background thread-pool tasks exit.  Each task checks
    // m_alive before calling QMetaObject::invokeMethod(this, ...) so they
    // will not touch the dead object.  We must wait for them to drain rather
    // than timing out, because even calling invokeMethod with a destroyed
    // `this` is UB.
    QThreadPool::globalInstance()->waitForDone(-1);

    // Destroy the persistent Rust sequencer (drops the background actor)
    if (m_sequencerHandle) {
        zone_sequencer_destroy(m_sequencerHandle);
        m_sequencerHandle = nullptr;
    }
}

// ── Settings persistence ──────────────────────────────────────────────────────

void YoloBoardBackend::loadSettings() {
    QSettings s;
    QString node    = s.value("nodeUrl", m_nodeUrl).toString();
    QString dataDir = s.value("dataDir").toString();
    if (!node.isEmpty()) m_nodeUrl = node;
    // Only accept a saved dataDir if it actually has the signing key file.
    // This prevents the app-data-dir (set by older code versions) from being used
    // as if it were a configured TUI data directory.
    if (!dataDir.isEmpty() && m_dataDir.isEmpty()) {
        if (QFile::exists(dataDir + "/sequencer.key")) {
            m_dataDir = dataDir;
        } else {
            qInfo() << "Saved dataDir has no sequencer.key, ignoring:" << dataDir;
            s.remove("dataDir");   // clear the stale entry
        }
    }
    m_storageUrl = s.value("storageUrl").toString();
    // Try to initialise from file-based config
    initZoneSequencer();
}

void YoloBoardBackend::saveSettings() {
    QSettings s;
    s.setValue("nodeUrl", m_nodeUrl);
    if (!m_dataDir.isEmpty()) s.setValue("dataDir", m_dataDir);
    if (!m_storageUrl.isEmpty()) s.setValue("storageUrl", m_storageUrl);
}

// ── Private helpers ───────────────────────────────────────────────────────────

void YoloBoardBackend::setStatus(const QString& msg) {
    if (m_status == msg) return;
    m_status = msg;
    emit statusChanged();
}

QVariant YoloBoardBackend::invokeZone(const QString& method, const QVariantList& args) {
#ifdef LOGOS_CORE_AVAILABLE
    if (!m_zoneClient) {
        qWarning() << "YoloBoardBackend: no zone client, cannot call" << method;
        return {};
    }
    return m_zoneClient->invokeRemoteMethod(kZoneObjectName, method, args);
#else
    Q_UNUSED(method); Q_UNUSED(args);
    return {};
#endif
}

QVariant YoloBoardBackend::invokeStorage(const QString& method, const QVariantList& args) {
#ifdef LOGOS_CORE_AVAILABLE
    if (!m_storageClient) {
        qWarning() << "YoloBoardBackend: no storage client, cannot call" << method;
        return {};
    }
    return m_storageClient->invokeRemoteMethod(kStorageModuleName, method, args);
#else
    Q_UNUSED(method); Q_UNUSED(args);
    return {};
#endif
}

void YoloBoardBackend::initStorageModule() {
#ifdef LOGOS_CORE_AVAILABLE
    if (m_storageStarted || !m_logosAPI) return;
    if (!m_storageClient) {
        m_storageClient = m_logosAPI->getClient(kStorageModuleName);
        if (!m_storageClient) return;
    }
    // Init with data dir config
    QString dataDir = m_dataDir.isEmpty() ? "/tmp/logos-storage" : m_dataDir + "/storage";
    QDir().mkpath(dataDir);
    QString cfg = QString("{\"data-dir\":\"%1\"}").arg(dataDir);
    QVariant initResult = invokeStorage("init", {cfg});
    qInfo() << "Storage init:" << initResult;
    QVariant startResult = invokeStorage("start", {});
    qInfo() << "Storage start:" << startResult;
    m_storageStarted = true;
#endif
}

bool YoloBoardBackend::isStandalone() const {
    return m_zoneClient == nullptr;
}

void YoloBoardBackend::initZoneSequencer() {
#ifdef LOGOS_CORE_AVAILABLE
    if (!m_zoneClient && m_logosAPI) {
        m_zoneClient = m_logosAPI->getClient(kZoneModuleName);
        if (m_zoneClient)
            qInfo() << "YoloBoardBackend: zone client connected via LogosAPI";
    }
#endif

    // Try loading key from file first; fall back to m_signingKey already set
    bool keyFromFile = loadKeyFromFile();
    if (!keyFromFile && m_signingKey.isEmpty()) {
        // No key available at all — stay unconfigured
        return;
    }

    // Try loading channel from file; if not found, derive from key
    bool channelFromFile = loadChannelFromFile();
    if (!channelFromFile) {
        if (m_signingKey.isEmpty()) return;
        if (isStandalone()) {
            m_ownChannelId = deriveChannelId(m_signingKey);
        } else {
            // IPC calls must run on main thread (QRemoteObjects is thread-bound).
            // Use a single-shot timer to defer so we don't block the current call.
            setStatus("Connecting to zone sequencer module...");
            QTimer::singleShot(0, this, [this]() {
                invokeZone("set_node_url", {m_nodeUrl});
                invokeZone("set_signing_key", {m_signingKey});
                if (!m_dataDir.isEmpty())
                    invokeZone("set_checkpoint_path", {m_dataDir + "/sequencer.checkpoint"});
                QString chId = invokeZone("get_channel_id").toString();
                if (!chId.isEmpty() && !chId.startsWith("Error:"))
                    invokeZone("set_channel_id", {chId});
                m_ownChannelId = chId;
                initZoneSequencerFinish();
            });
            return;
        }
    } else if (!isStandalone()) {
        setStatus("Connecting to zone sequencer module...");
        QTimer::singleShot(0, this, [this]() {
            invokeZone("set_node_url", {m_nodeUrl});
            invokeZone("set_signing_key", {m_signingKey});
            if (!m_dataDir.isEmpty())
                invokeZone("set_checkpoint_path", {m_dataDir + "/sequencer.checkpoint"});
            invokeZone("set_channel_id", {m_ownChannelId});
            initZoneSequencerFinish();
        });
        return;
    }

    initZoneSequencerFinish();
}

void YoloBoardBackend::initZoneSequencerFinish() {
    if (m_ownChannelId.isEmpty() || m_ownChannelId.startsWith("Error:")) {
        qWarning() << "YoloBoardBackend: could not determine own channel ID";
        setStatus("Error: " + m_ownChannelId);
        return;
    }

    emit ownChannelIdChanged();
    qInfo() << "YoloBoardBackend: own channel:" << m_ownChannelId.left(16) + "...";
    if (!m_channels.contains(m_ownChannelId)) {
        m_channels.prepend(m_ownChannelId);
        emit channelsChanged();
    }
    loadCacheForChannel(m_ownChannelId);

    // Create persistent sequencer handle (standalone mode only)
    if (isStandalone() && !m_sequencerHandle) {
        QString ckptPath = m_dataDir.isEmpty()
                           ? "" : m_dataDir + "/sequencer.checkpoint";
        m_sequencerHandle = zone_sequencer_create(
            m_nodeUrl.toUtf8().constData(),
            m_ownChannelId.toUtf8().constData(),
            m_signingKey.toUtf8().constData(),
            ckptPath.toUtf8().constData());
        if (m_sequencerHandle)
            qInfo() << "YoloBoardBackend: persistent sequencer created";
        else
            qWarning() << "YoloBoardBackend: failed to create persistent sequencer";
    }

    m_connected = true;
    emit connectedChanged();
    setStatus(QString(isStandalone() ? "[standalone] " : "") + "Connected to " + m_nodeUrl);
    m_pollTimer->start();
    loadSubscriptionsJson();

    // Initialize storage module if available (Basecamp mode)
    if (!isStandalone())
        QTimer::singleShot(500, this, [this]() { initStorageModule(); });
}

// ── Q_INVOKABLEs ─────────────────────────────────────────────────────────────

void YoloBoardBackend::setNodeUrl(const QString& url) {
    if (m_nodeUrl == url) return;
    m_nodeUrl = url;
    emit nodeUrlChanged();
    saveSettings();
    if (m_zoneClient) invokeZone("set_node_url", {url});
}

void YoloBoardBackend::setSigningKey(const QString& hex) {
    m_signingKey = hex;
    saveSettings();
    initZoneSequencer();
}

void YoloBoardBackend::setDataDir(const QString& dir) {
    if (m_dataDir == dir) return;
    m_dataDir = dir;
    emit dataDirChanged();
    saveSettings();
    initZoneSequencer();
}

void YoloBoardBackend::connectToNode() {
    initZoneSequencer();
}

void YoloBoardBackend::resetCheckpoint() {
    if (m_dataDir.isEmpty()) return;
    QString path = m_dataDir + "/sequencer.checkpoint";
    if (QFile::exists(path)) {
        QFile::rename(path, path + ".bak");
        setStatus("Checkpoint reset — publish should work now");
    } else {
        setStatus("No checkpoint to reset");
    }
}

// ── Media / storage ──────────────────────────────────────────────────────────

void YoloBoardBackend::setStorageUrl(const QString& url) {
    if (m_storageUrl == url) return;
    m_storageUrl = url;
    emit storageUrlChanged();
    saveSettings();
}

void YoloBoardBackend::attachFile(const QString& filePath) {
    QString path = filePath;
    if (path.startsWith("file://"))
        path = QUrl(path).toLocalFile();
    m_pendingAttachment = path;
    emit pendingAttachmentChanged();
}

void YoloBoardBackend::openFilePicker() {
    auto* dialog = new QFileDialog(nullptr, "Attach Image", QDir::homePath(),
        "Image files (*.png *.jpg *.jpeg *.gif *.webp);;All files (*)");
    dialog->setFileMode(QFileDialog::ExistingFile);
    dialog->setAttribute(Qt::WA_DeleteOnClose);
    connect(dialog, &QFileDialog::fileSelected, this, [this](const QString& path) {
        if (!path.isEmpty())
            attachFile(path);
    });
    dialog->open();
}

void YoloBoardBackend::clearAttachment() {
    m_pendingAttachment.clear();
    emit pendingAttachmentChanged();
}

void YoloBoardBackend::publishWithAttachment(const QString& text) {
    if (m_pendingAttachment.isEmpty()) {
        publish(text);
        return;
    }

    QFileInfo fi(m_pendingAttachment);
    if (!fi.exists()) {
        setStatus("Cannot read file: " + m_pendingAttachment);
        return;
    }
    QString filePath = fi.absoluteFilePath();
    QString fileName = fi.fileName();
    QString ext = fi.suffix().toLower();
    QString mimeType = "application/octet-stream";
    if (ext == "png")                       mimeType = "image/png";
    else if (ext == "jpg" || ext == "jpeg") mimeType = "image/jpeg";
    else if (ext == "gif")                  mimeType = "image/gif";
    else if (ext == "webp")                 mimeType = "image/webp";
    int fileSize = fi.size();

    m_uploading = true;
    emit uploadingChanged();
    setStatus("Uploading " + fileName + "…");

    QString cid;

#ifdef LOGOS_CORE_AVAILABLE
    if (m_storageClient && m_storageStarted) {
        // Synchronous upload: init → chunks → finalize
        QFile f(filePath);
        if (!f.open(QIODevice::ReadOnly)) {
            m_uploading = false;
            emit uploadingChanged();
            setStatus("Cannot read file");
            return;
        }
        QByteArray allData = f.readAll();
        f.close();

        // Use uploadUrl — it handles init+chunks+finalize internally.
        // Returns session ID immediately; CID comes via storageUploadDone event.
        // We defer getting the CID: start upload, then use a timer to check manifests.
        QJsonObject uploadObj;
        {
            QString resultStr = invokeStorage("uploadUrl", {filePath, (qlonglong)65536}).toString();
            if (!resultStr.isEmpty())
                uploadObj = QJsonDocument::fromJson(resultStr.toUtf8()).object();
        }
        qInfo() << "Storage uploadUrl:" << uploadObj;

        if (uploadObj["success"].toBool()) {
            // Upload started async — defer CID lookup via timer
            auto* timer = new QTimer(this);
            int* attempts = new int(0);
            timer->setInterval(2000);
            connect(timer, &QTimer::timeout, this, [this, timer, attempts, text, mimeType, fileName, fileSize, allData]() {
                (*attempts)++;
                QString manifestsStr = invokeStorage("manifests", {}).toString();
                QJsonObject mObj;
                if (!manifestsStr.isEmpty())
                    mObj = QJsonDocument::fromJson(manifestsStr.toUtf8()).object();

                QString foundCid;
                if (mObj["success"].toBool()) {
                    QJsonArray arr = mObj["value"].toArray();
                    for (const QJsonValue& v : arr) {
                        QJsonObject m = v.toObject();
                        if (m["filename"].toString() == fileName) {
                            foundCid = m["cid"].toString();
                            break;
                        }
                    }
                }

                if (!foundCid.isEmpty()) {
                    timer->stop(); timer->deleteLater(); delete attempts;
                    m_uploading = false;
                    emit uploadingChanged();
                    finishPublishWithMedia(text, foundCid, mimeType, fileName, fileSize, allData);
                } else if (*attempts >= 30) {
                    timer->stop(); timer->deleteLater(); delete attempts;
                    m_uploading = false;
                    emit uploadingChanged();
                    setStatus("Upload timed out waiting for CID");
                }
            });
            timer->start();
            return;  // async — don't fall through
        }
    }
#endif

    if (cid.isEmpty() && !m_storageUrl.isEmpty()) {
        // HTTP fallback
        QFile file(filePath);
        if (!file.open(QIODevice::ReadOnly)) {
            m_uploading = false;
            emit uploadingChanged();
            setStatus("Cannot read file");
            return;
        }
        QByteArray fileData = file.readAll();
        file.close();

        QUrl url(m_storageUrl.trimmed().remove(QRegularExpression("/+$")) + "/api/storage/v1/data");
        QNetworkRequest req(url);
        req.setHeader(QNetworkRequest::ContentTypeHeader, "application/octet-stream");
        req.setRawHeader("Content-Disposition",
                         ("attachment; filename=\"" + fileName + "\"").toUtf8());

        QNetworkReply* reply = m_nam->post(req, fileData);
        connect(reply, &QNetworkReply::finished, this,
                [this, reply, text, fileName, mimeType, fileSize, fileData]() {
            reply->deleteLater();
            m_uploading = false;
            emit uploadingChanged();

            if (reply->error() != QNetworkReply::NoError) {
                setStatus("Upload failed: " + reply->errorString());
                return;
            }

            QByteArray body = reply->readAll();
            QString httpCid;
            QJsonDocument doc = QJsonDocument::fromJson(body);
            if (doc.isObject() && doc.object().contains("cid"))
                httpCid = doc.object()["cid"].toString();
            else
                httpCid = QString::fromUtf8(body).trimmed().remove('"');

            if (httpCid.isEmpty()) {
                setStatus("Upload returned empty CID");
                return;
            }
            finishPublishWithMedia(text, httpCid, mimeType, fileName, fileSize, fileData);
        });
        return;
    }

    m_uploading = false;
    emit uploadingChanged();

    if (cid.isEmpty()) {
        setStatus("Upload failed — no storage available");
        return;
    }

    // Cache locally
    QFile file(filePath);
    QByteArray fileData;
    if (file.open(QIODevice::ReadOnly)) fileData = file.readAll();

    finishPublishWithMedia(text, cid, mimeType, fileName, fileSize, fileData);
}

void YoloBoardBackend::finishPublishWithMedia(const QString& text, const QString& cid,
                                               const QString& mimeType, const QString& fileName,
                                               int fileSize, const QByteArray& fileData) {
    setStatus("Uploaded, CID: " + cid.left(16) + "…");

    // Cache locally
    QString cachePath = mediaCachePath(cid);
    if (!cachePath.isEmpty() && !fileData.isEmpty()) {
        QDir().mkpath(mediaCacheDir());
        QFile cache(cachePath);
        if (cache.open(QIODevice::WriteOnly))
            cache.write(fileData);
    }

    QJsonObject payload;
    payload["v"] = 1;
    payload["text"] = text;
    QJsonArray media;
    QJsonObject mediaEntry;
    mediaEntry["cid"]  = cid;
    mediaEntry["type"] = mimeType;
    mediaEntry["name"] = fileName;
    mediaEntry["size"] = fileSize;
    media.append(mediaEntry);
    payload["media"] = media;

    QString encoded = QString::fromUtf8(
        QJsonDocument(payload).toJson(QJsonDocument::Compact));

    clearAttachment();
    publish(encoded);
}

QString YoloBoardBackend::resolveMediaPath(const QString& cid) {
    QString path = mediaCachePath(cid);
    if (path.isEmpty()) return {};
    if (QFile::exists(path)) return path;
    return {};
}

void YoloBoardBackend::fetchMedia(const QString& cid) {
    if (cid.isEmpty()) return;

    QString cached = resolveMediaPath(cid);
    if (!cached.isEmpty()) {
        emit mediaReady(cid, cached);
        return;
    }
    if (m_fetchingMedia.contains(cid)) return;
    m_fetchingMedia.insert(cid);

    QString cachePath = mediaCachePath(cid);

#ifdef LOGOS_CORE_AVAILABLE
    if (m_storageClient && m_storageStarted && !cachePath.isEmpty()) {
        QDir().mkpath(mediaCacheDir());
        QString resultStr = invokeStorage("downloadFile", {cid, cachePath, false}).toString();
        qInfo() << "Storage downloadFile result:" << resultStr;
        // downloadFile is async — file appears after storageDownloadDone event
        // Poll for the file with a timer
        auto* timer = new QTimer(this);
        int* attempts = new int(0);
        timer->setInterval(1000);
        connect(timer, &QTimer::timeout, this, [this, timer, attempts, cid, cachePath]() {
            (*attempts)++;
            if (QFile::exists(cachePath) && QFileInfo(cachePath).size() > 0) {
                timer->stop(); timer->deleteLater(); delete attempts;
                m_fetchingMedia.remove(cid);
                emit mediaReady(cid, cachePath);
                emit messagesChanged();
            } else if (*attempts >= 30) {
                timer->stop(); timer->deleteLater(); delete attempts;
                m_fetchingMedia.remove(cid);
                qWarning() << "fetchMedia timed out for" << cid;
            }
        });
        timer->start();
        return;
    }
#endif

    if (m_storageUrl.isEmpty()) {
        QUrl nodeUrl(m_nodeUrl);
        if (nodeUrl.isValid() && !nodeUrl.host().isEmpty()) {
            m_storageUrl = nodeUrl.scheme() + "://" + nodeUrl.host() + ":8090";
            emit storageUrlChanged();
        } else {
            m_fetchingMedia.remove(cid);
            return;
        }
    }

    QUrl url(m_storageUrl.trimmed().remove(QRegularExpression("/+$"))
             + "/api/storage/v1/data/" + cid + "/network/stream");
    QNetworkRequest req(url);
    QNetworkReply* reply = m_nam->get(req);

    connect(reply, &QNetworkReply::finished, this, [this, reply, cid]() {
        reply->deleteLater();
        m_fetchingMedia.remove(cid);

        if (reply->error() != QNetworkReply::NoError) {
            qWarning() << "fetchMedia failed for" << cid << reply->errorString();
            return;
        }

        QByteArray data = reply->readAll();
        QString dir = mediaCacheDir();
        if (dir.isEmpty()) return;
        QDir().mkpath(dir);

        QString path = mediaCachePath(cid);
        QFile f(path);
        if (f.open(QIODevice::WriteOnly)) {
            f.write(data);
            f.close();
            emit mediaReady(cid, path);
            emit messagesChanged();
        }
    });
}

// ── Subscriptions ────────────────────────────────────────────────────────────

void YoloBoardBackend::subscribe(const QString& input) {
    QString channelId = input.trimmed();
    if (channelId.isEmpty()) return;

    // If not a 64-char hex string, treat as a human-readable name
    static const QRegularExpression hexRe("^[0-9a-fA-F]{64}$");
    if (!hexRe.match(channelId).hasMatch()) {
        QString encoded = encodeChannelName(channelId);
        if (encoded.isEmpty()) {
            setStatus("Name too long — max 21 characters");
            return;
        }
        channelId = encoded;
    }

    if (m_channels.contains(channelId)) {
        setStatus("Already subscribed");
        return;
    }

    m_channels.append(channelId);
    m_unreadCounts[channelId] = 0;
    emit channelsChanged();
    saveSubscriptionsJson();
    setStatus("Subscribed to " + channelDisplayName(channelId));
    loadCacheForChannel(channelId);
    fetchMessagesAsync(channelId);
    startBackfill(channelId);
}

void YoloBoardBackend::unsubscribe(const QString& channelId) {
    if (!m_channels.contains(channelId)) return;
    if (channelId == m_ownChannelId) {
        setStatus("Cannot unsubscribe from own channel");
        return;
    }
    m_channels.removeAll(channelId);
    m_messages.remove(channelId);
    m_unreadCounts.remove(channelId);
    m_lastSeenId.remove(channelId);
    m_fetchingChannels.remove(channelId);
    if (m_currentChannelIndex >= m_channels.size())
        m_currentChannelIndex = qMax(0, m_channels.size() - 1);
    emit currentChannelIndexChanged();
    emit channelsChanged();
    emit messagesChanged();
    saveSubscriptionsJson();
}

void YoloBoardBackend::setCurrentChannelIndex(int index) {
    if (index < 0 || index >= m_channels.size()) return;
    if (m_currentChannelIndex == index) return;
    m_currentChannelIndex = index;
    clearUnread(m_channels.at(index));
    emit currentChannelIndexChanged();
    emit messagesChanged();
}

void YoloBoardBackend::clearUnread(const QString& channelId) {
    if (m_unreadCounts.value(channelId, 0) > 0) {
        m_unreadCounts[channelId] = 0;
        emit unreadCountsChanged();
    }
}

QString YoloBoardBackend::currentChannelId() const {
    if (m_currentChannelIndex < 0 || m_currentChannelIndex >= m_channels.size())
        return {};
    return m_channels.at(m_currentChannelIndex);
}

// ── Async publish ─────────────────────────────────────────────────────────────

void YoloBoardBackend::publish(const QString& message) {
    if (message.trimmed().isEmpty()) return;
    if (!m_connected) { setStatus("Not connected"); return; }
    if (m_signingKey.isEmpty()) { setStatus("No signing key set"); return; }

    // Add message immediately with pending state for instant feedback
    QString pendingId = QUuid::createUuid().toString(QUuid::WithoutBraces);
    QVariantMap pendingMsg;
    pendingMsg["id"]        = pendingId;
    pendingMsg["data"]      = message;
    pendingMsg["channel"]   = m_ownChannelId;
    pendingMsg["isOwn"]     = true;
    pendingMsg["timestamp"] = QDateTime::currentDateTime().toString("HH:mm:ss");
    pendingMsg["pending"]   = true;
    pendingMsg["failed"]    = false;
    QVariantMap parsed = parseMessagePayload(message);
    pendingMsg["displayText"] = parsed["text"];
    pendingMsg["media"]       = parsed["media"];
    m_messages[m_ownChannelId].append(pendingMsg);
    if (m_ownChannelId == currentChannelId()) emit messagesChanged();

    setStatus("Publishing…");

    if (isStandalone()) {
        if (!m_sequencerHandle) { setStatus("Sequencer not ready"); return; }

        // Use the persistent sequencer handle in a background thread
        void* handle = m_sequencerHandle;

        auto* watcher = new QFutureWatcher<QString>(this);
        m_publishWatchers.append(watcher);

        QFuture<QString> future = QtConcurrent::run([=]() -> QString {
            char* raw = zone_sequencer_publish(handle,
                                               message.toUtf8().constData());
            if (!raw) return {};
            QString result = QString::fromUtf8(raw);
            zone_free_string(raw);
            return result;
        });

        watcher->setFuture(future);
        connect(watcher, &QFutureWatcher<QString>::finished, this,
                [this, watcher, pendingId]() {
            onPublishFinished(watcher, m_ownChannelId, pendingId);
        });
    } else {
        // LogosAPI path — invoke on main thread (QRemoteObjects is thread-bound)
        QString result = invokeZone("publish", {message}).toString();

        // Update pending message directly
        bool ok = !result.isEmpty() && !result.startsWith("Error:");
        QVariantList& msgs = m_messages[m_ownChannelId];
        for (int i = 0; i < msgs.size(); ++i) {
            QVariantMap m = msgs[i].toMap();
            if (m["id"].toString() == pendingId) {
                m["pending"] = false;
                m["failed"]  = !ok;
                if (ok) m["id"] = result;
                msgs[i] = m;
                break;
            }
        }
        if (m_ownChannelId == currentChannelId()) emit messagesChanged();
        if (ok) {
            setStatus("Published: " + result.left(12) + "…");
            emit publishResult(true, result);
        } else {
            setStatus("Publish failed: " + result);
            emit publishResult(false, result);
        }
        saveCacheForChannel(m_ownChannelId);
    }
}

void YoloBoardBackend::onPublishFinished(QFutureWatcher<QString>* watcher,
                                          const QString& channelId,
                                          const QString& pendingMsgId) {
    QString txHash;
    if (watcher) {
        txHash = watcher->result();
        m_publishWatchers.removeOne(watcher);
        watcher->deleteLater();
    }

    if (!m_messages.contains(channelId)) return;

    bool ok = !txHash.isEmpty() && !txHash.startsWith("Error:");
    QVariantList& msgs = m_messages[channelId];
    for (int i = 0; i < msgs.size(); ++i) {
        QVariantMap m = msgs[i].toMap();
        if (m["id"].toString() == pendingMsgId) {
            m["pending"] = false;
            m["failed"]  = !ok;
            if (ok) m["id"] = txHash;
            msgs[i] = m;
            break;
        }
    }

    if (channelId == currentChannelId()) emit messagesChanged();

    if (ok) {
        setStatus("Published: " + txHash.left(12) + "…");
        emit publishResult(true, txHash);
        fetchMessagesAsync(channelId);
    } else {
        setStatus("Publish failed: " + txHash);
        emit publishResult(false, txHash);
    }
    saveCacheForChannel(channelId);
}

// ── Polling ───────────────────────────────────────────────────────────────────

void YoloBoardBackend::pollMessages() {
    for (const QString& channelId : m_channels)
        fetchMessagesAsync(channelId);
}

// Kick off a background fetch for channelId (no-op if one is already in flight).
void YoloBoardBackend::fetchMessagesAsync(const QString& channelId) {
    if (m_fetchingChannels.contains(channelId)) return;
    m_fetchingChannels.insert(channelId);

    QString nodeUrl  = m_nodeUrl;
    int     limit    = kQueryLimit;
    bool    standalone = isStandalone();

    auto alive = m_alive;
    // Always use direct FFI for queries — they're stateless, fast, and avoid
    // IPC timeouts that block the main thread.
    QThreadPool::globalInstance()->start([this, alive, channelId, nodeUrl, limit]() {
        QString json;
        char* raw = zone_query_channel(
            nodeUrl.toUtf8().constData(),
            channelId.toUtf8().constData(),
            limit);
        if (raw) { json = QString::fromUtf8(raw); zone_free_string(raw); }

        // Marshal result back to main thread for safe state mutation
        bool queryOk = !json.isEmpty();
        if (!alive->load()) return;
        QMetaObject::invokeMethod(this, [this, alive, channelId, json, queryOk]() {
            if (!alive->load()) return;
            mergeMessages(channelId, json);
            m_fetchingChannels.remove(channelId);
            // Track connection state from query success/failure
            if (queryOk && !m_connected) {
                m_connected = true;
                emit connectedChanged();
            } else if (!queryOk && m_connected && m_fetchingChannels.isEmpty()) {
                m_connected = false;
                emit connectedChanged();
                setStatus("Connection lost");
            }
        }, Qt::QueuedConnection);
    });
}

// Merge a JSON array of messages into m_messages[channelId]. Must run on the main thread.
void YoloBoardBackend::mergeMessages(const QString& channelId, const QString& json) {
    if (json.isEmpty() || json == "[]") return;

    QJsonDocument doc = QJsonDocument::fromJson(json.toUtf8());
    if (!doc.isArray()) return;
    QJsonArray arr = doc.array();

    QVariantList& existing = m_messages[channelId];
    QSet<QString> seenIds;
    for (const QVariant& v : existing)
        seenIds.insert(v.toMap().value("id").toString());

    bool added = false;
    for (const QJsonValue& val : arr) {
        QJsonObject obj = val.toObject();
        QString id = obj["id"].toString();
        if (seenIds.contains(id)) continue;

        QString text = obj["data"].toString();

        // Confirm a matching pending message in-place (like TUI does)
        bool confirmedPending = false;
        for (int i = 0; i < existing.size(); ++i) {
            QVariantMap m = existing[i].toMap();
            if ((m.value("pending").toBool() || m.value("failed").toBool())
                && m.value("data").toString() == text) {
                m["pending"] = false;
                m["failed"]  = false;
                m["id"]      = id;
                existing[i]  = m;
                confirmedPending = true;
                break;
            }
        }

        if (!confirmedPending) {
            QVariantMap msg;
            msg["id"]        = id;
            msg["data"]      = text;
            msg["channel"]   = channelId;
            msg["isOwn"]     = (channelId == m_ownChannelId);
            msg["timestamp"] = QDateTime::currentDateTime().toString("HH:mm:ss");
            msg["pending"]   = false;
            msg["failed"]    = false;
            QVariantMap parsed = parseMessagePayload(text);
            msg["displayText"] = parsed["text"];
            msg["media"]       = parsed["media"];
            existing.append(msg);

            if (channelId != currentChannelId())
                m_unreadCounts[channelId] = m_unreadCounts.value(channelId, 0) + 1;
        }

        seenIds.insert(id);
        added = true;
    }

    if (added) {
        saveCacheForChannel(channelId);
        if (channelId == currentChannelId()) emit messagesChanged();
        emit unreadCountsChanged();
    }
}

// ── Property accessors ────────────────────────────────────────────────────────

QVariantList YoloBoardBackend::messages() const {
    QString chId = currentChannelId();
    if (chId.isEmpty()) return {};
    return m_messages.value(chId);
}

QVariantMap YoloBoardBackend::unreadCounts() const {
    QVariantMap out;
    for (auto it = m_unreadCounts.constBegin(); it != m_unreadCounts.constEnd(); ++it)
        out[it.key()] = it.value();
    return out;
}

QVariantMap YoloBoardBackend::backfillProgress() const {
    QVariantMap out;
    for (auto it = m_backfillSlots.constBegin(); it != m_backfillSlots.constEnd(); ++it) {
        quint64 cursorSlot = it.value().first;
        quint64 libSlot    = it.value().second;
        double progress = (libSlot > 0) ? qMin(1.0, double(cursorSlot) / double(libSlot)) : 0.0;
        out[it.key()] = progress;
    }
    return out;
}

// ── History backfill ──────────────────────────────────────────────────────────

void YoloBoardBackend::startBackfill(const QString& channelId) {
    if (m_backfillCancelled.contains(channelId)) return;  // already running

    auto cancelled = std::make_shared<std::atomic<bool>>(false);
    m_backfillCancelled[channelId] = cancelled;
    m_backfillSlots[channelId] = {0, 1};
    emit backfillProgressChanged();

    QString nodeUrl   = m_nodeUrl;
    QString chId      = channelId;
    QString ckptDir   = m_dataDir;

    auto alive = m_alive;
    auto* pool = QThreadPool::globalInstance();
    pool->start([this, alive, chId, cancelled]() {
        runBackfill(chId, cancelled, alive);
    });
}

void YoloBoardBackend::stopBackfill(const QString& channelId) {
    auto it = m_backfillCancelled.find(channelId);
    if (it != m_backfillCancelled.end()) {
        (*it)->store(true);
        m_backfillCancelled.erase(it);
    }
    m_backfillSlots.remove(channelId);
    emit backfillProgressChanged();
}

void YoloBoardBackend::runBackfill(const QString& channelId,
                                    std::shared_ptr<std::atomic<bool>> cancelled,
                                    std::shared_ptr<std::atomic<bool>> alive) {
    static const int kPageSize = 100;
    QByteArray cursorJson;  // empty = from genesis

    while (!cancelled->load()) {
        const char* cursorArg = cursorJson.isEmpty() ? nullptr : cursorJson.constData();
        char* raw = zone_query_channel_paged(
            m_nodeUrl.toUtf8().constData(),
            channelId.toUtf8().constData(),
            cursorArg,
            kPageSize);

        if (!raw) {
            qWarning() << "YoloBoardBackend::runBackfill: zone_query_channel_paged returned NULL";
            break;
        }

        QString jsonStr = QString::fromUtf8(raw);
        zone_free_string(raw);

        QJsonDocument doc = QJsonDocument::fromJson(jsonStr.toUtf8());
        if (!doc.isObject()) {
            qWarning() << "YoloBoardBackend::runBackfill: unexpected JSON";
            break;
        }
        QJsonObject root = doc.object();

        // Update progress on main thread
        quint64 cursorSlot = (quint64)root["cursor_slot"].toDouble();
        quint64 libSlot    = (quint64)root["lib_slot"].toDouble();
        bool done          = root["done"].toBool(false);

        if (!alive->load()) break;
        QMetaObject::invokeMethod(this, [this, alive, channelId, cursorSlot, libSlot]() {
            if (!alive->load()) return;
            m_backfillSlots[channelId] = {cursorSlot, libSlot};
            emit backfillProgressChanged();
        }, Qt::QueuedConnection);

        // Merge messages on main thread
        QJsonArray msgs = root["messages"].toArray();
        if (!msgs.isEmpty()) {
            QVariantList newMsgs;
            for (const QJsonValue& val : msgs) {
                QJsonObject obj = val.toObject();
                QVariantMap msg;
                msg["id"]      = obj["id"].toString();
                msg["data"]    = obj["data"].toString();
                msg["channel"] = channelId;
                msg["isOwn"]   = (channelId == m_ownChannelId);
                msg["timestamp"] = QString();
                msg["pending"] = false;
                msg["failed"]  = false;
                QVariantMap parsed = parseMessagePayload(msg["data"].toString());
                msg["displayText"] = parsed["text"];
                msg["media"]       = parsed["media"];
                newMsgs.append(msg);
            }
            if (!alive->load()) break;
            QMetaObject::invokeMethod(this, [this, alive, channelId, newMsgs]() {
                if (!alive->load()) return;
                QVariantList& existing = m_messages[channelId];
                QSet<QString> seenIds;
                for (const QVariant& v : existing)
                    seenIds.insert(v.toMap().value("id").toString());

                QVariantList prepend;
                for (const QVariant& v : newMsgs) {
                    QString id = v.toMap().value("id").toString();
                    if (!seenIds.contains(id)) {
                        prepend.append(v);
                        seenIds.insert(id);
                    }
                }
                if (!prepend.isEmpty()) {
                    // Historical messages go before current ones
                    existing = prepend + existing;
                    saveCacheForChannel(channelId);
                    if (channelId == currentChannelId()) emit messagesChanged();
                }
            }, Qt::QueuedConnection);
        }

        // Advance cursor for next page
        QJsonDocument cursorDoc(root["cursor"].toObject());
        cursorJson = cursorDoc.toJson(QJsonDocument::Compact);

        if (done || cancelled->load()) break;

        // Brief yield between pages to avoid hammering the node
        QThread::msleep(200);
    }

    // Backfill complete — clean up state on main thread
    if (alive->load())
    QMetaObject::invokeMethod(this, [this, alive, channelId]() {
        if (!alive->load()) return;
        m_backfillCancelled.remove(channelId);
        m_backfillSlots.remove(channelId);
        emit backfillProgressChanged();
        setStatus("Backfill complete for " + channelDisplayName(channelId));
    }, Qt::QueuedConnection);
}
