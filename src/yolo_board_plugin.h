#pragma once

#include "../interfaces/IComponent.h"
#include <QObject>
#include <QtPlugin>

class YoloBoardBackend;

class YoloBoardPlugin : public QObject, public IComponent {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID IComponent_iid FILE "yolo_board_plugin.json")
    Q_INTERFACES(IComponent)

public:
    explicit YoloBoardPlugin(QObject* parent = nullptr);
    ~YoloBoardPlugin() override;

    QWidget* createWidget(LogosAPI* logosAPI = nullptr) override;
    void destroyWidget(QWidget* widget) override;

private:
    YoloBoardBackend* m_backend = nullptr;
};
