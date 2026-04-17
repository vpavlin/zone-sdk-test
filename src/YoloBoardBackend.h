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

extern "C" {
    char* zone_publish(const char* node_url, const char* channel_id_hex,
                       const char* signing_key_hex,
                       const char* data, const char* checkpoint_path);
    char* zone_query_channel(const char* node_url, const char* channel_id_hex, int limit);
    char* zone_query_channel_paged(const char* node_url, const char* channel_id_hex,
                                   const char* cursor_json, int limit);
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
class LogosAPI {};
class LogosAPIClient {};
#endif

class YoloBoardBackend : public QObject {
    Q_OBJECT

    Q_PROPERTY(QVariantList channelList READ channelList NOTIFY channelListChanged)
    Q_PROPERTY(QVariantList messages READ messages NOTIFY messagesChanged)
    Q_PROPERTY(int currentChannelIndex READ currentChannelIndex NOTIFY currentChannelIndexChanged)
    Q_PROPERTY(QString ownChannelId READ ownChannelId NOTIFY ownChannelIdChanged)
    Q_PROPERTY(QString ownChannelDisplayName READ ownChannelDisplayName NOTIFY ownChannelIdChanged)
    Q_PROPERTY(bool connected READ connected NOTIFY connectedChanged)
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    Q_PROPERTY(QVariantMap unreadCounts READ unreadCounts NOTIFY unreadCountsChanged)
    Q_PROPERTY(QString nodeUrl READ nodeUrl NOTIFY nodeUrlChanged)
    Q_PROPERTY(QVariantMap backfillProgress READ backfillProgress NOTIFY backfillProgressChanged)
    Q_PROPERTY(QString dataDir READ dataDir NOTIFY dataDirChanged)
    Q_PROPERTY(QString storageUrl READ storageUrl NOTIFY storageUrlChanged)
    Q_PROPERTY(QString pendingAttachmentPreview READ pendingAttachmentPreview NOTIFY pendingAttachmentChanged)
    Q_PROPERTY(bool uploading READ uploading NOTIFY uploadingChanged)
    Q_PROPERTY(bool storageReady READ storageReady NOTIFY storageReadyChanged)

public:
    explicit YoloBoardBackend(LogosAPI* logosAPI, QObject* parent = nullptr);
    ~YoloBoardBackend() override;

    QVariantList channelList() const;
    QVariantList messages() const;
    int currentChannelIndex() const { return m_currentChannelIndex; }
    QString ownChannelId() const { return m_ownChannelId; }
    QString ownChannelDisplayName() const;
    bool connected() const { return m_connected; }
    QString status() const { return m_status; }
    QVariantMap unreadCounts() const;
    QString nodeUrl() const { return m_nodeUrl; }
    QVariantMap backfillProgress() const;
    QString dataDir() const { return m_dataDir; }
    QString storageUrl() const { return m_storageUrl; }
    QString pendingAttachmentPreview() const;
    bool uploading() const { return m_uploading; }
    bool storageReady() const { return m_storageStarted; }

    Q_INVOKABLE void subscribe(const QString& channelIdOrName);
    Q_INVOKABLE void unsubscribe(const QString& channelId);
    Q_INVOKABLE void publish(const QString& message);
    Q_INVOKABLE void selectChannel(int index);
    Q_INVOKABLE void configureNodeUrl(const QString& url);
    Q_INVOKABLE void configureSigningKey(const QString& hex);
    Q_INVOKABLE void configureDataDir(const QString& dir);
    Q_INVOKABLE void connectToNode();
    Q_INVOKABLE void clearUnread(const QString& channelId);
    Q_INVOKABLE void resetCheckpoint();
    Q_INVOKABLE void startBackfill(const QString& channelId);
    Q_INVOKABLE void stopBackfill(const QString& channelId);
    Q_INVOKABLE void configureStorageUrl(const QString& url);
    Q_INVOKABLE void attachFile(const QString& filePath);
    Q_INVOKABLE void openFilePicker();
    Q_INVOKABLE void clearAttachment();
    Q_INVOKABLE void publishWithAttachment(const QString& text);
    Q_INVOKABLE void fetchMedia(const QString& cid);

    Q_INVOKABLE QString channelDisplayName(const QString& channelId) const;
    Q_INVOKABLE QString resolveMediaPath(const QString& cid);
    Q_INVOKABLE QString currentChannelId() const;

signals:
    void channelListChanged();
    void messagesChanged();
    void currentChannelIndexChanged();
    void ownChannelIdChanged();
    void connectedChanged();
    void statusChanged();
    void unreadCountsChanged();
    void nodeUrlChanged();
    void backfillProgressChanged();
    void dataDirChanged();
    void storageUrlChanged();
    void pendingAttachmentChanged();
    void uploadingChanged();
    void storageReadyChanged();
    void publishResult(bool success, const QString& txHash);
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
    void rebuildChannelList();

    static QString encodeChannelName(const QString& name);
    static QString decodeChannelName(const QString& hexId);

    QString mediaCacheDir() const;
    QString mediaCachePath(const QString& cid) const;
    static QVariantMap parseMessagePayload(const QString& data);

    QString cacheFilePath(const QString& channelId) const;
    void saveCacheForChannel(const QString& channelId);
    void loadCacheForChannel(const QString& channelId);

    void onPublishFinished(QFutureWatcher<QString>* watcher,
                           const QString& channelId,
                           const QString& pendingMsgId);

    void runBackfill(const QString& channelId,
                     std::shared_ptr<std::atomic<bool>> cancelled,
                     std::shared_ptr<std::atomic<bool>> alive);

    LogosAPI*         m_logosAPI = nullptr;
    LogosAPIClient*   m_zoneClient = nullptr;
    LogosAPIClient*   m_storageClient = nullptr;
    bool              m_storageStarted = false;
    void*             m_sequencerHandle = nullptr;

    QString     m_nodeUrl   = QStringLiteral("http://localhost:8080");
    QString     m_signingKey;
    QString     m_dataDir;
    QString     m_ownChannelId;
    bool        m_connected = false;
    QString     m_status;
    int         m_currentChannelIndex = 0;

    QStringList                 m_channelIds;
    QMap<QString, QVariantList> m_allMessages;
    QMap<QString, int>          m_unreadCounts;
    QMap<QString, QString>      m_lastSeenId;

    QList<QFutureWatcher<QString>*> m_publishWatchers;
    QSet<QString> m_fetchingChannels;
    QSet<QString> m_fetchingMedia;

    QMap<QString, std::shared_ptr<std::atomic<bool>>> m_backfillCancelled;
    QMap<QString, QPair<quint64,quint64>> m_backfillSlots;

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
