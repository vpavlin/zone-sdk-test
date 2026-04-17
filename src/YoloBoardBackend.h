#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVariantMap>
#include <QTimer>
#include <QMap>
#include <QSet>
#include <QSettings>
#include <QFile>
#include <QDir>
#include <QUuid>
#include <QDateTime>
#include <QUrl>
#include <QRegularExpression>
#include <QFutureWatcher>
#include <QThreadPool>
#include <QtConcurrent/QtConcurrentRun>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <atomic>
#include <memory>

// Direct Rust FFI — used in standalone mode (no LogosAPI)
extern "C" {
    // Legacy stateless publish (kept for backward compat)
    char* zone_publish(const char* node_url, const char* channel_id_hex,
                       const char* signing_key_hex,
                       const char* data, const char* checkpoint_path);
    char* zone_query_channel(const char* node_url, const char* channel_id_hex, int limit);
    char* zone_query_channel_paged(const char* node_url, const char* channel_id_hex,
                                   const char* cursor_json, int limit);
    // Persistent sequencer handle
    void* zone_sequencer_create(const char* node_url, const char* channel_id_hex,
                                const char* signing_key_hex, const char* checkpoint_path);
    char* zone_sequencer_publish(void* handle, const char* data);
    char* zone_sequencer_checkpoint(void* handle);
    void  zone_sequencer_destroy(void* handle);

    void  zone_free_string(char* s);
}

#ifdef LOGOS_CORE_AVAILABLE
class LogosAPI;
class LogosAPIClient;
#else
class LogosAPI {};       // empty stub so constructor signature compiles
class LogosAPIClient {}; // never instantiated in standalone mode
#endif

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
    Q_PROPERTY(QVariantMap backfillProgress READ backfillProgress NOTIFY backfillProgressChanged)
    Q_PROPERTY(QString dataDir READ dataDir NOTIFY dataDirChanged)
    Q_PROPERTY(QString storageUrl READ storageUrl WRITE setStorageUrl NOTIFY storageUrlChanged)
    Q_PROPERTY(QString pendingAttachmentPreview READ pendingAttachmentPreview NOTIFY pendingAttachmentChanged)
    Q_PROPERTY(bool uploading READ uploading NOTIFY uploadingChanged)

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
    QVariantMap backfillProgress() const;
    QString dataDir() const { return m_dataDir; }
    QString storageUrl() const { return m_storageUrl; }
    QString pendingAttachmentPreview() const;
    bool uploading() const { return m_uploading; }

    Q_INVOKABLE void subscribe(const QString& channelIdOrName);
    Q_INVOKABLE void unsubscribe(const QString& channelId);
    Q_INVOKABLE void publish(const QString& message);
    Q_INVOKABLE void setCurrentChannelIndex(int index);
    Q_INVOKABLE void setNodeUrl(const QString& url);
    Q_INVOKABLE void setSigningKey(const QString& hex);
    Q_INVOKABLE void setDataDir(const QString& dir);
    Q_INVOKABLE void connectToNode();
    Q_INVOKABLE QString currentChannelId() const;
    Q_INVOKABLE void clearUnread(const QString& channelId);
    Q_INVOKABLE void resetCheckpoint();
    Q_INVOKABLE void startBackfill(const QString& channelId);
    Q_INVOKABLE void stopBackfill(const QString& channelId);
    Q_INVOKABLE void setStorageUrl(const QString& url);
    Q_INVOKABLE void attachFile(const QString& filePath);
    Q_INVOKABLE void openFilePicker();
    Q_INVOKABLE void clearAttachment();
    Q_INVOKABLE void publishWithAttachment(const QString& text);
    Q_INVOKABLE QString resolveMediaPath(const QString& cid);
    Q_INVOKABLE void fetchMedia(const QString& cid);

    // Named-channel helpers — callable from QML for display
    Q_INVOKABLE QString channelDisplayName(const QString& channelId) const;

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
    void backfillProgressChanged();
    void dataDirChanged();
    void storageUrlChanged();
    void pendingAttachmentChanged();
    void uploadingChanged();
    void mediaReady(const QString& cid, const QString& localPath);

private slots:
    void pollMessages();

private:
    bool isStandalone() const;

    QVariant invokeZone(const QString& method, const QVariantList& args = {});
    QVariant invokeStorage(const QString& method, const QVariantList& args = {});
    void initStorageModule();
    void finishPublishWithMedia(const QString& text, const QString& cid,
                                const QString& mimeType, const QString& fileName,
                                int fileSize, const QByteArray& fileData);

    void fetchMessagesAsync(const QString& channelId);
    void mergeMessages(const QString& channelId, const QString& json);
    void setStatus(const QString& msg);
    void initZoneSequencer();
    void initZoneSequencerFinish();
    void loadSettings();
    void saveSettings();
    void saveSubscriptions();
    void loadSubscriptions();
    bool loadKeyFromFile();
    bool loadChannelFromFile();
    void loadSubscriptionsJson();
    void saveSubscriptionsJson();

    // Named-channel encoding/decoding
    static QString encodeChannelName(const QString& name);   // "alice" -> 64-char hex
    static QString decodeChannelName(const QString& hexId);  // hex -> "alice" or ""

    // Media helpers
    QString mediaCacheDir() const;
    QString mediaCachePath(const QString& cid) const;
    static QVariantMap parseMessagePayload(const QString& data);

    // Disk cache
    QString cacheFilePath(const QString& channelId) const;
    void saveCacheForChannel(const QString& channelId);
    void loadCacheForChannel(const QString& channelId);

    // Async publish
    void onPublishFinished(QFutureWatcher<QString>* watcher,
                           const QString& channelId,
                           const QString& pendingMsgId);

    // Backfill helpers
    void runBackfill(const QString& channelId,
                     std::shared_ptr<std::atomic<bool>> cancelled,
                     std::shared_ptr<std::atomic<bool>> alive);

    LogosAPI*         m_logosAPI = nullptr;
    LogosAPIClient*   m_zoneClient = nullptr;
    LogosAPIClient*   m_storageClient = nullptr;
    bool              m_storageStarted = false;
    void*             m_sequencerHandle = nullptr;  // persistent Rust sequencer

    QString     m_nodeUrl   = QStringLiteral("http://localhost:8080");
    QString     m_signingKey;
    QString     m_dataDir;
    QString     m_ownChannelId;
    bool        m_connected = false;
    QString     m_status;
    int         m_currentChannelIndex = 0;

    QStringList                 m_channels;
    QMap<QString, QVariantList> m_messages;
    QMap<QString, int>          m_unreadCounts;
    QMap<QString, QString>      m_lastSeenId;

    QList<QFutureWatcher<QString>*> m_publishWatchers;
    QSet<QString> m_fetchingChannels;   // channels with an in-flight poll
    QSet<QString> m_fetchingMedia;     // CIDs with an in-flight download

    // Backfill state: channelId → cancel flag
    QMap<QString, std::shared_ptr<std::atomic<bool>>> m_backfillCancelled;
    // channelId → {cursor_slot, lib_slot} for progress reporting
    QMap<QString, QPair<quint64,quint64>> m_backfillSlots;

    // Shared liveness flag: set to false in destructor so in-flight background
    // lambdas can bail out before touching member state via a dangling `this`.
    std::shared_ptr<std::atomic<bool>> m_alive =
        std::make_shared<std::atomic<bool>>(true);

    QNetworkAccessManager* m_nam = nullptr;
    QString     m_storageUrl;
    QString     m_pendingAttachment;
    bool        m_uploading = false;

    QTimer* m_pollTimer = nullptr;
    static constexpr int kPollIntervalMs   = 3000;
    static constexpr int kQueryLimit       = 50;
    static constexpr int kMaxCachedMsgs    = 200;

    static const char* kZoneModuleName;
    static const char* kZoneObjectName;
    static const char* kStorageModuleName;
};
