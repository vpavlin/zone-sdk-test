import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    width: 900
    height: 600
    color: theme.bg

    // ── Basecamp Dark Theme ──────────────────────────────────────────────────
    QtObject {
        id: theme
        readonly property color bg:          "#171717"
        readonly property color bgSecondary: "#262626"
        readonly property color bgElevated:  "#1E1E1E"
        readonly property color bgInset:     "#141414"
        readonly property color surface:     "#343434"
        readonly property color border:      "#434343"
        readonly property color borderSub:   "#333333"

        readonly property color text:        "#FFFFFF"
        readonly property color textSec:     "#A4A4A4"
        readonly property color textMuted:   "#969696"
        readonly property color textPlace:   "#717784"

        readonly property color accent:      "#ED7B58"
        readonly property color accentHover: "#FF6F42"
        readonly property color success:     "#49F563"
        readonly property color error:       "#FB3748"
        readonly property color warning:     "#FEBC2E"
        readonly property color info:        "#ED7B58"
        readonly property color notify:      "#FB3748"

        readonly property int fontPrimary:   14
        readonly property int fontSecondary: 12
    }

    property bool showSetup: backend.ownChannelId === ""

    palette.highlight: theme.accent
    palette.highlightedText: theme.text

    // ── Main Layout ──────────────────────────────────────────────────────────
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ── Header bar ───────────────────────────────────────────────────────
        Rectangle {
            Layout.fillWidth: true
            height: 44
            color: theme.bgElevated

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                spacing: 10

                Text {
                    text: "\u2B21"
                    font.pixelSize: 16
                    font.family: "Noto Sans Symbols2"
                    color: backend.connected ? theme.accent : theme.textPlace
                    ToolTip.visible: chainMouse.containsMouse
                    ToolTip.text: backend.connected ? "Chain: connected" : "Chain: disconnected"
                    MouseArea { id: chainMouse; anchors.fill: parent; hoverEnabled: true }
                }
                Text {
                    text: "\u25A4"
                    font.pixelSize: 14
                    color: backend.storageReady ? theme.accent : theme.textPlace
                    ToolTip.visible: storageMouse.containsMouse
                    ToolTip.text: backend.storageReady ? "Storage: ready" : "Storage: not ready"
                    MouseArea { id: storageMouse; anchors.fill: parent; hoverEnabled: true }
                }
                Text {
                    text: "Yolo Board"
                    color: theme.text
                    font.pixelSize: 16
                    font.weight: Font.Bold
                }
                Item { Layout.fillWidth: true }
                Text {
                    text: backend.ownChannelId.length > 0
                          ? backend.channelDisplayName(backend.ownChannelId)
                          : ""
                    color: theme.textMuted
                    font.pixelSize: theme.fontSecondary
                }
                Rectangle {
                    width: 1; height: 20
                    color: theme.border
                    visible: backend.nodeUrl.length > 0
                }
                Text {
                    text: backend.nodeUrl
                    color: theme.textMuted
                    font.pixelSize: theme.fontSecondary
                    visible: backend.nodeUrl.length > 0
                }
            }

            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width; height: 1
                color: theme.borderSub
            }
        }

        // ── Body ─────────────────────────────────────────────────────────────
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // ── Channel sidebar ──────────────────────────────────────────────
            Rectangle {
                Layout.preferredWidth: 200
                Layout.fillHeight: true
                color: theme.bgSecondary

                ColumnLayout {
                    anchors.fill: parent
                    spacing: 0

                    // Sidebar header
                    Item {
                        Layout.fillWidth: true
                        height: 36
                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            text: "CHANNELS"
                            color: theme.textMuted
                            font.pixelSize: 11
                            font.weight: Font.Medium
                            font.letterSpacing: 1
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
                            property bool selected: index === backend.currentChannelIndex
                            property bool hovered: chMouse.containsMouse

                            Rectangle {
                                width: chDelegate.width
                                height: 36
                                color: chDelegate.selected ? theme.surface
                                     : chDelegate.hovered ? Qt.rgba(1,1,1,0.04)
                                     : "transparent"
                                radius: 4
                                anchors.leftMargin: 4
                                anchors.rightMargin: 4

                                MouseArea {
                                    id: chMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: backend.currentChannelIndex = index
                                }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 12
                                    anchors.rightMargin: 8
                                    spacing: 6

                                    Text {
                                        Layout.fillWidth: true
                                        text: backend.channelDisplayName(modelData)
                                        color: chDelegate.selected ? theme.text
                                             : modelData === backend.ownChannelId ? theme.accent
                                             : theme.textSec
                                        font.pixelSize: theme.fontSecondary
                                        font.weight: chDelegate.selected ? Font.Medium : Font.Normal
                                        elide: Text.ElideRight
                                    }

                                    // Backfill button
                                    Rectangle {
                                        visible: chDelegate.backfilling || chDelegate.selected
                                        width: 20; height: 20; radius: 10; z: 1
                                        color: chDelegate.backfilling ? theme.accent : "transparent"
                                        border.color: chDelegate.backfilling ? "transparent" : theme.border
                                        border.width: 1
                                        Text {
                                            anchors.centerIn: parent
                                            text: "⟳"
                                            color: chDelegate.backfilling ? theme.text : theme.textMuted
                                            font.pixelSize: 12
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
                                        width: 22; height: 18; radius: 9
                                        color: theme.notify
                                        Text {
                                            anchors.centerIn: parent
                                            text: backend.unreadCounts[modelData] || 0
                                            color: theme.text
                                            font.pixelSize: 10
                                            font.weight: Font.Bold
                                        }
                                    }
                                }
                            }

                            // Progress bar
                            Item {
                                visible: chDelegate.backfilling
                                width: chDelegate.width
                                height: visible ? 14 : 0

                                Rectangle {
                                    anchors.left: parent.left
                                    anchors.leftMargin: 12
                                    anchors.right: pctLabel.left
                                    anchors.rightMargin: 4
                                    anchors.verticalCenter: parent.verticalCenter
                                    height: 3; radius: 2
                                    color: theme.surface

                                    Rectangle {
                                        width: chDelegate.backfillProg * parent.width
                                        height: parent.height
                                        color: theme.accent
                                        radius: 2
                                        Behavior on width { SmoothedAnimation { velocity: 80 } }
                                    }
                                }

                                Text {
                                    id: pctLabel
                                    anchors.right: parent.right
                                    anchors.rightMargin: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: Math.round(chDelegate.backfillProg * 100) + "%"
                                    color: theme.textMuted
                                    font.pixelSize: 9
                                }
                            }
                        }
                    }

                    // Subscribe bar
                    Rectangle {
                        Layout.fillWidth: true
                        height: 72
                        color: theme.bgElevated

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 8
                            spacing: 6

                            TextField {
                                id: subInput
                                Layout.fillWidth: true
                                placeholderText: "Channel name or ID…"
                                placeholderTextColor: theme.textPlace
                                font.pixelSize: theme.fontSecondary
                                color: theme.text
                                background: Rectangle {
                                    color: theme.bgInset
                                    border.color: theme.borderSub
                                    border.width: 1
                                    radius: 4
                                }
                                Keys.onReturnPressed: doSubscribe()
                            }

                            RowLayout {
                                spacing: 6
                                Button {
                                    Layout.fillWidth: true
                                    text: "Subscribe"
                                    font.pixelSize: theme.fontSecondary
                                    contentItem: Text {
                                        text: parent.text
                                        color: theme.text
                                        font: parent.font
                                        horizontalAlignment: Text.AlignHCenter
                                    }
                                    background: Rectangle {
                                        color: parent.down ? theme.accentHover : theme.surface
                                        radius: 4
                                    }
                                    onClicked: doSubscribe()
                                }
                                Button {
                                    text: "✕"
                                    font.pixelSize: theme.fontSecondary
                                    contentItem: Text {
                                        text: parent.text
                                        color: theme.textSec
                                        font: parent.font
                                        horizontalAlignment: Text.AlignHCenter
                                    }
                                    background: Rectangle {
                                        color: parent.down ? theme.error : theme.surface
                                        radius: 4
                                    }
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

                // Right border
                Rectangle {
                    anchors.right: parent.right
                    width: 1; height: parent.height
                    color: theme.borderSub
                }
            }

            // ── Message area ─────────────────────────────────────────────────
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                ListView {
                    id: messageList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 1
                    model: backend.messages
                    verticalLayoutDirection: ListView.BottomToTop

                    delegate: Rectangle {
                        width: messageList.width
                        height: msgCol.implicitHeight + 16
                        color: msgHover.containsMouse ? Qt.rgba(1,1,1,0.02) : "transparent"

                        readonly property bool isOwn:     modelData.isOwn    === true
                        readonly property bool isPending: modelData.pending  === true
                        readonly property bool isFailed:  modelData.failed   === true

                        MouseArea {
                            id: msgHover
                            anchors.fill: parent
                            hoverEnabled: true
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 14
                            anchors.topMargin: 6
                            spacing: 8

                            Rectangle {
                                visible: isOwn
                                width: 3; Layout.fillHeight: true
                                color: theme.accent
                                radius: 2
                            }

                            Column {
                                id: msgCol
                                Layout.fillWidth: true
                                spacing: 3

                                Text {
                                    text: {
                                        var sender = isOwn
                                            ? "you"
                                            : backend.channelDisplayName(modelData.channel || "")
                                        if (isPending) return sender + "  ·  sending…"
                                        if (isFailed)  return sender + "  ·  failed"
                                        return sender
                                    }
                                    color: isFailed ? theme.error
                                         : isOwn   ? theme.accent
                                         :           theme.textMuted
                                    font.pixelSize: 11
                                    font.weight: Font.Medium
                                }

                                Text {
                                    width: parent.width
                                    text: modelData.displayText || modelData.data || ""
                                    color: isFailed  ? theme.error
                                         : isPending ? theme.textMuted
                                         :             theme.text
                                    font.pixelSize: theme.fontPrimary
                                    font.strikeout: isFailed
                                    wrapMode: Text.Wrap
                                    opacity: isPending ? 0.5 : 1.0
                                    visible: (modelData.displayText || modelData.data || "").length > 0
                                }

                                Repeater {
                                    model: modelData.media || []
                                    delegate: Item {
                                        width: parent.width
                                        height: mediaImg.status === Image.Ready
                                                ? mediaImg.paintedHeight + 8
                                                : (mediaPlaceholder.visible ? 40 : 0)

                                        Image {
                                            id: mediaImg
                                            width: Math.min(parent.width, 300)
                                            fillMode: Image.PreserveAspectFit
                                            source: {
                                                var p = backend.resolveMediaPath(modelData.cid)
                                                return p.length > 0 ? "file://" + p : ""
                                            }
                                            visible: source.toString().length > 0

                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: Qt.openUrlExternally(mediaImg.source)
                                            }
                                        }

                                        Rectangle {
                                            id: mediaPlaceholder
                                            visible: mediaImg.source.toString().length === 0
                                            width: 200; height: 32; radius: 4
                                            color: theme.surface
                                            Text {
                                                anchors.centerIn: parent
                                                text: "Loading image…"
                                                color: theme.textMuted
                                                font.pixelSize: 11
                                            }
                                            Component.onCompleted: backend.fetchMedia(modelData.cid)
                                        }
                                    }
                                }

                                Text {
                                    visible: (modelData.timestamp || "").length > 0
                                    text: modelData.timestamp || ""
                                    color: theme.textPlace
                                    font.pixelSize: 10
                                }
                            }
                        }
                    }

                    ScrollBar.vertical: ScrollBar {
                        policy: ScrollBar.AsNeeded
                    }
                }

                // Attachment preview
                Rectangle {
                    Layout.fillWidth: true
                    height: (backend.pendingAttachmentPreview || "").length > 0 ? 52 : 0
                    visible: (backend.pendingAttachmentPreview || "").length > 0
                    color: theme.bgSecondary
                    Behavior on height { NumberAnimation { duration: 120 } }

                    Rectangle {
                        anchors.top: parent.top
                        width: parent.width; height: 1
                        color: theme.borderSub
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 14
                        anchors.topMargin: 6
                        anchors.bottomMargin: 6
                        spacing: 8

                        Rectangle {
                            width: 36; height: 36; radius: 4
                            color: theme.surface
                            Text {
                                anchors.centerIn: parent
                                text: "\uD83D\uDDBC"
                                font.pixelSize: 18
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: backend.pendingAttachmentPreview || ""
                            color: theme.textSec
                            font.pixelSize: theme.fontSecondary
                            elide: Text.ElideMiddle
                        }
                        Button {
                            contentItem: Text {
                                text: "\u2715"
                                color: theme.textMuted
                                font.pixelSize: 14
                                horizontalAlignment: Text.AlignHCenter
                            }
                            background: Rectangle {
                                color: parent.down ? theme.error : theme.surface
                                radius: 4
                                implicitWidth: 28; implicitHeight: 28
                            }
                            onClicked: backend.clearAttachment()
                        }
                    }
                }

                // Compose bar
                Rectangle {
                    Layout.fillWidth: true
                    height: 56
                    color: theme.bgSecondary

                    Rectangle {
                        anchors.top: parent.top
                        width: parent.width; height: 1
                        color: theme.borderSub
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 14
                        anchors.topMargin: 8
                        anchors.bottomMargin: 8
                        spacing: 10

                        Button {
                            contentItem: Text {
                                text: "+"
                                color: theme.textMuted
                                font.pixelSize: 18
                                horizontalAlignment: Text.AlignHCenter
                            }
                            background: Rectangle {
                                color: parent.down ? theme.surface : "transparent"
                                radius: 6
                                implicitWidth: 36; implicitHeight: 36
                            }
                            ToolTip.visible: hovered
                            ToolTip.text: "Attach image"
                            onClicked: backend.openFilePicker()
                        }

                        TextField {
                            id: composeInput
                            Layout.fillWidth: true
                            placeholderText: "Type a message…"
                            placeholderTextColor: theme.textPlace
                            font.pixelSize: theme.fontPrimary
                            color: theme.text
                            background: Rectangle {
                                color: theme.bgInset
                                border.color: composeInput.activeFocus ? theme.accent : theme.borderSub
                                border.width: 1
                                radius: 6
                            }
                            enabled: backend.connected
                            Keys.onReturnPressed: doPublish()
                        }

                        Button {
                            text: backend.uploading ? "Uploading…" : "Publish"
                            font.pixelSize: theme.fontPrimary
                            enabled: backend.connected && !backend.uploading
                                     && (composeInput.text.length > 0
                                         || (backend.pendingAttachmentPreview || "").length > 0)
                            contentItem: Text {
                                text: parent.text
                                color: parent.enabled ? theme.text : theme.textMuted
                                font: parent.font
                                horizontalAlignment: Text.AlignHCenter
                            }
                            background: Rectangle {
                                color: parent.enabled
                                    ? (parent.down ? theme.accentHover : theme.accent)
                                    : theme.surface
                                radius: 6
                                implicitWidth: 80
                                implicitHeight: 36
                            }
                            onClicked: doPublish()
                        }

                        Button {
                            text: "⟳"
                            font.pixelSize: 16
                            ToolTip.visible: hovered
                            ToolTip.text: "Reset checkpoint"
                            contentItem: Text {
                                text: parent.text
                                color: theme.textMuted
                                font: parent.font
                                horizontalAlignment: Text.AlignHCenter
                            }
                            background: Rectangle {
                                color: parent.down ? theme.surface : "transparent"
                                radius: 6
                                implicitWidth: 36
                                implicitHeight: 36
                            }
                            onClicked: backend.resetCheckpoint()
                        }
                    }
                }

                // Status bar
                Rectangle {
                    Layout.fillWidth: true
                    height: 24
                    color: theme.bgElevated

                    Rectangle {
                        anchors.top: parent.top
                        width: parent.width; height: 1
                        color: theme.borderSub
                    }

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 14
                        anchors.verticalCenter: parent.verticalCenter
                        text: backend.status
                        color: theme.textPlace
                        font.pixelSize: 11
                    }
                }
            }
        }
    }

    // ── Setup dialog ─────────────────────────────────────────────────────────
    Rectangle {
        visible: root.showSetup
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.6)

        Rectangle {
            anchors.centerIn: parent
            width: 420; height: 340
            color: theme.bgSecondary
            border.color: theme.border
            border.width: 1
            radius: 12

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 24
                spacing: 14

                Text {
                    text: "Yolo Board"
                    color: theme.text
                    font.pixelSize: 18
                    font.weight: Font.Bold
                }
                Text {
                    text: "Enter the path to your Zone data directory\n(contains sequencer.key and channel.id)"
                    color: theme.textSec
                    font.pixelSize: theme.fontSecondary
                    lineHeight: 1.4
                    Layout.fillWidth: true
                }
                TextField {
                    id: dataDirInput
                    Layout.fillWidth: true
                    placeholderText: "Data directory…"
                    placeholderTextColor: theme.textPlace
                    font.pixelSize: theme.fontPrimary
                    color: theme.text
                    text: backend.dataDir
                    background: Rectangle {
                        color: theme.bgInset
                        border.color: dataDirInput.activeFocus ? theme.accent : theme.border
                        border.width: 1
                        radius: 6
                    }
                }
                TextField {
                    id: nodeInput
                    Layout.fillWidth: true
                    placeholderText: "Node URL (e.g. http://localhost:8080)"
                    placeholderTextColor: theme.textPlace
                    font.pixelSize: theme.fontPrimary
                    color: theme.text
                    text: backend.nodeUrl
                    background: Rectangle {
                        color: theme.bgInset
                        border.color: nodeInput.activeFocus ? theme.accent : theme.border
                        border.width: 1
                        radius: 6
                    }
                }
                TextField {
                    id: storageInput
                    Layout.fillWidth: true
                    placeholderText: "Storage URL (e.g. http://localhost:8090)"
                    placeholderTextColor: theme.textPlace
                    font.pixelSize: theme.fontPrimary
                    color: theme.text
                    text: backend.storageUrl
                    background: Rectangle {
                        color: theme.bgInset
                        border.color: storageInput.activeFocus ? theme.accent : theme.border
                        border.width: 1
                        radius: 6
                    }
                }
                Button {
                    Layout.fillWidth: true
                    text: "Connect"
                    font.pixelSize: theme.fontPrimary
                    font.weight: Font.Medium
                    enabled: dataDirInput.text.length > 0
                    contentItem: Text {
                        text: parent.text
                        color: theme.text
                        font: parent.font
                        horizontalAlignment: Text.AlignHCenter
                    }
                    background: Rectangle {
                        color: parent.enabled
                            ? (parent.down ? theme.accentHover : theme.accent)
                            : theme.surface
                        radius: 6
                        implicitHeight: 40
                    }
                    onClicked: {
                        backend.setDataDir(dataDirInput.text)
                        backend.setNodeUrl(nodeInput.text)
                        if (storageInput.text.length > 0)
                            backend.setStorageUrl(storageInput.text)
                        backend.connectToNode()
                    }
                }
            }
        }
    }

    // ── Functions ────────────────────────────────────────────────────────────
    function doSubscribe() {
        var ch = subInput.text.trim()
        if (ch.length > 0) {
            backend.subscribe(ch)
            subInput.text = ""
        }
    }

    function doPublish() {
        var msg = composeInput.text.trim()
        var hasAttachment = (backend.pendingAttachmentPreview || "").length > 0
        if (msg.length === 0 && !hasAttachment) return
        if (hasAttachment) {
            backend.publishWithAttachment(msg)
        } else {
            backend.publish(msg)
        }
        composeInput.text = ""
    }

    Connections {
        target: backend
        function onMessagesChanged() {
            messageList.positionViewAtEnd()
        }
    }
}
