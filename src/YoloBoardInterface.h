#pragma once

#include "interface.h"

class YoloBoardInterface : public PluginInterface {
public:
    virtual ~YoloBoardInterface() = default;
};

#define YoloBoardInterface_iid "org.logos.YoloBoardInterface"
Q_DECLARE_INTERFACE(YoloBoardInterface, YoloBoardInterface_iid)
