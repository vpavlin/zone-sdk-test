import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    width: 900
    height: 600
    color: theme.bg

    readonly property bool basecampMode: typeof logos !== "undefined" && logos !== null

    // ── State (fetched from yolo_board_module via get_state polling) ────────
    property var stateSnapshot: ({})
    property var channelList: []
    property var messagesList: []
    property string lastMessagesJson: ""
    property var mediaPaths: ({})
    property int currentChannelIndex: 0
    property string pendingAttachment: ""

    // Derived from stateSnapshot
    readonly property string ownChannelId: stateSnapshot.ownChannelId || ""
    readonly property string ownChannelName: stateSnapshot.ownChannelName || ""
    readonly property bool isConnected: stateSnapshot.connected === true
    readonly property string statusText: stateSnapshot.status || "Waiting\u2026"
    readonly property string nodeUrl: stateSnapshot.nodeUrl || "http://localhost:8080"
    readonly property string dataDir: stateSnapshot.dataDir || ""
    readonly property bool isUploading: stateSnapshot.uploading === true
    readonly property bool storageIsReady: stateSnapshot.storageReady === true
    readonly property bool sequencerStarting: stateSnapshot.sequencerStarting === true
    readonly property bool storageStarting:   stateSnapshot.storageStarting === true
    readonly property string storagePeerId:          stateSnapshot.storagePeerId || ""
    readonly property string storageSpr:             stateSnapshot.storageSpr || ""
    readonly property var    storageListenAddrs:     stateSnapshot.storageListenAddrs   || []
    readonly property var    storageAnnounceAddrs:   stateSnapshot.storageAnnounceAddrs || []

    function storageTooltip() {
        if (!storageIsReady) {
            return storageStarting ? "Storage starting\u2026" : "Storage offline"
        }
        var lines = []
        if (storagePeerId.length > 0) lines.push("peer id: " + storagePeerId)
        if (storageListenAddrs.length > 0) lines.push("listen: " + storageListenAddrs.join("\n        "))
        if (storageAnnounceAddrs.length > 0) lines.push("announce: " + storageAnnounceAddrs.join("\n          "))
        if (storageSpr.length > 0) {
            var short = storageSpr.length > 60 ? (storageSpr.substring(0, 28) + "\u2026" + storageSpr.substring(storageSpr.length - 28)) : storageSpr
            lines.push("spr: " + short)
        }
        return lines.length > 0 ? lines.join("\n") : "Storage ready"
    }
    readonly property var backfillProgressMap: stateSnapshot.backfillProgress || ({})

    property bool showSetup: ownChannelId === ""

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
        readonly property color notify:      "#FB3748"
        readonly property color error:       "#FB3748"
        readonly property int fontPrimary:   14
        readonly property int fontSecondary: 12
    }

    palette.highlight: theme.accent
    palette.highlightedText: theme.text

    function call(method, args) {
        if (!basecampMode) return ""
        return logos.callModule("yolo_board_module", method, args || [])
    }

    function refresh() {
        var s = call("get_state", [])
        try {
            stateSnapshot = JSON.parse(s)
            if (stateSnapshot.channels) channelList = stateSnapshot.channels
        } catch(e) {}
        loadMessagesForCurrent()
    }

    function loadMessagesForCurrent() {
        if (channelList.length === 0) return
        var idx = currentChannelIndex
        if (idx < 0 || idx >= channelList.length) idx = 0
        var chId = channelList[idx].id
        var json = call("get_messages", [chId])
        // Skip reassign when the payload hasn't changed — otherwise the
        // ListView resets scroll position on every poll.
        var key = chId + "|" + json
        if (key === lastMessagesJson) return
        lastMessagesJson = key
        try {
            // Newest first so the default (top) scroll position shows recent.
            // Dedupe by data: there are real on-chain duplicates from a
            // prior upload-retry race, plus pending+confirmed both stick
            // around briefly. Keep the first occurrence (= newest after reverse).
            var raw = (JSON.parse(json) || []).reverse()
            var seen = {}
            var deduped = []
            for (var i = 0; i < raw.length; i++) {
                var k = raw[i].data || raw[i].id || ""
                if (seen[k]) continue
                seen[k] = true
                deduped.push(raw[i])
            }
            messagesList = deduped
        } catch(e) { messagesList = [] }
    }

    function channelDisplayName(id) {
        for (var i = 0; i < channelList.length; i++)
            if (channelList[i].id === id) return channelList[i].name
        if (id.length > 12) return id.substr(0, 12) + "\u2026"
        return id
    }

    function doConnect() {
        call("configure", [dataDirInput.text.trim(), nodeInput.text.trim()])
        // Configure returns "pending" immediately — state arrives via subsequent get_state polls
    }

    function doSubscribe() {
        var ch = subInput.text.trim()
        if (ch.length === 0) return
        subInput.text = ""
        call("subscribe", [ch])
        refresh()
    }

    function doUnsubscribe() {
        if (channelList.length === 0) return
        var chId = channelList[currentChannelIndex].id
        call("unsubscribe", [chId])
        if (currentChannelIndex >= channelList.length - 1)
            currentChannelIndex = Math.max(0, channelList.length - 2)
        refresh()
    }

    function doSelectChannel(index) {
        if (index < 0 || index >= channelList.length) return
        currentChannelIndex = index
        var chId = channelList[index].id
        call("clear_unread", [chId])
        loadMessagesForCurrent()
    }

    function doPublish() {
        var msg = composeInput.text.trim()
        var hasAttach = pendingAttachment.length > 0
        if (msg.length === 0 && !hasAttach) return
        composeInput.text = ""
        if (hasAttach) {
            call("publish_with_attachment", [msg, pendingAttachment])
            pendingAttachment = ""
        } else {
            call("publish", [msg])
        }
        // refresh shortly to pick up the optimistic pending message
        refreshSoon.start()
    }

    function doStartBackfill(channelId) {
        call("start_backfill", [channelId])
    }
    function doStopBackfill(channelId) {
        call("stop_backfill", [channelId])
    }
    function doResetCheckpoint() {
        call("reset_checkpoint", [])
    }
    function doFetchMedia(cid) {
        call("fetch_media", [cid])
    }
    // Look up a CID. Reads mediaPaths reactively so source bindings update
    // when the path dictionary changes. Side-effectful population happens
    // in ensureResolved() below — never inside a binding, to avoid loops.
    function mediaPathFor(cid) {
        return mediaPaths[cid] || ""
    }
    function ensureResolved(cid) {
        if (!cid || cid === "uploading") return
        if (mediaPaths[cid]) return
        var p = call("resolve_media", [cid])
        if (p && p.length > 0) {
            var mp = Object.assign({}, mediaPaths)
            mp[cid] = p
            mediaPaths = mp
        }
    }

    Timer { id: refreshSoon; interval: 200; repeat: false; onTriggered: refresh() }

    Timer {
        id: refreshTimer
        interval: 2000
        repeat: true
        running: basecampMode
        onTriggered: refresh()
    }

    Component.onCompleted: {
        if (basecampMode) {
            // Tell the module our QML dir so it can mirror images here
            // (the host sandbox blocks file:// outside the plugin root).
            var url = Qt.resolvedUrl(".").toString()
            if (url.startsWith("file://")) url = url.substring(7)
            while (url.endsWith("/")) url = url.substring(0, url.length - 1)
            call("set_ui_dir", [url])

            // Load saved config to pre-populate setup fields
            var cfg = call("load_saved_config", [])
            try {
                var c = JSON.parse(cfg)
                if (c.dataDir) stateSnapshot = Object.assign({}, stateSnapshot, { dataDir: c.dataDir })
                if (c.nodeUrl) stateSnapshot = Object.assign({}, stateSnapshot, { nodeUrl: c.nodeUrl })
            } catch(e) {}
            refresh()
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Rectangle {
            Layout.fillWidth: true; height: 44; color: theme.bgElevated
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 16; anchors.rightMargin: 16; spacing: 10
                Text {
                    id: seqIcon
                    text: "\u2B21"; font.pixelSize: 16
                    color: isConnected ? theme.accent : theme.textPlace
                    ToolTip.visible: hovered ?? false
                    ToolTip.text: isConnected ? "Sequencer connected" : (sequencerStarting ? "Sequencer starting…" : "Sequencer disconnected")
                    // Fade between grey and orange while starting.
                    SequentialAnimation on color {
                        loops: Animation.Infinite
                        running: sequencerStarting && !isConnected
                        ColorAnimation { from: theme.textPlace; to: theme.accent; duration: 700 }
                        ColorAnimation { from: theme.accent;    to: theme.textPlace; duration: 700 }
                    }
                }
                Text {
                    id: storageIcon
                    text: "\u25A4"; font.pixelSize: 14
                    color: storageIsReady ? theme.accent : theme.textPlace
                    Layout.preferredWidth: 18
                    Layout.preferredHeight: 18
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    SequentialAnimation on color {
                        loops: Animation.Infinite
                        running: storageStarting && !storageIsReady
                        ColorAnimation { from: theme.textPlace; to: theme.accent; duration: 700 }
                        ColorAnimation { from: theme.accent;    to: theme.textPlace; duration: 700 }
                    }
                    MouseArea {
                        id: storageHover
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: storageInfoDialog.open()
                        ToolTip.visible: containsMouse
                        ToolTip.text: storageTooltip()
                        ToolTip.delay: 200
                        ToolTip.timeout: 15000
                    }
                }
                Text {
                    text: "Yolo Board"; color: theme.text
                    font.pixelSize: 16; font.weight: Font.Bold
                }
                Item { Layout.fillWidth: true }
                Text { text: ownChannelName; color: theme.textMuted; font.pixelSize: theme.fontSecondary }
                Rectangle { width: 1; height: 20; color: theme.border; visible: nodeUrl.length > 0 }
                Text { text: nodeUrl; color: theme.textMuted; font.pixelSize: theme.fontSecondary; visible: nodeUrl.length > 0 }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: theme.borderSub }
        }

        RowLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: 0

            Rectangle {
                Layout.preferredWidth: 200; Layout.fillHeight: true; color: theme.bgSecondary
                ColumnLayout {
                    anchors.fill: parent; spacing: 0
                    Item {
                        Layout.fillWidth: true; height: 36
                        Text {
                            anchors.left: parent.left; anchors.leftMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            text: "CHANNELS"; color: theme.textMuted
                            font.pixelSize: 11; font.weight: Font.Medium; font.letterSpacing: 1
                        }
                    }

                    ListView {
                        id: channelListView
                        Layout.fillWidth: true; Layout.fillHeight: true
                        clip: true
                        model: channelList
                        delegate: Column {
                            id: chDelegate
                            width: channelListView.width
                            required property var modelData
                            required property int index
                            property string chId: modelData.id || ""
                            property real backfillProg: backfillProgressMap[chId] || -1
                            property bool backfilling: backfillProg >= 0
                            property bool selected: index === currentChannelIndex
                            property bool hovered: chMouse.containsMouse

                            Rectangle {
                                width: chDelegate.width; height: 36
                                color: chDelegate.selected ? theme.surface
                                     : chDelegate.hovered ? Qt.rgba(1,1,1,0.04) : "transparent"
                                radius: 4
                                MouseArea { id: chMouse; anchors.fill: parent; hoverEnabled: true; onClicked: doSelectChannel(chDelegate.index) }
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 12; anchors.rightMargin: 8; spacing: 6
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.name || ""
                                        color: chDelegate.selected ? theme.text
                                             : modelData.isOwn ? theme.accent
                                             : theme.textSec
                                        font.pixelSize: theme.fontSecondary
                                        font.weight: chDelegate.selected ? Font.Medium : Font.Normal
                                        elide: Text.ElideRight
                                    }
                                    Rectangle {
                                        visible: chDelegate.backfilling || chDelegate.selected
                                        width: 20; height: 20; radius: 10; z: 1
                                        color: chDelegate.backfilling ? theme.accent : "transparent"
                                        border.color: chDelegate.backfilling ? "transparent" : theme.border
                                        border.width: 1
                                        Text {
                                            anchors.centerIn: parent
                                            text: "\u27F3"
                                            color: chDelegate.backfilling ? theme.text : theme.textMuted
                                            font.pixelSize: 12
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            onClicked: chDelegate.backfilling
                                                ? doStopBackfill(chDelegate.chId)
                                                : doStartBackfill(chDelegate.chId)
                                        }
                                    }
                                    Rectangle {
                                        visible: (modelData.unread || 0) > 0
                                        width: 22; height: 18; radius: 9
                                        color: theme.notify
                                        Text {
                                            anchors.centerIn: parent
                                            text: modelData.unread || 0
                                            color: theme.text; font.pixelSize: 10; font.weight: Font.Bold
                                        }
                                    }
                                }
                            }
                            Item {
                                visible: chDelegate.backfilling
                                width: chDelegate.width; height: visible ? 14 : 0
                                Rectangle {
                                    anchors.left: parent.left; anchors.leftMargin: 12
                                    anchors.right: pctLabel.left; anchors.rightMargin: 4
                                    anchors.verticalCenter: parent.verticalCenter
                                    height: 3; radius: 2; color: theme.surface
                                    Rectangle {
                                        width: chDelegate.backfillProg * parent.width
                                        height: parent.height; color: theme.accent; radius: 2
                                        Behavior on width { SmoothedAnimation { velocity: 80 } }
                                    }
                                }
                                Text {
                                    id: pctLabel
                                    anchors.right: parent.right; anchors.rightMargin: 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: Math.round(chDelegate.backfillProg * 100) + "%"
                                    color: theme.textMuted; font.pixelSize: 9
                                }
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true; height: 72; color: theme.bgElevated
                        ColumnLayout {
                            anchors.fill: parent; anchors.margins: 8; spacing: 6
                            TextField {
                                id: subInput
                                Layout.fillWidth: true
                                placeholderText: "Channel name or ID\u2026"
                                placeholderTextColor: theme.textPlace
                                font.pixelSize: theme.fontSecondary; color: theme.text
                                background: Rectangle { color: theme.bgInset; border.color: theme.borderSub; border.width: 1; radius: 4 }
                                Keys.onReturnPressed: doSubscribe()
                            }
                            RowLayout {
                                spacing: 6
                                Button {
                                    Layout.fillWidth: true; text: "Subscribe"; font.pixelSize: theme.fontSecondary
                                    contentItem: Text { text: parent.text; color: theme.text; font: parent.font; horizontalAlignment: Text.AlignHCenter }
                                    background: Rectangle { color: parent.down ? theme.accentHover : theme.surface; radius: 4 }
                                    onClicked: doSubscribe()
                                }
                                Button {
                                    text: "\u2715"; font.pixelSize: theme.fontSecondary
                                    contentItem: Text { text: parent.text; color: theme.textSec; font: parent.font; horizontalAlignment: Text.AlignHCenter }
                                    background: Rectangle { color: parent.down ? theme.error : theme.surface; radius: 4 }
                                    enabled: channelList.length > 0
                                    onClicked: doUnsubscribe()
                                }
                            }
                        }
                    }
                }
                Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: theme.borderSub }
            }

            ColumnLayout {
                Layout.fillWidth: true; Layout.fillHeight: true; spacing: 0

                ListView {
                    id: messageList
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true; spacing: 1
                    model: messagesList

                    DropArea {
                        anchors.fill: parent
                        onEntered: (drag) => { drag.accept(Qt.CopyAction); dropHint.visible = true }
                        onExited: dropHint.visible = false
                        onDropped: (drop) => {
                            dropHint.visible = false
                            if (drop.hasUrls && drop.urls.length > 0) {
                                var p = drop.urls[0].toString()
                                if (p.startsWith("file://")) p = p.substring(7)
                                pendingAttachment = p
                            }
                        }
                    }
                    Rectangle {
                        id: dropHint
                        visible: false
                        anchors.fill: parent
                        color: Qt.rgba(0.93, 0.48, 0.34, 0.15)
                        border.color: theme.accent; border.width: 2; z: 100
                        Text {
                            anchors.centerIn: parent; text: "Drop image to attach"
                            color: theme.accent; font.pixelSize: 18; font.weight: Font.Bold
                        }
                    }

                    delegate: Rectangle {
                        width: messageList.width
                        height: msgCol.implicitHeight + 16
                        color: msgHover.containsMouse ? Qt.rgba(1,1,1,0.02) : "transparent"
                        required property var modelData
                        readonly property bool isOwn: modelData.isOwn === true
                        readonly property bool isPending: modelData.pending === true
                        readonly property bool isFailed: modelData.failed === true
                        MouseArea { id: msgHover; anchors.fill: parent; hoverEnabled: true }
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 14; anchors.rightMargin: 14; anchors.topMargin: 6; spacing: 8
                            Rectangle {
                                visible: isOwn; width: 3; Layout.fillHeight: true
                                color: theme.accent; radius: 2
                            }
                            Column {
                                id: msgCol
                                Layout.fillWidth: true; spacing: 3
                                Text {
                                    text: {
                                        var sender = isOwn ? "you" : channelDisplayName(modelData.channel || "")
                                        if (isPending) return sender + "  \u00B7  sending\u2026"
                                        if (isFailed) return sender + "  \u00B7  failed"
                                        return sender
                                    }
                                    color: isFailed ? theme.error : isOwn ? theme.accent : theme.textMuted
                                    font.pixelSize: 11; font.weight: Font.Medium
                                }
                                Text {
                                    width: parent.width
                                    text: modelData.displayText || modelData.data || ""
                                    color: isFailed ? theme.error : isPending ? theme.textMuted : theme.text
                                    font.pixelSize: theme.fontPrimary
                                    font.strikeout: isFailed
                                    wrapMode: Text.Wrap
                                    opacity: isPending ? 0.5 : 1.0
                                    visible: (modelData.displayText || modelData.data || "").length > 0
                                }
                                Repeater {
                                    id: mediaRepeater
                                    model: modelData.media || []
                                    delegate: Item {
                                        id: mediaSlot
                                        property var entry: mediaRepeater.model[index]
                                        property string cid: entry ? (entry.cid || "") : ""
                                        property string resolvedPath: mediaPathFor(cid)
                                        width: msgCol.width
                                        height: mediaImg.status === Image.Ready
                                                ? mediaImg.paintedHeight + 8
                                                : 40
                                        Image {
                                            id: mediaImg
                                            width: Math.min(parent.width, 300)
                                            fillMode: Image.PreserveAspectFit
                                            asynchronous: true
                                            cache: false
                                            source: mediaSlot.resolvedPath.length > 0
                                                    ? "file://" + mediaSlot.resolvedPath
                                                    : ""
                                            visible: status === Image.Ready
                                            MouseArea {
                                                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                            }
                                        }
                                        Rectangle {
                                            visible: mediaImg.status !== Image.Ready
                                            width: 200; height: 32; radius: 4
                                            color: theme.surface
                                            Text {
                                                anchors.centerIn: parent
                                                text: mediaSlot.cid === "uploading" ? "Uploading\u2026"
                                                      : mediaImg.status === Image.Error ? "Image unavailable"
                                                      : mediaSlot.resolvedPath.length === 0 ? "Fetching\u2026"
                                                      : "Loading image\u2026"
                                                color: theme.textMuted; font.pixelSize: 11
                                            }
                                        }
                                        Component.onCompleted: {
                                            if (!cid || cid === "uploading") return
                                            ensureResolved(cid)
                                            if (mediaPathFor(cid).length === 0)
                                                doFetchMedia(cid)
                                        }
                                    }
                                }
                                Text {
                                    visible: (modelData.timestamp || "").length > 0
                                    text: modelData.timestamp || ""
                                    color: theme.textPlace; font.pixelSize: 10
                                }
                            }
                        }
                    }
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: pendingAttachment.length > 0 ? 52 : 0
                    visible: pendingAttachment.length > 0
                    color: theme.bgSecondary
                    Behavior on height { NumberAnimation { duration: 120 } }
                    Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: theme.borderSub }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 14; anchors.rightMargin: 14; anchors.topMargin: 6; anchors.bottomMargin: 6
                        spacing: 8
                        Rectangle {
                            width: 36; height: 36; radius: 4; color: theme.surface
                            Text { anchors.centerIn: parent; text: "\uD83D\uDDBC"; font.pixelSize: 18 }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: pendingAttachment.split("/").pop()
                            color: theme.textSec; font.pixelSize: theme.fontSecondary
                            elide: Text.ElideMiddle
                        }
                        Button {
                            contentItem: Text { text: "\u2715"; color: theme.textMuted; font.pixelSize: 14; horizontalAlignment: Text.AlignHCenter }
                            background: Rectangle { color: parent.down ? theme.error : theme.surface; radius: 4; implicitWidth: 28; implicitHeight: 28 }
                            onClicked: pendingAttachment = ""
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true; height: 56; color: theme.bgSecondary
                    Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: theme.borderSub }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 14; anchors.rightMargin: 14
                        anchors.topMargin: 8; anchors.bottomMargin: 8
                        spacing: 10
                        Button {
                            contentItem: Text { text: "+"; color: theme.textMuted; font.pixelSize: 18; horizontalAlignment: Text.AlignHCenter }
                            background: Rectangle { color: parent.down ? theme.surface : "transparent"; radius: 6; implicitWidth: 36; implicitHeight: 36 }
                            ToolTip.visible: hovered
                            ToolTip.text: "Attach image (or drag-drop onto messages)"
                            onClicked: attachPathDialog.open()
                        }
                        TextField {
                            id: composeInput
                            Layout.fillWidth: true
                            placeholderText: "Type a message\u2026"
                            placeholderTextColor: theme.textPlace
                            font.pixelSize: theme.fontPrimary; color: theme.text
                            background: Rectangle {
                                color: theme.bgInset
                                border.color: composeInput.activeFocus ? theme.accent : theme.borderSub
                                border.width: 1; radius: 6
                            }
                            enabled: isConnected
                            Keys.onReturnPressed: doPublish()
                        }
                        Button {
                            text: isUploading ? "Uploading\u2026" : "Publish"
                            font.pixelSize: theme.fontPrimary
                            enabled: isConnected && !isUploading
                                     && (composeInput.text.length > 0 || pendingAttachment.length > 0)
                            contentItem: Text { text: parent.text; color: parent.enabled ? theme.text : theme.textMuted; font: parent.font; horizontalAlignment: Text.AlignHCenter }
                            background: Rectangle {
                                color: parent.enabled ? (parent.down ? theme.accentHover : theme.accent) : theme.surface
                                radius: 6; implicitWidth: 80; implicitHeight: 36
                            }
                            onClicked: doPublish()
                        }
                        Button {
                            text: "\u27F3"; font.pixelSize: 16
                            ToolTip.visible: hovered
                            ToolTip.text: "Reset checkpoint"
                            contentItem: Text { text: parent.text; color: theme.textMuted; font: parent.font; horizontalAlignment: Text.AlignHCenter }
                            background: Rectangle { color: parent.down ? theme.surface : "transparent"; radius: 6; implicitWidth: 36; implicitHeight: 36 }
                            onClicked: doResetCheckpoint()
                        }
                        Button {
                            text: "\u26D3"; font.pixelSize: 16
                            ToolTip.visible: hovered
                            ToolTip.text: "Connect storage peer"
                            contentItem: Text { text: parent.text; color: theme.textMuted; font: parent.font; horizontalAlignment: Text.AlignHCenter }
                            background: Rectangle { color: parent.down ? theme.surface : "transparent"; radius: 6; implicitWidth: 36; implicitHeight: 36 }
                            onClicked: connectPeerDialog.open()
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true; height: 24; color: theme.bgElevated
                    Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: theme.borderSub }
                    Text {
                        anchors.left: parent.left; anchors.leftMargin: 14
                        anchors.verticalCenter: parent.verticalCenter
                        text: statusText; color: theme.textPlace; font.pixelSize: 11
                    }
                }
            }
        }
    }

    Rectangle {
        visible: root.showSetup
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.6)
        Rectangle {
            anchors.centerIn: parent
            width: 420; height: 280
            color: theme.bgSecondary
            border.color: theme.border; border.width: 1; radius: 12
            ColumnLayout {
                anchors.fill: parent; anchors.margins: 24; spacing: 14
                Text { text: "Yolo Board"; color: theme.text; font.pixelSize: 18; font.weight: Font.Bold }
                Text {
                    text: "Enter the path to your Zone data directory\n(contains sequencer.key and channel.id)"
                    color: theme.textSec; font.pixelSize: theme.fontSecondary
                    lineHeight: 1.4; Layout.fillWidth: true
                }
                TextField {
                    id: dataDirInput
                    Layout.fillWidth: true
                    placeholderText: "Data directory\u2026"
                    placeholderTextColor: theme.textPlace
                    font.pixelSize: theme.fontPrimary; color: theme.text
                    text: dataDir
                    background: Rectangle { color: theme.bgInset; border.color: dataDirInput.activeFocus ? theme.accent : theme.border; border.width: 1; radius: 6 }
                }
                TextField {
                    id: nodeInput
                    Layout.fillWidth: true
                    placeholderText: "Node URL"
                    placeholderTextColor: theme.textPlace
                    font.pixelSize: theme.fontPrimary; color: theme.text
                    text: nodeUrl
                    background: Rectangle { color: theme.bgInset; border.color: nodeInput.activeFocus ? theme.accent : theme.border; border.width: 1; radius: 6 }
                }
                Button {
                    Layout.fillWidth: true
                    text: "Connect"; font.pixelSize: theme.fontPrimary; font.weight: Font.Medium
                    enabled: dataDirInput.text.length > 0
                    contentItem: Text { text: parent.text; color: theme.text; font: parent.font; horizontalAlignment: Text.AlignHCenter }
                    background: Rectangle { color: parent.enabled ? (parent.down ? theme.accentHover : theme.accent) : theme.surface; radius: 6; implicitHeight: 40 }
                    onClicked: doConnect()
                }
            }
        }
    }

    Dialog {
        id: attachPathDialog
        title: "Attach Image"
        anchors.centerIn: parent
        width: 420; modal: true
        standardButtons: Dialog.Ok | Dialog.Cancel
        background: Rectangle { color: theme.bgSecondary; border.color: theme.border; border.width: 1; radius: 12 }
        header: Item {
            height: 40
            Text {
                anchors.left: parent.left; anchors.leftMargin: 24
                anchors.verticalCenter: parent.verticalCenter
                text: "Attach Image"; color: theme.text
                font.pixelSize: 16; font.weight: Font.Bold
            }
        }
        contentItem: ColumnLayout {
            spacing: 10
            Text { text: "Enter the full path to the image file (or drag-drop onto messages)"; color: theme.textSec; font.pixelSize: theme.fontSecondary }
            TextField {
                id: attachPathInput
                Layout.fillWidth: true
                placeholderText: "/path/to/image.png"
                placeholderTextColor: theme.textPlace
                font.pixelSize: theme.fontPrimary; color: theme.text
                background: Rectangle { color: theme.bgInset; border.color: attachPathInput.activeFocus ? theme.accent : theme.border; border.width: 1; radius: 6 }
            }
        }
        onAccepted: {
            var p = attachPathInput.text.trim()
            if (p.length > 0) pendingAttachment = p
            attachPathInput.text = ""
        }
        onRejected: attachPathInput.text = ""
    }

    Dialog {
        id: storageInfoDialog
        title: "Storage Node"
        anchors.centerIn: parent
        width: 620; modal: true
        padding: 20
        background: Rectangle { color: theme.bgSecondary; border.color: theme.border; border.width: 1; radius: 12 }
        header: Item {
            height: 40
            Text {
                anchors.left: parent.left; anchors.leftMargin: 24
                anchors.verticalCenter: parent.verticalCenter
                text: "Storage Node"; color: theme.text
                font.pixelSize: 16; font.weight: Font.Bold
            }
        }
        contentItem: ColumnLayout {
            spacing: 10
            Text {
                text: "Identity + listen addresses for this node. Share the SPR with NAT'd peers and set up port-forwarding for any listen port you want reachable from the public internet."
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                color: theme.textSec
                font.pixelSize: theme.fontSecondary
            }
            Text { text: storageIsReady ? "Ready" : "Not ready"; color: storageIsReady ? theme.accent : theme.textPlace; font.pixelSize: theme.fontSecondary }

            Text { text: "Peer ID"; color: theme.textMuted; font.pixelSize: theme.fontSecondary }
            TextField {
                text: storagePeerId
                readOnly: true
                selectByMouse: true
                Layout.fillWidth: true
                font.pixelSize: theme.fontPrimary; color: theme.text
                background: Rectangle { color: theme.bgInset; border.color: theme.border; border.width: 1; radius: 6 }
            }

            Text { text: "SPR"; color: theme.textMuted; font.pixelSize: theme.fontSecondary }
            TextField {
                text: storageSpr
                readOnly: true
                selectByMouse: true
                Layout.fillWidth: true
                font.pixelSize: theme.fontSecondary; color: theme.text
                background: Rectangle { color: theme.bgInset; border.color: theme.border; border.width: 1; radius: 6 }
            }

            Text { text: "Listen addresses (ports to forward)"; color: theme.textMuted; font.pixelSize: theme.fontSecondary }
            Repeater {
                model: storageListenAddrs
                delegate: TextField {
                    text: modelData
                    readOnly: true; selectByMouse: true
                    Layout.fillWidth: true
                    font.pixelSize: theme.fontSecondary; color: theme.text
                    background: Rectangle { color: theme.bgInset; border.color: theme.border; border.width: 1; radius: 6 }
                }
            }

            Text { text: "Announce addresses"; color: theme.textMuted; font.pixelSize: theme.fontSecondary }
            Repeater {
                model: storageAnnounceAddrs
                delegate: TextField {
                    text: modelData
                    readOnly: true; selectByMouse: true
                    Layout.fillWidth: true
                    font.pixelSize: theme.fontSecondary; color: theme.text
                    background: Rectangle { color: theme.bgInset; border.color: theme.border; border.width: 1; radius: 6 }
                }
            }

            Item { Layout.fillHeight: true; Layout.minimumHeight: 4 }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                Button {
                    text: "Close"
                    font.pixelSize: theme.fontPrimary
                    contentItem: Text { text: parent.text; color: theme.text; font: parent.font; horizontalAlignment: Text.AlignHCenter }
                    background: Rectangle {
                        color: parent.down ? theme.border : theme.surface
                        radius: 6; implicitWidth: 80; implicitHeight: 34
                    }
                    onClicked: storageInfoDialog.close()
                }
            }
        }
    }

    Dialog {
        id: connectPeerDialog
        title: "Connect Storage Peer"
        anchors.centerIn: parent
        width: 520; modal: true
        padding: 20
        background: Rectangle { color: theme.bgSecondary; border.color: theme.border; border.width: 1; radius: 12 }
        property string lastResult: ""
        onAboutToShow: {
            peerIdInput.text = stateSnapshot.savedPeerId || ""
            peerAddrsInput.text = stateSnapshot.savedPeerAddrs || ""
            lastResult = ""
        }
        header: Item {
            height: 40
            Text {
                anchors.left: parent.left; anchors.leftMargin: 24
                anchors.verticalCenter: parent.verticalCenter
                text: "Connect Storage Peer"; color: theme.text
                font.pixelSize: 16; font.weight: Font.Bold
            }
        }
        contentItem: ColumnLayout {
            spacing: 10
            Text {
                text: "Dial a public storage node so your CIDs can propagate even when you're behind NAT. Paste the peer id and (optionally) one or more multiaddrs."
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                color: theme.textSec
                font.pixelSize: theme.fontSecondary
            }
            Text { text: "Peer id"; color: theme.textMuted; font.pixelSize: theme.fontSecondary }
            TextField {
                id: peerIdInput
                Layout.fillWidth: true
                placeholderText: "16Uiu2HAm\u2026"
                placeholderTextColor: theme.textPlace
                font.pixelSize: theme.fontPrimary; color: theme.text
                background: Rectangle { color: theme.bgInset; border.color: peerIdInput.activeFocus ? theme.accent : theme.border; border.width: 1; radius: 6 }
            }
            Text { text: "Multiaddrs (comma-separated, optional)"; color: theme.textMuted; font.pixelSize: theme.fontSecondary }
            TextField {
                id: peerAddrsInput
                Layout.fillWidth: true
                placeholderText: "/ip4/1.2.3.4/tcp/4001, \u2026"
                placeholderTextColor: theme.textPlace
                font.pixelSize: theme.fontPrimary; color: theme.text
                background: Rectangle { color: theme.bgInset; border.color: peerAddrsInput.activeFocus ? theme.accent : theme.border; border.width: 1; radius: 6 }
            }
            Text {
                text: connectPeerDialog.lastResult
                visible: connectPeerDialog.lastResult.length > 0
                color: theme.textSec
                font.pixelSize: theme.fontSecondary
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                Layout.topMargin: 4
            }
            Item { Layout.fillHeight: true; Layout.minimumHeight: 8 }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Item { Layout.fillWidth: true }
                Button {
                    text: "Close"
                    font.pixelSize: theme.fontPrimary
                    contentItem: Text { text: parent.text; color: theme.text; font: parent.font; horizontalAlignment: Text.AlignHCenter }
                    background: Rectangle {
                        color: parent.down ? theme.border : theme.surface
                        radius: 6; implicitWidth: 80; implicitHeight: 34
                    }
                    onClicked: connectPeerDialog.close()
                }
                Button {
                    text: "Connect"
                    font.pixelSize: theme.fontPrimary
                    enabled: peerIdInput.text.trim().length > 0
                    contentItem: Text { text: parent.text; color: parent.enabled ? theme.text : theme.textMuted; font: parent.font; horizontalAlignment: Text.AlignHCenter }
                    background: Rectangle {
                        color: parent.enabled ? (parent.down ? theme.accentHover : theme.accent) : theme.surface
                        radius: 6; implicitWidth: 100; implicitHeight: 34
                    }
                    onClicked: {
                        var r = call("connect_storage_peer",
                                     [peerIdInput.text.trim(), peerAddrsInput.text.trim()])
                        connectPeerDialog.lastResult = r || "(no response)"
                    }
                }
            }
        }
        onClosed: { lastResult = "" }
    }
}
