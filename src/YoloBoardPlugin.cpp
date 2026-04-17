#include "YoloBoardPlugin.h"
#include "YoloBoardBackend.h"

#include <QQuickWidget>
#include <QQmlContext>
#include <QQmlEngine>
#include <QUrl>

YoloBoardPlugin::YoloBoardPlugin(QObject* parent) : QObject(parent) {}
YoloBoardPlugin::~YoloBoardPlugin() = default;

void YoloBoardPlugin::initLogos(LogosAPI* api) {
    if (m_backend) return;
    logosAPI = api;
    m_backend = new YoloBoardBackend(api, this);
    qDebug() << "YoloBoardPlugin: backend initialized via initLogos";
}

QWidget* YoloBoardPlugin::createWidget(LogosAPI* api) {
    if (!m_backend) {
        if (api) logosAPI = api;
        m_backend = new YoloBoardBackend(logosAPI, this);
    }

    auto* view = new QQuickWidget();
    view->engine()->rootContext()->setContextProperty("backend", m_backend);
    view->setResizeMode(QQuickWidget::SizeRootObjectToView);

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
