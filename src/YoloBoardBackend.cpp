#include "YoloBoardBackend.h"
#ifdef LOGOS_CORE_AVAILABLE
#  include "logos_api.h"
#  include "logos_api_client.h"
#endif

#include <QDebug>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>

const char* YoloBoardBackend::kZoneModuleName = "liblogos_zone_sequencer_module";
const char* YoloBoardBackend::kZoneObjectName = "liblogos_zone_sequencer_module";

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
}

YoloBoardBackend::~YoloBoardBackend() = default;

// ── Private helpers ──────────────────────────────────────────────────────────

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
        // Derive channel ID — works in both modes
        QString channelId;
        if (isStandalone()) {
            char* raw = zone_derive_channel_id(m_signingKey.toUtf8().constData());
            if (raw) { channelId = QString::fromUtf8(raw); zone_free_string(raw); }
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
        } else {
            qWarning() << "YoloBoardBackend: get_channel_id failed:" << channelId;
        }

        m_connected = true;
        emit connectedChanged();
        setStatus((isStandalone() ? "[standalone] " : "") + "Connected to " + m_nodeUrl);
        m_pollTimer->start();
    }
}

// ── Q_INVOKABLEs ─────────────────────────────────────────────────────────────

void YoloBoardBackend::setNodeUrl(const QString& url) {
    if (m_nodeUrl == url) return;
    m_nodeUrl = url;
    emit nodeUrlChanged();
    if (m_zoneClient) {
        invokeZone("set_node_url", {url});
    }
}

void YoloBoardBackend::setSigningKey(const QString& hex) {
    m_signingKey = hex;
    initZoneSequencer();
}

void YoloBoardBackend::setCheckpointDir(const QString& dir) {
    m_checkpointDir = dir;
}

void YoloBoardBackend::subscribe(const QString& channelId) {
    if (channelId.isEmpty() || m_channels.contains(channelId)) return;
    m_channels.append(channelId);
    m_unreadCounts[channelId] = 0;
    emit channelsChanged();
    setStatus("Subscribed to " + channelId.left(12) + "...");
    // Immediately fetch messages for new channel
    fetchAndMergeMessages(channelId);
}

void YoloBoardBackend::unsubscribe(const QString& channelId) {
    if (!m_channels.contains(channelId)) return;
    // Don't allow unsubscribing from own channel
    if (channelId == m_ownChannelId) {
        setStatus("Cannot unsubscribe from own channel");
        return;
    }
    m_channels.removeAll(channelId);
    m_messages.remove(channelId);
    m_unreadCounts.remove(channelId);
    m_lastSeenId.remove(channelId);
    if (m_currentChannelIndex >= m_channels.size()) {
        m_currentChannelIndex = qMax(0, m_channels.size() - 1);
        emit currentChannelIndexChanged();
    }
    emit channelsChanged();
    emit messagesChanged();
}

void YoloBoardBackend::setCurrentChannelIndex(int index) {
    if (index < 0 || index >= m_channels.size()) return;
    if (m_currentChannelIndex == index) return;
    m_currentChannelIndex = index;
    // Clear unread for newly selected channel
    if (index < m_channels.size()) {
        clearUnread(m_channels.at(index));
    }
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

void YoloBoardBackend::publish(const QString& message) {
    if (message.trimmed().isEmpty()) return;
    if (!m_connected) { setStatus("Not connected — cannot publish"); return; }
    if (m_signingKey.isEmpty()) { setStatus("No signing key set"); return; }

    setStatus("Publishing...");
    QString txHash;

    if (isStandalone()) {
        QString ckptPath = m_checkpointDir.isEmpty()
            ? "" : m_checkpointDir + "/zone.checkpoint";
        char* raw = zone_publish(
            m_nodeUrl.toUtf8().constData(),
            m_signingKey.toUtf8().constData(),
            message.toUtf8().constData(),
            ckptPath.toUtf8().constData());
        if (raw) { txHash = QString::fromUtf8(raw); zone_free_string(raw); }
    } else {
        txHash = invokeZone("publish", {message}).toString();
    }

    if (txHash.isEmpty() || txHash.startsWith("Error:")) {
        setStatus("Publish failed: " + txHash);
        emit publishResult(false, txHash);
    } else {
        setStatus("Published: " + txHash.left(12) + "...");
        emit publishResult(true, txHash);
        pollMessages();
    }
}

// ── Polling ───────────────────────────────────────────────────────────────────

void YoloBoardBackend::pollMessages() {
    for (const QString& channelId : m_channels) {
        fetchAndMergeMessages(channelId);
    }
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
    for (const QVariant& v : existing) {
        seenIds.insert(v.toMap().value("id").toString());
    }

    bool added = false;
    for (const QJsonValue& val : arr) {
        QJsonObject obj = val.toObject();
        QString id = obj["id"].toString();
        if (seenIds.contains(id)) continue;

        QVariantMap msg;
        msg["id"]   = id;
        msg["data"] = obj["data"].toString();
        msg["channel"] = channelId;
        msg["isOwn"] = (channelId == m_ownChannelId);
        existing.append(msg);
        seenIds.insert(id);
        added = true;

        // Increment unread if not the currently viewed channel
        if (channelId != currentChannelId()) {
            m_unreadCounts[channelId] = m_unreadCounts.value(channelId, 0) + 1;
        }
    }

    if (added) {
        if (channelId == currentChannelId()) {
            emit messagesChanged();
        }
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
    for (auto it = m_unreadCounts.constBegin(); it != m_unreadCounts.constEnd(); ++it) {
        out[it.key()] = it.value();
    }
    return out;
}
