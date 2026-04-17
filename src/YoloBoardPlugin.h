#pragma once

#include "YoloBoardInterface.h"
#include <QObject>
#include <QWidget>
#include <QtPlugin>

class YoloBoardBackend;

// Backward-compat interface for current Basecamp plugin loader
class IComponent {
public:
    virtual ~IComponent() = default;
    virtual QWidget* createWidget(LogosAPI* logosAPI = nullptr) = 0;
    virtual void destroyWidget(QWidget* widget) = 0;
};
#define IComponent_iid "com.logos.component.IComponent"
Q_DECLARE_INTERFACE(IComponent, IComponent_iid)

class YoloBoardPlugin : public QObject,
                        public YoloBoardInterface,
                        public IComponent {
    Q_OBJECT
    Q_PLUGIN_METADATA(IID IComponent_iid FILE "../metadata.json")
    Q_INTERFACES(YoloBoardInterface IComponent)

public:
    explicit YoloBoardPlugin(QObject* parent = nullptr);
    ~YoloBoardPlugin() override;

    // PluginInterface
    QString name() const override { return "yolo_board"; }
    QString version() const override { return "0.1.0"; }
    Q_INVOKABLE void initLogos(LogosAPI* api);

    // IComponent (backward compat for current Basecamp)
    QWidget* createWidget(LogosAPI* logosAPI = nullptr) override;
    void destroyWidget(QWidget* widget) override;

private:
    YoloBoardBackend* m_backend = nullptr;
};
