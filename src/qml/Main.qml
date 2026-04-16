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

    // ── Fonts / colours (fallback when Logos.Theme not available) ─────────────
    readonly property color bgColor:       "#1a1a2e"
    readonly property color panelColor:    "#16213e"
    readonly property color accentColor:   "#0f3460"
    readonly property color highlightColor:"#e94560"
    readonly property color textColor:     "#eaeaea"
    readonly property color mutedColor:    "#888"
    readonly property color ownMsgColor:   "#c8f7c5"
    readonly property color otherMsgColor: "#eaeaea"
    readonly property int   baseFontPx:    13

    // ── Setup dialog (shown when no signing key) ───────────────────────────────
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
                    width: 8; height: 8
                    radius: 4
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
                    text: backend.ownChannelId.length > 12
                          ? "Channel: " + backend.ownChannelId.substring(0, 12) + "..."
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

        // ── Main body ────────────────────────────────────────────────────────
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

                        delegate: Rectangle {
                            width: channelList.width
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
                                    text: modelData.length > 14
                                          ? modelData.substring(0, 14) + "…"
                                          : modelData
                                    color: index === backend.currentChannelIndex
                                           ? "white" : root.textColor
                                    font.pixelSize: 11
                                    font.family: "monospace"
                                    elide: Text.ElideRight
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
                                placeholderText: "Channel ID to subscribe…"
                                font.pixelSize: 10
                                font.family: "monospace"
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

            // ── Message area ─────────────────────────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                // Messages list
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
                        height: msgText.implicitHeight + 16
                        color: "transparent"

                        readonly property bool isOwn: modelData.isOwn === true

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
                                Layout.fillWidth: true
                                spacing: 2

                                Text {
                                    text: (isOwn ? "you" : modelData.channel.substring(0, 8) + "…")
                                    color: isOwn ? root.highlightColor : root.mutedColor
                                    font.pixelSize: 10
                                }

                                Text {
                                    id: msgText
                                    width: parent.width
                                    text: modelData.data || ""
                                    color: isOwn ? root.ownMsgColor : root.otherMsgColor
                                    font.pixelSize: root.baseFontPx
                                    wrapMode: Text.Wrap
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
                text: "Enter your Ed25519 signing key (64-char hex) and node URL to connect."
                color: root.mutedColor
                font.pixelSize: 11
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }

            TextField {
                id: keyInput
                Layout.fillWidth: true
                placeholderText: "Signing key (64-char hex)…"
                font.family: "monospace"
                font.pixelSize: 11
                color: root.textColor
                background: Rectangle { color: root.accentColor; radius: 3 }
                echoMode: TextInput.Password
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
                enabled: keyInput.text.length === 64
                onClicked: {
                    backend.setNodeUrl(nodeInput.text)
                    backend.setSigningKey(keyInput.text)
                    root.showSetup = false
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

    // Auto-scroll on new messages
    Connections {
        target: backend
        function onMessagesChanged() {
            messageList.positionViewAtBeginning()
        }
    }
} // ApplicationWindow
