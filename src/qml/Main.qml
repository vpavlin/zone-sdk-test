import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

Rectangle {
    id: root
    width: 900
    height: 600
    color: theme.bg

    // ── Backend access ──────────────────────────────────────────────────────
    // Basecamp injects "logos" (LogosQmlBridge) for IPC to core modules.
    // Standalone injects "backend" (YoloBoardBackend C++ object).
    readonly property bool basecampMode: typeof logos !== "undefined" && logos !== null
    readonly property var api: basecampMode ? null : (typeof backend !== "undefined" ? backend : null)

    // ── State (managed in QML for Basecamp mode) ────────────────────────────
    property var channelList: []
    property var messagesList: []
    property int currentChannelIndex: 0
    property string ownChannelId: ""
    property bool isConnected: false
    property string statusText: "Waiting for configuration..."
    property var unreadCounts: ({})
    property string nodeUrl: "http://localhost:8080"
    property var backfillProgressMap: ({})
    property string dataDir: ""
    property string pendingAttachment: ""
    property bool isUploading: false
    property bool storageIsReady: false
    property int pollTimerId: -1

    Component.onCompleted: {
        if (basecampMode) startupTimer.start()
    }
    Timer {
        id: startupTimer
        interval: 500
        repeat: false
        onTriggered: {
            var cfg = callZone("load_ui_config", [])
            try {
                var c = JSON.parse(cfg)
                if (c.dataDir) dataDir = c.dataDir
                if (c.nodeUrl) nodeUrl = c.nodeUrl
            } catch(e) {}
        }
    }

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

    // ── Helpers for dual mode ───────────────────────────────────────────────

    function getChannelList() {
        if (!basecampMode) return api ? api.channelList : []
        return channelList
    }
    function getMessages() {
        if (!basecampMode) return api ? api.messages : []
        return messagesList
    }
    function getCurrentChannelIndex() {
        if (!basecampMode) return api ? api.currentChannelIndex : 0
        return currentChannelIndex
    }
    function getOwnChannelId() {
        if (!basecampMode) return api ? api.ownChannelId : ""
        return ownChannelId
    }
    function getConnected() {
        if (!basecampMode) return api ? api.connected : false
        return isConnected
    }
    function getStatus() {
        if (!basecampMode) return api ? api.status : ""
        return statusText
    }
    function getUnreadCounts() {
        if (!basecampMode) return api ? api.unreadCounts : ({})
        return unreadCounts
    }
    function getNodeUrl() {
        if (!basecampMode) return api ? api.nodeUrl : ""
        return nodeUrl
    }
    function getBackfillProgress() {
        if (!basecampMode) return api ? api.backfillProgress : ({})
        return backfillProgressMap
    }
    function getDataDir() {
        if (!basecampMode) return api ? api.dataDir : ""
        return dataDir
    }
    function getPendingAttachment() {
        if (!basecampMode) return api ? (api.pendingAttachmentPreview || "") : ""
        return pendingAttachment
    }
    function getUploading() {
        if (!basecampMode) return api ? api.uploading : false
        return isUploading
    }
    function getStorageReady() {
        if (!basecampMode) return api ? api.storageReady : false
        return storageIsReady
    }

    property bool showSetup: getOwnChannelId() === ""

    palette.highlight: theme.accent
    palette.highlightedText: theme.text

    // ── Basecamp IPC helpers ────────────────────────────────────────────────

    function callZone(method, args) {
        if (!basecampMode) return ""
        return logos.callModule("liblogos_zone_sequencer_module", method, args || [])
    }

    function callStorage(method, args) {
        if (!basecampMode) return ""
        return logos.callModule("storage_module", method, args || [])
    }

    function initStorage(dir) {
        if (!basecampMode) return
        var storageDir = dir + "/storage"
        var cfg = JSON.stringify({"data-dir": storageDir})
        var r1 = callStorage("init", [cfg])
        console.log("Storage init:", r1)
        var r2 = callStorage("start", [])
        console.log("Storage start:", r2)
        if (r2 && r2.indexOf("Error") < 0) {
            storageIsReady = true
        }
    }

    // ── Media cache ─────────────────────────────────────────────────────────
    property var mediaPaths: ({})
    property var fetchingMedia: ({})

    function mediaCacheDir() { return dataDir + "/media_cache" }

    function resolveMedia(cid) {
        if (mediaPaths[cid]) return mediaPaths[cid]
        return ""
    }

    function fetchMediaBc(cid) {
        if (!basecampMode || !storageIsReady || !cid) return
        if (fetchingMedia[cid]) return
        if (mediaPaths[cid]) return

        var fm = Object.assign({}, fetchingMedia)
        fm[cid] = true
        fetchingMedia = fm

        var cachePath = mediaCacheDir() + "/" + cid
        callStorage("downloadFile", [cid, cachePath, false])

        pollForFile(cid, cachePath, 0)
    }

    function pollForFile(cid, path, attempt) {
        if (attempt >= 30) {
            var fm2 = Object.assign({}, fetchingMedia)
            delete fm2[cid]
            fetchingMedia = fm2
            return
        }
        pollFileTimer.cid = cid
        pollFileTimer.path = path
        pollFileTimer.attempt = attempt
        pollFileTimer.start()
    }

    Timer {
        id: pollFileTimer
        interval: 1000
        repeat: false
        property string cid: ""
        property string path: ""
        property int attempt: 0
        onTriggered: {
            var existsResult = callStorage("exists", [cid])
            var found = false
            try {
                var obj = JSON.parse(existsResult)
                found = obj.success === true || obj.value === true
            } catch(e) {
                found = existsResult === "true"
            }
            if (found) {
                var mp = Object.assign({}, mediaPaths)
                mp[cid] = path
                mediaPaths = mp
                var fm = Object.assign({}, fetchingMedia)
                delete fm[cid]
                fetchingMedia = fm
                updateMessages()
            } else {
                pollForFile(cid, path, attempt + 1)
            }
        }
    }

    function uploadAndPublish(filePath, text) {
        if (!basecampMode || !storageIsReady) {
            statusText = "Storage not ready"
            return
        }

        var fileName = filePath.split("/").pop()
        var ext = fileName.split(".").pop().toLowerCase()
        var mimeType = "application/octet-stream"
        if (ext === "png") mimeType = "image/png"
        else if (ext === "jpg" || ext === "jpeg") mimeType = "image/jpeg"
        else if (ext === "gif") mimeType = "image/gif"
        else if (ext === "webp") mimeType = "image/webp"

        isUploading = true
        statusText = "Uploading " + fileName + "\u2026"

        var result = callStorage("uploadUrl", [filePath, 65536])
        console.log("uploadUrl:", result)

        try {
            var obj = JSON.parse(result)
            if (!obj.success) {
                isUploading = false
                statusText = "Upload failed"
                return
            }
        } catch(e) {
            isUploading = false
            statusText = "Upload failed: " + result
            return
        }

        pollManifestsTimer.fileName = fileName
        pollManifestsTimer.text = text
        pollManifestsTimer.mimeType = mimeType
        pollManifestsTimer.attempt = 0
        pollManifestsTimer.start()
    }

    Timer {
        id: pollManifestsTimer
        interval: 2000
        repeat: true
        property string fileName: ""
        property string text: ""
        property string mimeType: ""
        property int attempt: 0
        onTriggered: {
            attempt++
            var result = callStorage("manifests", [])
            var foundCid = ""
            try {
                var obj = JSON.parse(result)
                if (obj.success) {
                    var arr = obj.value || []
                    for (var i = 0; i < arr.length; i++) {
                        if (arr[i].filename === fileName) {
                            foundCid = arr[i].cid
                            break
                        }
                    }
                }
            } catch(e) {}

            if (foundCid) {
                stop()
                isUploading = false
                statusText = "Uploaded, CID: " + foundCid.substr(0, 16) + "\u2026"

                var payload = JSON.stringify({
                    v: 1,
                    text: text,
                    media: [{ cid: foundCid, type: mimeType, name: fileName, size: 0 }]
                })
                pendingAttachment = ""
                doPublishRaw(payload)
            } else if (attempt >= 30) {
                stop()
                isUploading = false
                statusText = "Upload timed out"
            }
        }
    }

    function doPublishRaw(msg) {
        var pendingId = "pending-" + Date.now()
        var parsed = parseMessagePayload(msg)
        var existing = (allMessages[ownChannelId] || []).slice()
        existing.push({
            id: pendingId, data: msg, displayText: parsed.text, media: parsed.media,
            channel: ownChannelId, isOwn: true,
            timestamp: new Date().toLocaleTimeString(Qt.locale(), "HH:mm:ss"),
            pending: true, failed: false
        })
        var am = Object.assign({}, allMessages)
        am[ownChannelId] = existing
        allMessages = am
        updateMessages()

        statusText = "Publishing\u2026"
        var result = callZone("publish", [msg])
        var ok = result && result.length > 0 && result.indexOf("Error") !== 0

        var msgs = (allMessages[ownChannelId] || []).slice()
        for (var i = 0; i < msgs.length; i++) {
            if (msgs[i].id === pendingId) {
                msgs[i] = Object.assign({}, msgs[i], { pending: false, failed: !ok })
                if (ok) msgs[i].id = result
                break
            }
        }
        am = Object.assign({}, allMessages)
        am[ownChannelId] = msgs
        allMessages = am
        updateMessages()
        statusText = ok ? "Published: " + result.substr(0, 12) + "\u2026" : "Publish failed: " + result
    }

    function encodeChannelName(name) {
        var prefix = "logos:yolo:"
        var raw = prefix + name
        if (raw.length > 32) return ""
        while (raw.length < 32) raw += "\0"
        var hex = ""
        for (var i = 0; i < raw.length; i++) {
            var c = raw.charCodeAt(i).toString(16)
            hex += c.length < 2 ? "0" + c : c
        }
        return hex
    }

    function decodeChannelName(hexId) {
        if (hexId.length !== 64) return ""
        var bytes = ""
        for (var i = 0; i < hexId.length; i += 2) {
            bytes += String.fromCharCode(parseInt(hexId.substr(i, 2), 16))
        }
        var prefix = "logos:yolo:"
        if (bytes.substr(0, prefix.length) !== prefix) return ""
        var name = bytes.substr(prefix.length).replace(/\0+$/, "")
        return name
    }

    function channelDisplayName(channelId) {
        var name = decodeChannelName(channelId)
        if (name.length > 0) return name
        if (channelId.length > 12) return channelId.substr(0, 12) + "\u2026"
        return channelId
    }

    function parseMessagePayload(data) {
        if (!data || data.charAt(0) !== '{') return { text: data || "", media: [] }
        try {
            var obj = JSON.parse(data)
            if (!obj.v) return { text: data, media: [] }
            return { text: obj.text || "", media: obj.media || [] }
        } catch(e) {
            return { text: data, media: [] }
        }
    }

    function currentChannelId() {
        var list = getChannelList()
        var idx = getCurrentChannelIndex()
        if (idx < 0 || idx >= list.length) return ""
        return basecampMode ? list[idx].id : (list[idx].id || "")
    }

    // ── Basecamp mode: IPC actions ──────────────────────────────────────────

    function doConnect() {
        if (!basecampMode) {
            if (api) {
                api.configureDataDir(dataDirInput.text)
                api.configureNodeUrl(nodeInput.text)
                api.connectToNode()
            }
            return
        }

        var dir = dataDirInput.text.trim()
        nodeUrl = nodeInput.text.trim()
        statusText = "Connecting..."

        callZone("set_node_url", [nodeUrl])

        var result = callZone("load_from_directory", [dir])
        console.log("load_from_directory:", result)

        if (result && result.indexOf("Error") !== 0 && result.length > 0) {
            ownChannelId = result
            if (!hasChannel(ownChannelId)) {
                channelList = [{ id: ownChannelId, name: channelDisplayName(ownChannelId), isOwn: true }].concat(channelList)
            }
            isConnected = true
            statusText = "Connected to " + nodeUrl
            callZone("save_ui_config", [JSON.stringify({ dataDir: dir, nodeUrl: nodeUrl })])
            initStorage(dir)
            loadSubscriptions()
            startPolling()
        } else {
            statusText = result || "Failed to connect"
        }
    }

    function saveSubscriptions() {
        if (!basecampMode) return
        var subs = []
        for (var i = 0; i < channelList.length; i++) {
            if (channelList[i].id !== ownChannelId)
                subs.push(channelList[i].id)
        }
        callZone("save_subscriptions", [JSON.stringify(subs)])
    }

    function loadSubscriptions() {
        if (!basecampMode) return
        var json = callZone("load_subscriptions", [])
        try {
            var subs = JSON.parse(json)
            if (!Array.isArray(subs)) return
            var newList = channelList.slice()
            for (var i = 0; i < subs.length; i++) {
                var chId = subs[i]
                if (chId && !hasChannel(chId)) {
                    newList.push({ id: chId, name: channelDisplayName(chId), isOwn: false })
                    fetchMessages(chId)
                }
            }
            channelList = newList
        } catch(e) {}
    }

    function hasChannel(id) {
        for (var i = 0; i < channelList.length; i++)
            if (channelList[i].id === id) return true
        return false
    }

    function doSubscribe() {
        var ch = subInput.text.trim()
        if (ch.length === 0) return
        subInput.text = ""

        var channelId = ch
        if (!/^[0-9a-fA-F]{64}$/.test(channelId)) {
            channelId = encodeChannelName(channelId)
            if (channelId.length === 0) {
                statusText = "Name too long"
                return
            }
        }

        if (!basecampMode) {
            if (api) api.subscribe(ch)
            return
        }

        if (hasChannel(channelId)) {
            statusText = "Already subscribed"
            return
        }

        var newList = channelList.slice()
        newList.push({ id: channelId, name: channelDisplayName(channelId), isOwn: false })
        channelList = newList
        statusText = "Subscribed to " + channelDisplayName(channelId)
        fetchMessages(channelId)
        saveSubscriptions()
    }

    function doUnsubscribe() {
        if (!basecampMode) {
            if (api) {
                var ch = api.currentChannelId()
                if (ch) api.unsubscribe(ch)
            }
            return
        }
        var chId = currentChannelId()
        if (!chId || chId === ownChannelId) return
        var newList = channelList.filter(function(c) { return c.id !== chId })
        channelList = newList
        var am = Object.assign({}, allMessages)
        delete am[chId]
        allMessages = am
        if (currentChannelIndex >= channelList.length)
            currentChannelIndex = Math.max(0, channelList.length - 1)
        updateMessages()
        saveSubscriptions()
    }

    function doSelectChannel(index) {
        if (!basecampMode) {
            if (api) api.selectChannel(index)
            return
        }
        if (index < 0 || index >= channelList.length) return
        currentChannelIndex = index
        var chId = channelList[index].id
        if (unreadCounts[chId] > 0) {
            var uc = Object.assign({}, unreadCounts)
            uc[chId] = 0
            unreadCounts = uc
        }
        updateMessages()
    }

    // ── Polling ─────────────────────────────────────────────────────────────

    property var allMessages: ({})

    function startPolling() {
        if (pollTimerId >= 0) return
        pollTimerId = setInterval(function() {
            for (var i = 0; i < channelList.length; i++)
                fetchMessages(channelList[i].id)
        }, 3000)
    }

    function fetchMessages(channelId) {
        if (!basecampMode) return
        var result = callZone("query_channel", [channelId, 50])
        if (!result || result.length === 0) return

        try {
            var arr = JSON.parse(result)
            if (!Array.isArray(arr)) return
        } catch(e) { return }

        var existing = allMessages[channelId] || []
        var seenIds = {}
        for (var i = 0; i < existing.length; i++)
            seenIds[existing[i].id] = true

        var added = false
        for (var j = 0; j < arr.length; j++) {
            var item = arr[j]
            if (seenIds[item.id]) continue
            var parsed = parseMessagePayload(item.data)
            existing.push({
                id: item.id,
                data: item.data,
                displayText: parsed.text,
                media: parsed.media,
                channel: channelId,
                isOwn: channelId === ownChannelId,
                timestamp: new Date().toLocaleTimeString(Qt.locale(), "HH:mm:ss"),
                pending: false,
                failed: false
            })
            seenIds[item.id] = true
            added = true

            if (channelId !== currentChannelId()) {
                var uc = Object.assign({}, unreadCounts)
                uc[channelId] = (uc[channelId] || 0) + 1
                unreadCounts = uc
            }
        }

        if (added) {
            var am = Object.assign({}, allMessages)
            am[channelId] = existing
            allMessages = am
            if (!isConnected) isConnected = true
            updateMessages()
        }
    }

    function updateMessages() {
        var chId = currentChannelId()
        if (!chId) { messagesList = []; return }
        messagesList = allMessages[chId] || []
    }

    // ── Backfill ────────────────────────────────────────────────────────────

    property string backfillChannelId: ""
    property string backfillCursor: ""
    property bool backfillRunning: false

    function doStartBackfill(channelId) {
        if (!basecampMode) {
            if (api) api.startBackfill(channelId)
            return
        }
        statusText = "Backfill requires async IPC (newer Basecamp)"
    }

    function doStopBackfill(channelId) {
        if (!basecampMode) {
            if (api) api.stopBackfill(channelId)
            return
        }
        backfillTimer.stop()
        backfillRunning = false
        var bp = Object.assign({}, backfillProgressMap)
        delete bp[channelId]
        backfillProgressMap = bp
    }

    function backfillNextPage() {
        if (!backfillRunning) return
        var channelId = backfillChannelId

        logos.callModuleAsync(
            "liblogos_zone_sequencer_module", "query_channel_paged",
            [channelId, backfillCursor, 100],
            function(result) {
                if (!backfillRunning || backfillChannelId !== channelId) return
                if (!result || result.length === 0) { doStopBackfill(channelId); return }

                try { var root = JSON.parse(result) } catch(e) { doStopBackfill(channelId); return }
                if (!root || typeof root !== "object") { doStopBackfill(channelId); return }

                var cursorSlot = root.cursor_slot || 0
                var libSlot = root.lib_slot || 1
                var done = root.done || false
                var bp = Object.assign({}, backfillProgressMap)
                bp[channelId] = libSlot > 0 ? Math.min(1.0, cursorSlot / libSlot) : 0
                backfillProgressMap = bp

                var msgs = root.messages || []
                if (msgs.length > 0) {
                    var existing = (allMessages[channelId] || []).slice()
                    var seenIds = {}
                    for (var i = 0; i < existing.length; i++) seenIds[existing[i].id] = true

                    var prepend = []
                    for (var j = 0; j < msgs.length; j++) {
                        if (seenIds[msgs[j].id]) continue
                        var parsed = parseMessagePayload(msgs[j].data)
                        prepend.push({
                            id: msgs[j].id, data: msgs[j].data,
                            displayText: parsed.text, media: parsed.media,
                            channel: channelId, isOwn: channelId === ownChannelId,
                            timestamp: "", pending: false, failed: false
                        })
                    }
                    if (prepend.length > 0) {
                        var am = Object.assign({}, allMessages)
                        am[channelId] = prepend.concat(existing)
                        allMessages = am
                        updateMessages()
                    }
                }

                if (done) {
                    doStopBackfill(channelId)
                    statusText = "Backfill complete for " + channelDisplayName(channelId)
                    return
                }

                backfillCursor = JSON.stringify(root.cursor || {})
                backfillNextPage()
            },
            60000
        )
    }

    function doPublish() {
        var msg = composeInput.text.trim()
        var hasAttach = getPendingAttachment().length > 0
        if (msg.length === 0 && !hasAttach) return
        composeInput.text = ""

        if (!basecampMode) {
            if (api) {
                if (hasAttach) api.publishWithAttachment(msg)
                else api.publish(msg)
            }
            return
        }

        if (hasAttach) {
            uploadAndPublish(pendingAttachment, msg)
            return
        }

        if (msg.length === 0) return

        // Optimistic add
        var pendingId = "pending-" + Date.now()
        var parsed = parseMessagePayload(msg)
        var existing = (allMessages[ownChannelId] || []).slice()
        existing.push({
            id: pendingId, data: msg, displayText: parsed.text, media: parsed.media,
            channel: ownChannelId, isOwn: true,
            timestamp: new Date().toLocaleTimeString(Qt.locale(), "HH:mm:ss"),
            pending: true, failed: false
        })
        var am = Object.assign({}, allMessages)
        am[ownChannelId] = existing
        allMessages = am
        updateMessages()

        statusText = "Publishing\u2026"
        var result = callZone("publish", [msg])
        var ok = result && result.length > 0 && result.indexOf("Error") !== 0

        // Update pending message
        var msgs = (allMessages[ownChannelId] || []).slice()
        for (var i = 0; i < msgs.length; i++) {
            if (msgs[i].id === pendingId) {
                msgs[i] = Object.assign({}, msgs[i], { pending: false, failed: !ok })
                if (ok) msgs[i].id = result
                break
            }
        }
        am = Object.assign({}, allMessages)
        am[ownChannelId] = msgs
        allMessages = am
        updateMessages()
        statusText = ok ? "Published: " + result.substr(0, 12) + "\u2026" : "Publish failed: " + result
    }

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
                    color: getConnected() ? theme.accent : theme.textPlace
                    ToolTip.visible: chainMouse.containsMouse
                    ToolTip.text: getConnected() ? "Chain: connected" : "Chain: disconnected"
                    MouseArea { id: chainMouse; anchors.fill: parent; hoverEnabled: true }
                }
                Text {
                    text: "\u25A4"
                    font.pixelSize: 14
                    color: getStorageReady() ? theme.accent : theme.textPlace
                    ToolTip.visible: storageMouse.containsMouse
                    ToolTip.text: getStorageReady() ? "Storage: ready" : "Storage: not ready"
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
                    text: getOwnChannelId().length > 0 ? channelDisplayName(getOwnChannelId()) : ""
                    color: theme.textMuted
                    font.pixelSize: theme.fontSecondary
                }
                Rectangle {
                    width: 1; height: 20
                    color: theme.border
                    visible: getNodeUrl().length > 0
                }
                Text {
                    text: getNodeUrl()
                    color: theme.textMuted
                    font.pixelSize: theme.fontSecondary
                    visible: getNodeUrl().length > 0
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
                        id: channelListView
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        model: getChannelList()

                        delegate: Column {
                            id: chDelegate
                            width: channelListView.width

                            required property var modelData
                            required property int index

                            property string chId: modelData.id || ""
                            property string chName: modelData.name || ""
                            property bool chIsOwn: modelData.isOwn === true
                            property real backfillProg: getBackfillProgress()[chId] || -1
                            property bool backfilling: backfillProg >= 0
                            property bool selected: index === getCurrentChannelIndex()
                            property bool hovered: chMouse.containsMouse

                            Rectangle {
                                width: chDelegate.width
                                height: 36
                                color: chDelegate.selected ? theme.surface
                                     : chDelegate.hovered ? Qt.rgba(1,1,1,0.04)
                                     : "transparent"
                                radius: 4

                                MouseArea {
                                    id: chMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: doSelectChannel(chDelegate.index)
                                }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 12
                                    anchors.rightMargin: 8
                                    spacing: 6

                                    Text {
                                        Layout.fillWidth: true
                                        text: chDelegate.chName
                                        color: chDelegate.selected ? theme.text
                                             : chDelegate.chIsOwn ? theme.accent
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
                                            onClicked: {
                                                if (chDelegate.backfilling)
                                                    doStopBackfill(chDelegate.chId)
                                                else
                                                    doStartBackfill(chDelegate.chId)
                                            }
                                        }
                                    }

                                    Rectangle {
                                        visible: (getUnreadCounts()[chDelegate.chId] || 0) > 0
                                        width: 22; height: 18; radius: 9
                                        color: theme.notify
                                        Text {
                                            anchors.centerIn: parent
                                            text: getUnreadCounts()[chDelegate.chId] || 0
                                            color: theme.text
                                            font.pixelSize: 10
                                            font.weight: Font.Bold
                                        }
                                    }
                                }
                            }

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
                                placeholderText: "Channel name or ID\u2026"
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
                                    text: "\u2715"
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
                                    enabled: getChannelList().length > 0
                                    onClicked: {
                                        doUnsubscribe()
                                    }
                                }
                            }
                        }
                    }
                }

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
                    model: getMessages()
                    verticalLayoutDirection: ListView.BottomToTop

                    delegate: Rectangle {
                        width: messageList.width
                        height: msgCol.implicitHeight + 16
                        color: msgHover.containsMouse ? Qt.rgba(1,1,1,0.02) : "transparent"

                        required property var modelData

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
                                        var sender = isOwn ? "you" : channelDisplayName(modelData.channel || "")
                                        if (isPending) return sender + "  \u00B7  sending\u2026"
                                        if (isFailed)  return sender + "  \u00B7  failed"
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
                                                var p = ""
                                                if (basecampMode) {
                                                    p = resolveMedia(modelData.cid)
                                                } else if (api) {
                                                    p = api.resolveMediaPath(modelData.cid)
                                                }
                                                return p && p.length > 0 ? "file://" + p : ""
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
                                                text: "Loading image\u2026"
                                                color: theme.textMuted
                                                font.pixelSize: 11
                                            }
                                            Component.onCompleted: {
                                                if (basecampMode) fetchMediaBc(modelData.cid)
                                                else if (api) api.fetchMedia(modelData.cid)
                                            }
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
                    height: getPendingAttachment().length > 0 ? 52 : 0
                    visible: getPendingAttachment().length > 0
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
                            text: getPendingAttachment()
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
                            onClicked: {
                                if (!basecampMode && api) api.clearAttachment()
                            }
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
                            visible: true
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
                            onClicked: {
                                if (basecampMode) {
                                    attachPathDialog.open()
                                } else if (api) {
                                    api.openFilePicker()
                                }
                            }
                        }

                        TextField {
                            id: composeInput
                            Layout.fillWidth: true
                            placeholderText: "Type a message\u2026"
                            placeholderTextColor: theme.textPlace
                            font.pixelSize: theme.fontPrimary
                            color: theme.text
                            background: Rectangle {
                                color: theme.bgInset
                                border.color: composeInput.activeFocus ? theme.accent : theme.borderSub
                                border.width: 1
                                radius: 6
                            }
                            enabled: getConnected()
                            Keys.onReturnPressed: doPublish()
                        }

                        Button {
                            text: getUploading() ? "Uploading\u2026" : "Publish"
                            font.pixelSize: theme.fontPrimary
                            enabled: getConnected() && !getUploading()
                                     && (composeInput.text.length > 0 || getPendingAttachment().length > 0)
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
                            text: "\u27F3"
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
                            onClicked: {
                                if (!basecampMode && api) api.resetCheckpoint()
                            }
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
                        text: getStatus()
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
            width: 420; height: 280
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
                    placeholderText: "Data directory\u2026"
                    placeholderTextColor: theme.textPlace
                    font.pixelSize: theme.fontPrimary
                    color: theme.text
                    text: getDataDir()
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
                    text: getNodeUrl()
                    background: Rectangle {
                        color: theme.bgInset
                        border.color: nodeInput.activeFocus ? theme.accent : theme.border
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
                    onClicked: doConnect()
                }
            }
        }
    }

    // ── Attach file dialog (Basecamp mode) ─────────────────────────────────
    Dialog {
        id: attachPathDialog
        title: "Attach Image"
        anchors.centerIn: parent
        width: 420
        modal: true
        standardButtons: Dialog.Ok | Dialog.Cancel

        background: Rectangle {
            color: theme.bgSecondary
            border.color: theme.border
            border.width: 1
            radius: 12
        }

        header: Item {
            height: 40
            Text {
                anchors.left: parent.left
                anchors.leftMargin: 24
                anchors.verticalCenter: parent.verticalCenter
                text: "Attach Image"
                color: theme.text
                font.pixelSize: 16
                font.weight: Font.Bold
            }
        }

        contentItem: ColumnLayout {
            spacing: 10
            Text {
                text: "Enter the full path to the image file"
                color: theme.textSec
                font.pixelSize: theme.fontSecondary
            }
            TextField {
                id: attachPathInput
                Layout.fillWidth: true
                placeholderText: "/path/to/image.png"
                placeholderTextColor: theme.textPlace
                font.pixelSize: theme.fontPrimary
                color: theme.text
                background: Rectangle {
                    color: theme.bgInset
                    border.color: attachPathInput.activeFocus ? theme.accent : theme.border
                    border.width: 1
                    radius: 6
                }
            }
        }

        onAccepted: {
            var path = attachPathInput.text.trim()
            if (path.length > 0) {
                if (path.startsWith("~")) path = path  // tilde handled by storage module
                pendingAttachment = path
            }
            attachPathInput.text = ""
        }
        onRejected: attachPathInput.text = ""
    }

    // ── Standalone mode connections ──────────────────────────────────────────
    Connections {
        target: basecampMode ? null : api
        function onMessagesChanged() {
            messageList.positionViewAtEnd()
        }
        function onChannelListChanged() {
            channelListView.model = api ? api.channelList : []
        }
    }

    Component.onDestruction: {
        if (pollTimerId >= 0) clearInterval(pollTimerId)
    }
}
