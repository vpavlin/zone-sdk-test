import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: root
    visible: true
    width: 900
    height: 600
    minimumWidth: 600
    minimumHeight: 400
    title: "Yolo Board"
    color: "#1a1a2e"

    // ── Colours ───────────────────────────────────────────────────────────────
    readonly property color bgColor:       "#1a1a2e"
    readonly property color panelColor:    "#16213e"
    readonly property color accentColor:   "#0f3460"
    readonly property color highlightColor:"#e94560"
    readonly property color textColor:     "#eaeaea"
    readonly property color mutedColor:    "#888"
    readonly property color ownMsgColor:   "#c8f7c5"
    readonly property color otherMsgColor: "#eaeaea"
    readonly property color pendingColor:  "#888"
    readonly property color failedColor:   "#ff4444"
    readonly property int   baseFontPx:    13

    property bool showSetup: backend.ownChannelId === ""

    // ── Header ────────────────────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Rectangle {
            Layout.fillWidth: true
            height: 40
            color: root.accentColor

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 8

                Rectangle {
                    width: 8; height: 8; radius: 4
                    color: backend.connected ? "#44ff44" : "#ff4444"
                }
                Text {
                    text: "Yolo Board"
                    color: root.textColor
                    font.pixelSize: 15
                    font.bold: true
                }
                Item { Layout.fillWidth: true }
                Text {
                    text: backend.ownChannelId.length > 0
                          ? "Channel: " + backend.channelDisplayName(backend.ownChannelId)
                          : "Not configured"
                    color: root.mutedColor
                    font.pixelSize: 11
                }
                Text {
                    text: backend.nodeUrl
                    color: root.mutedColor
                    font.pixelSize: 11
                }
            }
        }

        // ── Main body ─────────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // ── Channel sidebar ───────────────────────────────────────────────
            Rectangle {
                Layout.preferredWidth: 180
                Layout.fillHeight: true
                color: root.panelColor

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 0

                    Rectangle {
                        Layout.fillWidth: true
                        height: 30
                        color: root.accentColor
                        Text {
                            anchors.centerIn: parent
                            text: "Channels"
                            color: root.textColor
                            font.pixelSize: 12
                            font.bold: true
                        }
                    }

                    ListView {
                        id: channelList
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        model: backend.channels

                        delegate: Column {
                            id: chDelegate
                            width: channelList.width

                            property real backfillProg: backend.backfillProgress[modelData] || -1
                            property bool backfilling: backfillProg >= 0

                            // ── Channel row ───────────────────────────────
                            Rectangle {
                                width: chDelegate.width
                                height: 38
                                color: index === backend.currentChannelIndex
                                       ? root.highlightColor : "transparent"

                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: backend.currentChannelIndex = index
                                }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 6
                                    spacing: 4

                                    Text {
                                        Layout.fillWidth: true
                                        text: (modelData === backend.ownChannelId ? "[you] " : "")
                                              + backend.channelDisplayName(modelData)
                                        color: index === backend.currentChannelIndex
                                               ? "white" : root.textColor
                                        font.pixelSize: 11
                                        elide: Text.ElideRight
                                    }

                                    // Backfill ⟳ button
                                    Rectangle {
                                        visible: chDelegate.backfilling ||
                                                 (index === backend.currentChannelIndex)
                                        width: 18; height: 18; radius: 9
                                        color: chDelegate.backfilling ? "#4488ff" : "transparent"
                                        border.color: chDelegate.backfilling ? "transparent" : root.mutedColor
                                        border.width: chDelegate.backfilling ? 0 : 1
                                        Text {
                                            anchors.centerIn: parent
                                            text: "⟳"
                                            color: chDelegate.backfilling ? "white" : root.mutedColor
                                            font.pixelSize: 11
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            onClicked: {
                                                if (chDelegate.backfilling)
                                                    backend.stopBackfill(modelData)
                                                else
                                                    backend.startBackfill(modelData)
                                            }
                                        }
                                    }

                                    // Unread badge
                                    Rectangle {
                                        visible: (backend.unreadCounts[modelData] || 0) > 0
                                        width: 20; height: 18; radius: 9
                                        color: "#e94560"
                                        Text {
                                            anchors.centerIn: parent
                                            text: backend.unreadCounts[modelData] || 0
                                            color: "white"
                                            font.pixelSize: 10
                                            font.bold: true
                                        }
                                    }
                                }
                            }

                            // ── Progress bar (visible only while backfilling) ──
                            Item {
                                visible: chDelegate.backfilling
                                width: chDelegate.width
                                height: visible ? 14 : 0

                                // Track
                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.right: pctLabel.left
                                    anchors.rightMargin: 3
                                    anchors.verticalCenter: parent.verticalCenter
                                    height: 3
                                    color: root.accentColor
                                    radius: 1

                                    // Fill
                                    Rectangle {
                                        width: chDelegate.backfillProg * parent.width
                                        height: parent.height
                                        color: "#4488ff"
                                        radius: 1
                                        Behavior on width { SmoothedAnimation { velocity: 80 } }
                                    }
                                }

                                Text {
                                    id: pctLabel
                                    anchors.right: parent.right
                                    anchors.rightMargin: 4
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: Math.round(chDelegate.backfillProg * 100) + "%"
                                    color: root.mutedColor
                                    font.pixelSize: 9
                                }
                            }
                        }
                    }

                    // Subscribe input
                    Rectangle {
                        Layout.fillWidth: true
                        height: 70
                        color: root.accentColor

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 6
                            spacing: 4

                            TextField {
                                id: subInput
                                Layout.fillWidth: true
                                placeholderText: "Name or hex channel ID…"
                                font.pixelSize: 10
                                color: root.textColor
                                background: Rectangle { color: "#0a0a1a"; radius: 3 }
                                Keys.onReturnPressed: doSubscribe()
                            }

                            RowLayout {
                                spacing: 4
                                Button {
                                    Layout.fillWidth: true
                                    text: "Subscribe"
                                    font.pixelSize: 10
                                    onClicked: doSubscribe()
                                }
                                Button {
                                    text: "✕"
                                    font.pixelSize: 10
                                    enabled: backend.currentChannelIndex >= 0 &&
                                             backend.channels.length > 0
                                    onClicked: {
                                        var ch = backend.currentChannelId()
                                        if (ch) backend.unsubscribe(ch)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ── Message area ──────────────────────────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                ListView {
                    id: messageList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 2
                    model: backend.messages
                    verticalLayoutDirection: ListView.BottomToTop

                    delegate: Rectangle {
                        width: messageList.width
                        height: msgCol.implicitHeight + 14
                        color: "transparent"

                        readonly property bool isOwn:    modelData.isOwn    === true
                        readonly property bool isPending: modelData.pending  === true
                        readonly property bool isFailed:  modelData.failed   === true

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            anchors.topMargin: 6
                            spacing: 6

                            Rectangle {
                                visible: isOwn
                                width: 3; height: parent.height
                                color: root.highlightColor
                                radius: 1
                            }

                            Column {
                                id: msgCol
                                Layout.fillWidth: true
                                spacing: 2

                                // Sender / state label
                                Text {
                                    text: {
                                        var sender = isOwn
                                            ? "you"
                                            : modelData.channel.substring(0, 8) + "…"
                                        if (isPending) return sender + " [sending…]"
                                        if (isFailed)  return sender + " [failed]"
                                        return sender
                                    }
                                    color: isFailed ? root.failedColor
                                                    : (isOwn ? root.highlightColor : root.mutedColor)
                                    font.pixelSize: 10
                                }

                                // Message body
                                Text {
                                    id: msgText
                                    width: parent.width
                                    text: modelData.data || ""
                                    color: isFailed  ? root.failedColor
                                         : isPending ? root.pendingColor
                                         : isOwn     ? root.ownMsgColor
                                         :             root.otherMsgColor
                                    font.pixelSize: root.baseFontPx
                                    font.strikeout: isFailed
                                    wrapMode: Text.Wrap
                                    opacity: isPending ? 0.6 : 1.0
                                }

                                // Timestamp
                                Text {
                                    id: tsText
                                    visible: (modelData.timestamp || "").length > 0
                                    text: modelData.timestamp || ""
                                    color: root.mutedColor
                                    font.pixelSize: 9
                                    opacity: 0.7
                                }
                            }
                        }
                    }

                    ScrollBar.vertical: ScrollBar {}
                }

                // Compose bar
                Rectangle {
                    Layout.fillWidth: true
                    height: 50
                    color: root.panelColor

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        anchors.topMargin: 6
                        anchors.bottomMargin: 6
                        spacing: 8

                        TextField {
                            id: composeInput
                            Layout.fillWidth: true
                            placeholderText: "Type a message…"
                            font.pixelSize: root.baseFontPx
                            color: root.textColor
                            background: Rectangle { color: root.accentColor; radius: 4 }
                            enabled: backend.connected
                            Keys.onReturnPressed: doPublish()
                        }

                        Button {
                            text: "Publish"
                            font.pixelSize: 12
                            enabled: backend.connected && composeInput.text.length > 0
                            onClicked: doPublish()
                        }
                        Button {
                            text: "⟳ Reset"
                            font.pixelSize: 11
                            ToolTip.visible: hovered
                            ToolTip.text: "Clear stale checkpoint if Publish is stuck"
                            onClicked: backend.resetCheckpoint()
                        }
                    }
                }

                // Status bar
                Rectangle {
                    Layout.fillWidth: true
                    height: 22
                    color: "#0a0a1a"
                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: backend.status
                        color: root.mutedColor
                        font.pixelSize: 10
                    }
                }
            }
        }
    }

    // ── Setup dialog ──────────────────────────────────────────────────────────
    Rectangle {
        visible: root.showSetup
        anchors.centerIn: parent
        width: 400; height: 260
        color: root.panelColor
        border.color: root.accentColor
        border.width: 1
        radius: 6

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 20
            spacing: 12

            Text {
                text: "Yolo Board — Configuration"
                color: root.textColor
                font.pixelSize: 15
                font.bold: true
            }
            Text {
                text: "Enter the path to your Zone data directory (contains sequencer.key and channel.id)."
                color: root.mutedColor
                font.pixelSize: 11
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            TextField {
                id: dataDirInput
                Layout.fillWidth: true
                placeholderText: "Data directory (where sequencer.key lives)…"
                font.pixelSize: 11
                color: root.textColor
                text: backend.dataDir
                background: Rectangle { color: root.accentColor; radius: 3 }
            }
            TextField {
                id: nodeInput
                Layout.fillWidth: true
                placeholderText: "Node URL (e.g. http://localhost:8080)"
                font.pixelSize: 11
                color: root.textColor
                text: backend.nodeUrl
                background: Rectangle { color: root.accentColor; radius: 3 }
            }
            Button {
                Layout.fillWidth: true
                text: "Connect"
                font.pixelSize: 13
                enabled: dataDirInput.text.length > 0
                onClicked: {
                    backend.setDataDir(dataDirInput.text)
                    backend.setNodeUrl(nodeInput.text)
                    backend.connectToNode()
                }
            }
        }
    }

    // ── Functions ─────────────────────────────────────────────────────────────
    function doSubscribe() {
        var ch = subInput.text.trim()
        if (ch.length > 0) {
            backend.subscribe(ch)
            subInput.text = ""
        }
    }

    function doPublish() {
        var msg = composeInput.text.trim()
        if (msg.length > 0) {
            backend.publish(msg)
            composeInput.text = ""
        }
    }

    Connections {
        target: backend
        function onMessagesChanged() {
            messageList.positionViewAtBeginning()
        }
    }
}
