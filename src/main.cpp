#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickView>
#include <QUrl>
#include <QIcon>
#include <QStandardPaths>
#include <QDir>
#include <QCommandLineParser>
#include <QTimer>
#include <QTextStream>
#include "YoloBoardBackend.h"

static int runHeadless(const QCoreApplication& app,
                       const QString& signingKey,
                       const QString& nodeUrl,
                       const QString& message,
                       const QString& subscribeChannel)
{
    QTextStream out(stdout), err(stderr);
    QDir().mkpath(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation));

    YoloBoardBackend backend(nullptr);

    int  exitCode = 2;

    QObject::connect(&backend, &YoloBoardBackend::connectedChanged, [&]() {
        if (!backend.connected()) return;
        out << "[headless] connected, own channel: " << backend.ownChannelId() << "\n";
        out.flush();

        if (!subscribeChannel.isEmpty() && subscribeChannel != backend.ownChannelId()) {
            out << "[headless] subscribing to: " << subscribeChannel << "\n";
            out.flush();
            backend.subscribe(subscribeChannel);
        }

        if (!message.isEmpty()) {
            out << "[headless] publishing: " << message << "\n";
            out.flush();
            backend.publish(message);
        } else {
            exitCode = 0;
            QTimer::singleShot(0, [&]() { app.quit(); });
        }
    });

    QObject::connect(&backend, &YoloBoardBackend::publishResult,
                     [&](bool ok, const QString& txHash) {
        if (ok) {
            out << "[headless] publish OK, inscription: " << txHash << "\n";
            out.flush();
            exitCode = 0;
        } else {
            out << "[headless] publish FAILED: " << txHash << "\n";
            out.flush();
            exitCode = 1;
        }
        QTimer::singleShot(0, [&]() { app.quit(); });
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
    });

    QObject::connect(&backend, &YoloBoardBackend::statusChanged, [&]() {
        out << "[headless] status: " << backend.status() << "\n";
        out.flush();
    });

    QTimer::singleShot(30000, [&]() {
        err << "[headless] timeout\n";
        err.flush();
        exitCode = 2;
        app.quit();
    });

    backend.configureNodeUrl(nodeUrl);
    backend.configureSigningKey(signingKey);

    app.exec();
    return exitCode;
}

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

    QDir().mkpath(QStandardPaths::writableLocation(QStandardPaths::AppDataLocation));
    YoloBoardBackend backend(nullptr);

    QQuickView view;
    view.setResizeMode(QQuickView::SizeRootObjectToView);
    view.rootContext()->setContextProperty("backend", &backend);

    const char* qmlPath = std::getenv("QML_PATH");
    QUrl source = qmlPath
        ? QUrl::fromLocalFile(QString::fromUtf8(qmlPath) + "/Main.qml")
        : QUrl("qrc:/qml/Main.qml");

    qDebug() << "Loading QML from:" << source;
    view.setSource(source);
    if (view.status() == QQuickView::Error) {
        for (const auto& e : view.errors())
            qCritical() << "QML error:" << e.toString();
        return 1;
    }
    qDebug() << "QML loaded, status:" << view.status();
    view.setTitle("Yolo Board");
    view.resize(900, 600);
    view.show();
    qDebug() << "Window shown, visible:" << view.isVisible();

    return app.exec();
}
