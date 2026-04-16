#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>
#include <QTimer>
#include <QMap>

// Direct Rust FFI — used in standalone mode (no LogosAPI)
extern "C" {
    char* zone_publish(const char* node_url, const char* signing_key_hex,
                       const char* data, const char* checkpoint_path);
    char* zone_query_channel(const char* node_url, const char* channel_id_hex, int limit);
    char* zone_derive_channel_id(const char* signing_key_hex);
    void  zone_free_string(char* s);
}

class LogosAPI;
class LogosAPIClient;

class YoloBoardBackend : public QObject {
    Q_OBJECT

    Q_PROPERTY(QStringList channels READ channels NOTIFY channelsChanged)
    Q_PROPERTY(QVariantList messages READ messages NOTIFY messagesChanged)
    Q_PROPERTY(int currentChannelIndex READ currentChannelIndex WRITE setCurrentChannelIndex NOTIFY currentChannelIndexChanged)
    Q_PROPERTY(QString ownChannelId READ ownChannelId NOTIFY ownChannelIdChanged)
    Q_PROPERTY(bool connected READ connected NOTIFY connectedChanged)
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    Q_PROPERTY(QVariantMap unreadCounts READ unreadCounts NOTIFY unreadCountsChanged)
    Q_PROPERTY(QString nodeUrl READ nodeUrl WRITE setNodeUrl NOTIFY nodeUrlChanged)

public:
    explicit YoloBoardBackend(LogosAPI* logosAPI, QObject* parent = nullptr);
    ~YoloBoardBackend() override;

    QStringList channels() const { return m_channels; }
    QVariantList messages() const;
    int currentChannelIndex() const { return m_currentChannelIndex; }
    QString ownChannelId() const { return m_ownChannelId; }
    bool connected() const { return m_connected; }
    QString status() const { return m_status; }
    QVariantMap unreadCounts() const;
    QString nodeUrl() const { return m_nodeUrl; }

    Q_INVOKABLE void subscribe(const QString& channelId);
    Q_INVOKABLE void unsubscribe(const QString& channelId);
    Q_INVOKABLE void publish(const QString& message);
    Q_INVOKABLE void setCurrentChannelIndex(int index);
    Q_INVOKABLE void setNodeUrl(const QString& url);
    Q_INVOKABLE void setSigningKey(const QString& hex);
    Q_INVOKABLE void setCheckpointDir(const QString& dir);
    Q_INVOKABLE QString currentChannelId() const;
    Q_INVOKABLE void clearUnread(const QString& channelId);

signals:
    void channelsChanged();
    void messagesChanged();
    void currentChannelIndexChanged();
    void ownChannelIdChanged();
    void connectedChanged();
    void statusChanged();
    void unreadCountsChanged();
    void nodeUrlChanged();
    void publishResult(bool success, const QString& txHash);

private slots:
    void pollMessages();

private:
    bool isStandalone() const;   // true when running without LogosAPI

    // Call zone_sequencer module via LogosAPI
    QVariant invokeZone(const QString& method,
                        const QVariantList& args = {});

    void fetchAndMergeMessages(const QString& channelId);
    void setStatus(const QString& msg);
    void initZoneSequencer();

    LogosAPI*         m_logosAPI = nullptr;
    LogosAPIClient*   m_zoneClient = nullptr;

    QString     m_nodeUrl   = QStringLiteral("http://localhost:8080");
    QString     m_signingKey;
    QString     m_checkpointDir;
    QString     m_ownChannelId;
    bool        m_connected = false;
    QString     m_status;
    int         m_currentChannelIndex = 0;

    QStringList                 m_channels;        // list of channel IDs we track
    QMap<QString, QVariantList> m_messages;        // channelId -> message list
    QMap<QString, int>          m_unreadCounts;    // channelId -> unread count
    QMap<QString, QString>      m_lastSeenId;      // channelId -> last message ID seen

    QTimer* m_pollTimer = nullptr;
    static constexpr int kPollIntervalMs = 3000;

    static constexpr int kQueryLimit = 50;
    static const char* kZoneModuleName;
    static const char* kZoneObjectName;
};
