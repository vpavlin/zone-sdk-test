# Yolo Board — Build & Test Instructions

## Overview

Yolo Board is a censorship-resistant bulletin board running on the Logos blockchain. Publishes text messages as on-chain inscriptions; uploads image attachments to Logos Storage (Codex) and embeds the CID. Ships as a **`ui_qml` plugin** — QML thin client that talks to a single backend module (`yolo_board_module`) via `logos.callModule()` IPC. That module in turn fans out to `liblogos_zone_sequencer_module` and `storage_module`.

The architecture is the canonical "domain module" Logos Core pattern: QML polls JSON-state snapshots and triggers actions, while all blockchain, storage, and persistence logic lives in the backend module.

## Prerequisites

- Nix with flakes enabled
- Logos Basecamp pre-built (see note below)
- Access to a Logos zone node (e.g. `http://192.168.0.203:8080`)

## Repos

| Repo | Branch | Why forked |
|------|--------|-----------|
| [vpavlin/zone-sdk-test](https://github.com/vpavlin/zone-sdk-test) | `basecamp` | Yolo Board UI plugin (QML thin client) |
| [vpavlin/logos-yolo-board-module](https://github.com/vpavlin/logos-yolo-board-module) | `master` | Domain module that owns polling, message cache, subscriptions, upload orchestration. `--whole-archive` so `ModuleProxy` symbols stay in. |
| [jimmy-claw/logos-zone-sequencer-module](https://github.com/jimmy-claw/logos-zone-sequencer-module) | `master` | `--whole-archive` link; adds `load_from_directory` |
| [vpavlin/logos-storage-module](https://github.com/vpavlin/logos-storage-module) | `update_api` | Adds `downloadFile`; `*Json` wrapper methods around every `LogosResult`-returning call (workaround for SDK bug); `start()` detached to `std::thread` so IPC returns immediately while libstorage initialises |
| [vpavlin/logos-cpp-sdk](https://github.com/vpavlin/logos-cpp-sdk) | `logos-result-fix-on-latest` | `LogosResult` → JSON serialization in `ModuleProxy::callRemoteMethod` (still shadowed at runtime; see FEEDBACK §15) |
| [vpavlin/logos-liblogos](https://github.com/vpavlin/logos-liblogos) | `ipc-fixes` | `informModuleToken` retry loop (1s single-shot is too fragile) |
| [vpavlin/logos-capability-module](https://github.com/vpavlin/logos-capability-module) | `fix-ipc-shadowing` | Remove shadowing of `PluginInterface::logosAPI` — the bug broke all IPC auth |

## Clone

```bash
mkdir -p ~/yolo-board-build && cd ~/yolo-board-build

git clone -b basecamp https://github.com/vpavlin/zone-sdk-test.git
git clone https://github.com/vpavlin/logos-yolo-board-module.git
git clone https://github.com/jimmy-claw/logos-zone-sequencer-module.git
git clone -b update_api https://github.com/vpavlin/logos-storage-module.git
git clone -b logos-result-fix-on-latest https://github.com/vpavlin/logos-cpp-sdk.git
git clone -b ipc-fixes https://github.com/vpavlin/logos-liblogos.git
git clone -b fix-ipc-shadowing https://github.com/vpavlin/logos-capability-module.git
```

## Build

```bash
# UI plugin (produces yolo-board.lgx)
(cd zone-sdk-test && nix build)

# Domain module (produces yolo-board-module.lgx)
(cd logos-yolo-board-module && nix build)

# Backing core modules
(cd logos-zone-sequencer-module && nix build .#plugin)
(cd logos-storage-module && nix build .#lgx)
(cd logos-capability-module && nix build)

# Standalone app (optional — runs Yolo without Basecamp for smoke tests)
(cd zone-sdk-test && nix build .#app -o result-app)
```

## Install

Use `lgpm` to install each `.lgx`, then patch variant keys for the dev Basecamp build:

```bash
LGPM=/path/to/logos-package-manager/scripts/lgpm
BASECAMP=~/.local/share/Logos/LogosBasecampDev

# Backing modules (capability_module is preinstalled by Basecamp on first launch)
$LGPM --modules-dir $BASECAMP/modules --ui-plugins-dir $BASECAMP/plugins \
      install --file logos-zone-sequencer-module/result/*.lgx
$LGPM --modules-dir $BASECAMP/modules --ui-plugins-dir $BASECAMP/plugins \
      install --file logos-storage-module/result/*.lgx
$LGPM --modules-dir $BASECAMP/modules --ui-plugins-dir $BASECAMP/plugins \
      install --file logos-yolo-board-module/result/yolo-board-module.lgx
$LGPM --modules-dir $BASECAMP/modules --ui-plugins-dir $BASECAMP/plugins \
      install --file zone-sdk-test/result/yolo-board.lgx

# Patch variant keys: lgpm writes "linux-amd64" but dev Basecamp expects "-dev"
sed -i 's/"linux-amd64"/"linux-amd64-dev"/g; s/"linux-x86_64"/"linux-x86_64-dev"/g' \
       $BASECAMP/modules/*/manifest.json $BASECAMP/plugins/*/manifest.json
```

For repeated iteration, use the `/basecamp-deploy` Claude Code skill — it bakes in the
sed step, kills stale `logos_host` processes before relaunch, and offers verbose-Qt
logging mode.

## Launch

```bash
/path/to/logos-basecamp/result/bin/logos-basecamp
```

For QML iteration without rebuilding:

```bash
QML_PATH=/path/to/zone-sdk-test/src/qml /path/to/logos-basecamp
```

For debug logs (without these, all module qInfo output is hidden — Basecamp's
launching shell only sees its own stdout, not the per-`logos_host` stderr):

```bash
QT_LOGGING_RULES="*=true;qt.scenegraph*=false;qt.text*=false;qt.qpa*=false;qt.quick.hover*=false;qt.quick.viewport*=false;qt.qml.import*=false;qt.qml.diskcache*=false;qt.quick.dirty*=false;qt.quick.layouts*=false" \
QT_FORCE_STDERR_LOGGING=1 \
QT_MESSAGE_PATTERN="[%{type}|%{category}] %{message}" \
/path/to/logos-basecamp 2>&1 | tee basecamp.log
```

## Zone Data Directory

```bash
mkdir -p ~/zone-data

# Signing key (32 random bytes)
openssl rand 32 > ~/zone-data/sequencer.key

# Channel ID: pad "logos:yolo:yourname" to 32 bytes
python3 -c 'import sys; n="yourname".encode(); sys.stdout.buffer.write((b"logos:yolo:"+n).ljust(32, b"\x00"))' > ~/zone-data/channel.id
```

## Usage

1. Click **Yolo Board** in the Basecamp sidebar
2. Enter the path to your Zone data directory (e.g. `/home/you/zone-data`) — `~/...` expansion is handled by the zone module
3. Enter the zone node URL
4. Click **Connect** — config is saved to `~/.config/logos/yolo_board.json` for auto-fill next time
5. Publish text: type → **Publish** → on-chain inscription
6. Attach image: drag-drop onto message area OR click **+** and type a path → **Publish**
7. Subscribe to other channels by name (`alice`) or 64-hex channel ID

## Architecture

```
Basecamp process
├── LogosQmlBridge              (logos.callModule() from QML)
└── yolo_board plugin (Main.qml — QML thin client)
                │
                │  callModule("yolo_board_module", "<method>", [args])
                ▼
logos_host[yolo_board_module]   — domain logic
   ├─ poll get_state every 2s, get_messages per channel
   ├─ message cache, subscription persistence, media cache
   ├─ upload orchestration (uploadUrlJson + manifestsJson polling)
   └─ resolve_media: copy cached file into <plugin_dir>/media/<cid>
                │
                │  QtRO IPC (main-thread, dispatched via QTimer::singleShot)
                ▼
logos_host[liblogos_zone_sequencer_module]   logos_host[storage_module]
   ├─ libzone_sequencer_rs.so (Rust FFI)         ├─ libstorage.so (Codex)
   └─ publish, query_channel, set_node_url       └─ uploadUrlJson, manifestsJson, etc.
```

Plus `logos_host[capability_module]` for IPC token auth (preinstalled by Basecamp).

### Call flow (publish text)

```
QML
  → logos.callModule("yolo_board_module", "publish", [text])
  → yolo_board_module appends optimistic pending message; QTimer::singleShot(0, ...) →
  → zoneCall("publish", {text}) via QRemoteObjects
  → logos_host[zone_sequencer] → ModuleProxy → LogosZoneSequencerModule::publish()
  → libzone_sequencer_rs.so (Rust FFI) → zone node (blockchain)
  → InscriptionId returned → yolo_board_module marks pending msg confirmed
  → fetchMessages poll picks it up; messagesChanged event → QML refreshes
```

### Call flow (publish image)

```
QML drop file → callModule(..., "publish_with_attachment", [text, path])
  → yolo_board_module: optimistic pending message with cid="uploading"
  → startUploadWhenReady (waits for storageReady)
  → runUpload: storageCall("uploadUrlJson"), poll storageCall("manifestsJson")
       until manifest carries the file's CID
  → cache file at <dataDir>/media_cache/<cid>; mirror copy to
       <plugin_dir>/media/<cid> so QML sandbox can load it
  → publish(JSON{"v":1,"text":..., "media":[{"cid":..., ...}]})
  → QML resolveMedia(cid) returns mirrored path; Image source = "file://<path>"
```

## What Works

- ✅ Load plugin, setup dialog, auto-save/restore config (auto-connect on launch)
- ✅ Publishing text messages (signed, on-chain)
- ✅ Polling subscribed channels every 2s (staggered, UI stays responsive)
- ✅ Subscription persistence (`subscriptions.json` in data dir)
- ✅ Named channels (`logos:yolo:alice` encoding)
- ✅ Storage init + start (with detached `start()` so the ~30s libstorage spin-up
      doesn't block the IPC return)
- ✅ File upload to storage + CID retrieval via `*Json` wrapper methods
- ✅ Inline image rendering (own-channel uploads cached, mirrored into plugin dir)
- ✅ Drag-and-drop file attachment
- ✅ Optimistic pending message with single-retry-chain across the storage warm-up
- ✅ Domain-module middleware pattern (UI → yolo_board_module → zone+storage)

## What Doesn't Work (Yet)

- ⚠️ Cross-channel image download — `fetch_media` runs but only completes when
      storage has peers serving the requested CID; otherwise the image stays in
      "Fetching…" forever
- ⚠️ Backfill of historical messages — implemented via `QtConcurrent::run` and
      `QMetaObject::invokeMethod`, works in standalone but flaky in Basecamp
- ❌ Native file picker — `QtQuick.Dialogs` blocked by Basecamp's QML sandbox;
      drag-and-drop is the only option (see FEEDBACK §17)
- ❌ Async UI feedback for long-running calls — `LogosQmlBridge` is sync-only in
      current Basecamp (FEEDBACK §18). Mitigated by polling get_state from QML.

## Key Fixes Applied

| Fix | Where | Why |
|-----|-------|-----|
| Remove private `logosAPI` shadowing | capability_module | The shadowed member was always null → `informModuleToken` failed → all IPC auth broken |
| `--whole-archive` for SDK link | yolo_board_module + zone-sequencer-module + storage_module CMakeLists.txt | Without it, `ModuleProxy` symbols were stripped → capability_module's `informModuleToken` calls hung 20s per IPC round-trip |
| `*Json` wrapper methods (`uploadUrlJson`, `manifestsJson`, `downloadFileJson`, `existsJson`) | storage_module | `LogosResult` arrives empty across QtRO; JSON `std::string` round-trips fine and the codegen maps it to `QString` |
| Detached `storage_module.start()` to `std::thread` | storage_module | `storage_start` blocks ~30s for libstorage discovery + transport bind; detaching keeps the IPC return immediate |
| All cross-module IPC via `QTimer::singleShot(0, this, ...)` on main thread | yolo_board_module | `QRemoteObjects` is main-thread bound; calls from `QtConcurrent::run` are silently dropped |
| Optimistic pending message + single retry chain | yolo_board_module `publish_with_attachment` | Original retry-on-error spawned multiple parallel uploads when storage finally came up |
| `set_ui_dir(qmlDir)` + mirror media into `<qmlDir>/media/<cid>` | yolo_board_module + Main.qml | The Basecamp QML host blocks file:// outside the plugin dir, blocks data: URLs (network disabled), and resolves symlinks — only a real copy in the plugin dir loads |
| `load_from_directory` in zone module | zone-sequencer-module | QML sandbox can't read binary files; module reads `sequencer.key` / `channel.id` itself |
| Auto-connect on init from saved config | yolo_board_module | UI doesn't have to re-enter dataDir/nodeUrl on every relaunch |
| `--whole-archive` for SDK link in storage_module | storage_module CMakeLists | Same reason as zone-sequencer; storage is also an IPC target |
