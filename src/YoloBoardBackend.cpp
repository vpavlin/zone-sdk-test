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

// ── Disk cache ────────────────────────────────────────────────────────────────

QString YoloBoardBackend::cacheFilePath(const QString& channelId) const {
    if (m_checkpointDir.isEmpty()) return {};
    return m_checkpointDir + "/cache/" + channelId + ".json";
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
    QSettings s;
    QStringList subs;
    for (const QString& ch : m_channels)
        if (ch != m_ownChannelId)
            subs.append(ch);
    s.setValue("subscribedChannels", subs);
}

void YoloBoardBackend::loadSubscriptions() {
    QSettings s;
    QStringList subs = s.value("subscribedChannels").toStringList();
    bool changed = false;
    for (const QString& ch : subs) {
        if (ch.isEmpty() || m_channels.contains(ch)) continue;
        m_channels.append(ch);
        m_unreadCounts[ch] = 0;
        loadCacheForChannel(ch);
        fetchAndMergeMessages(ch);
        changed = true;
    }
    if (changed) emit channelsChanged();
}

// ── Constructor / destructor ──────────────────────────────────────────────────

YoloBoardBackend::YoloBoardBackend(LogosAPI* logosAPI, QObject* parent)
    : QObject(parent)
    , m_logosAPI(logosAPI)
{
    m_pollTimer = new QTimer(this);
    m_pollTimer->setInterval(kPollIntervalMs);
    connect(m_pollTimer, &QTimer::timeout, this, &YoloBoardBackend::pollMessages);

    if (m_logosAPI) {
#ifdef LOGOS_CORE_AVAILABLE
        m_zoneClient = m_logosAPI->getClient(kZoneModuleName);
#endif
        setStatus("Waiting for configuration...");
    } else {
        setStatus("No Logos API — standalone mode");
    }

    loadSettings();
}

YoloBoardBackend::~YoloBoardBackend() {
    // Cancel any in-flight publishes to avoid callbacks on a destroyed object
    for (auto* w : m_publishWatchers) {
        w->cancel();
        w->waitForFinished();
        delete w;
    }
    m_publishWatchers.clear();
}

// ── Settings persistence ──────────────────────────────────────────────────────

void YoloBoardBackend::loadSettings() {
    QSettings s;
    QString key  = s.value("signingKey").toString();
    QString node = s.value("nodeUrl", m_nodeUrl).toString();
    if (!node.isEmpty()) m_nodeUrl = node;
    if (!key.isEmpty()) {
        m_signingKey = key;
        initZoneSequencer();
    }
}

void YoloBoardBackend::saveSettings() {
    QSettings s;
    s.setValue("signingKey", m_signingKey);
    s.setValue("nodeUrl",    m_nodeUrl);
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

bool YoloBoardBackend::isStandalone() const {
    return m_zoneClient == nullptr;
}

void YoloBoardBackend::initZoneSequencer() {
    if (!m_signingKey.isEmpty()) {
        QString channelId;
        if (isStandalone()) {
            channelId = deriveChannelId(m_signingKey);
        } else {
            invokeZone("set_node_url", {m_nodeUrl});
            invokeZone("set_signing_key", {m_signingKey});
            if (!m_checkpointDir.isEmpty())
                invokeZone("set_checkpoint_path", {m_checkpointDir + "/zone.checkpoint"});
            channelId = invokeZone("get_channel_id").toString();
        }

        if (!channelId.isEmpty() && !channelId.startsWith("Error:")) {
            m_ownChannelId = channelId;
            emit ownChannelIdChanged();
            qInfo() << "YoloBoardBackend: own channel:" << channelId.left(16) + "...";
            if (!m_channels.contains(m_ownChannelId)) {
                m_channels.prepend(m_ownChannelId);
                emit channelsChanged();
            }
            loadCacheForChannel(m_ownChannelId);
        } else {
            qWarning() << "YoloBoardBackend: get_channel_id failed:" << channelId;
        }

        m_connected = true;
        emit connectedChanged();
        setStatus(QString(isStandalone() ? "[standalone] " : "") + "Connected to " + m_nodeUrl);
        m_pollTimer->start();
        loadSubscriptions();
    }
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

void YoloBoardBackend::setCheckpointDir(const QString& dir) {
    m_checkpointDir = dir;
}

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
    saveSubscriptions();
    setStatus("Subscribed to " + channelDisplayName(channelId));
    loadCacheForChannel(channelId);
    fetchAndMergeMessages(channelId);
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
    if (m_currentChannelIndex >= m_channels.size())
        m_currentChannelIndex = qMax(0, m_channels.size() - 1);
    emit currentChannelIndexChanged();
    emit channelsChanged();
    emit messagesChanged();
    saveSubscriptions();
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
    m_messages[m_ownChannelId].append(pendingMsg);
    if (m_ownChannelId == currentChannelId()) emit messagesChanged();

    setStatus("Publishing…");

    if (isStandalone()) {
        // Run zone_publish in a background thread so the UI stays responsive
        QString nodeUrl  = m_nodeUrl;
        QString sigKey   = m_signingKey;
        QString ckptPath = m_checkpointDir.isEmpty()
                           ? "" : m_checkpointDir + "/zone.checkpoint";

        auto* watcher = new QFutureWatcher<QString>(this);
        m_publishWatchers.append(watcher);

        QFuture<QString> future = QtConcurrent::run([=]() -> QString {
            char* raw = zone_publish(nodeUrl.toUtf8().constData(),
                                     sigKey.toUtf8().constData(),
                                     message.toUtf8().constData(),
                                     ckptPath.toUtf8().constData());
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
        // LogosAPI path — invoke synchronously (zone module handles its own threading)
        QString txHash = invokeZone("publish", {message}).toString();
        onPublishFinished(nullptr, m_ownChannelId, pendingId);
        Q_UNUSED(txHash);
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
        fetchAndMergeMessages(channelId);
    } else {
        setStatus("Publish failed: " + txHash);
        emit publishResult(false, txHash);
    }
    saveCacheForChannel(channelId);
}

// ── Polling ───────────────────────────────────────────────────────────────────

void YoloBoardBackend::pollMessages() {
    for (const QString& channelId : m_channels)
        fetchAndMergeMessages(channelId);
}

void YoloBoardBackend::fetchAndMergeMessages(const QString& channelId) {
    QString json;
    if (isStandalone()) {
        char* raw = zone_query_channel(
            m_nodeUrl.toUtf8().constData(),
            channelId.toUtf8().constData(),
            kQueryLimit);
        if (raw) { json = QString::fromUtf8(raw); zone_free_string(raw); }
    } else {
        json = invokeZone("query_channel", {channelId, kQueryLimit}).toString();
    }
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

        QVariantMap msg;
        msg["id"]        = id;
        msg["data"]      = obj["data"].toString();
        msg["channel"]   = channelId;
        msg["isOwn"]     = (channelId == m_ownChannelId);
        msg["timestamp"] = QDateTime::currentDateTime().toString("HH:mm:ss");
        msg["pending"]   = false;
        msg["failed"]    = false;
        existing.append(msg);
        seenIds.insert(id);
        added = true;

        if (channelId != currentChannelId())
            m_unreadCounts[channelId] = m_unreadCounts.value(channelId, 0) + 1;
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
