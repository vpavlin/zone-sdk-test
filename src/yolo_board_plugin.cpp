#include "yolo_board_plugin.h"
#include "YoloBoardBackend.h"

#include <QQuickWidget>
#include <QQmlContext>
#include <QQmlEngine>
#include <QUrl>

YoloBoardPlugin::YoloBoardPlugin(QObject* parent) : QObject(parent) {}
YoloBoardPlugin::~YoloBoardPlugin() = default;

QWidget* YoloBoardPlugin::createWidget(LogosAPI* logosAPI) {
    m_backend = new YoloBoardBackend(logosAPI);

    auto* view = new QQuickWidget();
    view->engine()->rootContext()->setContextProperty("backend", m_backend);
    view->setResizeMode(QQuickWidget::SizeRootObjectToView);

    // Allow overriding QML path at runtime for development
    const char* qmlPathEnv = std::getenv("QML_PATH");
    if (qmlPathEnv) {
        view->setSource(QUrl::fromLocalFile(
            QString::fromUtf8(qmlPathEnv) + "/Main.qml"));
    } else {
        view->setSource(QUrl("qrc:/qml/Main.qml"));
    }

    return view;
}

void YoloBoardPlugin::destroyWidget(QWidget* widget) {
    delete m_backend;
    m_backend = nullptr;
    delete widget;
}
