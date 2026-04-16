#include <QApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QUrl>
#include <QIcon>
#include "YoloBoardBackend.h"

int main(int argc, char* argv[]) {
    QApplication app(argc, argv);
    app.setApplicationName("Yolo Board");
    app.setApplicationVersion("0.1.0");
    app.setOrganizationName("logos");

    YoloBoardBackend backend(nullptr);  // standalone: no LogosAPI

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("backend", &backend);

    // Dev mode: load QML from disk so edits are picked up without rebuild
    const char* qmlPath = std::getenv("QML_PATH");
    QUrl source = qmlPath
        ? QUrl::fromLocalFile(QString::fromUtf8(qmlPath) + "/Main.qml")
        : QUrl("qrc:/qml/Main.qml");

    engine.load(source);
    if (engine.rootObjects().isEmpty()) return 1;

    return app.exec();
}
