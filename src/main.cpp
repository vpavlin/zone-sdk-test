#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QUrl>
#include <QIcon>
#include <QStandardPaths>
#include <QDir>
#include <QCommandLineParser>
#include <QTimer>
#include <QTextStream>
#include "YoloBoardBackend.h"

// ── Headless smoke-test mode ──────────────────────────────────────────────────
// Usage: yolo-board --headless --key <64-hex> --node <url> [--message <text>]
//                              [--channel <hex>]
// Publishes one message then queries the channel and prints results.

static int runHeadless(const QCoreApplication& app,
                       const QString& signingKey,
                       const QString& nodeUrl,
                       const QString& message,
                       const QString& subscribeChannel)
{
    QTextStream out(stdout), err(stderr);

    QString dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dataDir);

    YoloBoardBackend backend(nullptr);
    backend.setCheckpointDir(dataDir);

    bool done = false;
    int  exitCode = 0;

    // Wire up signals before setSigningKey (which starts the poll timer)
    QObject::connect(&backend, &YoloBoardBackend::connectedChanged, [&]() {
        if (!backend.connected()) return;
        out << "[headless] connected, own channel: " << backend.ownChannelId() << "\n";
        out.flush();

        // Optionally subscribe to another channel
        if (!subscribeChannel.isEmpty() && subscribeChannel != backend.ownChannelId()) {
            out << "[headless] subscribing to: " << subscribeChannel << "\n";
            out.flush();
            backend.subscribe(subscribeChannel);
        }

        // Publish if a message was given
        if (!message.isEmpty()) {
            out << "[headless] publishing: " << message << "\n";
            out.flush();
            backend.publish(message);
        }
    });

    QObject::connect(&backend, &YoloBoardBackend::publishResult,
                     [&](bool ok, const QString& txHash) {
        if (ok)
            out << "[headless] publish OK, inscription: " << txHash << "\n";
        else
            out << "[headless] publish FAILED: " << txHash << "\n";
        out.flush();
        exitCode = ok ? 0 : 1;
    });

    QObject::connect(&backend, &YoloBoardBackend::messagesChanged, [&]() {
        QVariantList msgs = backend.messages();
        out << "[headless] messages in current channel (" << msgs.size() << "):\n";
        for (const QVariant& v : msgs) {
            QVariantMap m = v.toMap();
            out << "  [" << m["id"].toString().left(12) << "...] "
                << m["data"].toString() << "\n";
        }
        out.flush();
        // Exit after first successful message fetch
        QTimer::singleShot(0, [&]() { done = true; app.quit(); });
    });

    QObject::connect(&backend, &YoloBoardBackend::statusChanged, [&]() {
        out << "[headless] status: " << backend.status() << "\n";
        out.flush();
    });

    // Timeout after 30s
    QTimer::singleShot(30000, [&]() {
        err << "[headless] timeout — no messages received\n";
        err.flush();
        exitCode = 2;
        app.quit();
    });

    backend.setNodeUrl(nodeUrl);
    backend.setSigningKey(signingKey);   // triggers initZoneSequencer + poll timer

    app.exec();
    return exitCode;
}

// ── GUI mode ──────────────────────────────────────────────────────────────────

int main(int argc, char* argv[]) {
    QApplication app(argc, argv);
    app.setApplicationName("Yolo Board");
    app.setApplicationVersion("0.1.0");
    app.setOrganizationName("logos");

    QCommandLineParser parser;
    parser.setApplicationDescription("Yolo Board — Logos Zone bulletin board");
    parser.addHelpOption();
    parser.addVersionOption();

    QCommandLineOption headlessOpt("headless", "Run headless smoke-test and exit");
    QCommandLineOption keyOpt("key", "Ed25519 signing key (64-char hex)", "key");
    QCommandLineOption nodeOpt("node", "Zone node URL", "url", "http://localhost:8080");
    QCommandLineOption msgOpt("message", "Message to publish (headless mode)", "text", "hello from headless");
    QCommandLineOption chanOpt("channel", "Extra channel to subscribe to (headless mode)", "hex");

    parser.addOption(headlessOpt);
    parser.addOption(keyOpt);
    parser.addOption(nodeOpt);
    parser.addOption(msgOpt);
    parser.addOption(chanOpt);
    parser.process(app);

    if (parser.isSet(headlessOpt)) {
        if (!parser.isSet(keyOpt)) {
            QTextStream(stderr) << "Error: --key is required in headless mode\n";
            return 1;
        }
        return runHeadless(app,
                           parser.value(keyOpt),
                           parser.value(nodeOpt),
                           parser.value(msgOpt),
                           parser.value(chanOpt));
    }

    // ── GUI path ──────────────────────────────────────────────────────────────
    YoloBoardBackend backend(nullptr);
    QString dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    QDir().mkpath(dataDir);
    backend.setCheckpointDir(dataDir);

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("backend", &backend);

    const char* qmlPath = std::getenv("QML_PATH");
    QUrl source = qmlPath
        ? QUrl::fromLocalFile(QString::fromUtf8(qmlPath) + "/Main.qml")
        : QUrl("qrc:/qml/Main.qml");

    engine.load(source);
    if (engine.rootObjects().isEmpty()) return 1;

    return app.exec();
}
