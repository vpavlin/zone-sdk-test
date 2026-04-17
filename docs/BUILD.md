# Yolo Board — Build & Test Instructions

## Overview

Yolo Board is a censorship-resistant bulletin board running on the Logos blockchain. Publishes text messages as on-chain inscriptions; uploads image attachments to Logos Storage (Codex) and embeds the CID. Ships as a **`ui_qml` plugin** — pure QML that talks to core modules (`liblogos_zone_sequencer_module`, `storage_module`) via `logos.callModule()` IPC.

The architecture follows the Logos Core pattern: QML is a thin client; all blockchain and storage I/O is delegated to core modules running in separate processes.

## Prerequisites

- Nix with flakes enabled
- Logos Basecamp pre-built (see note below)
- Access to a Logos zone node (e.g. `http://192.168.0.203:8080`)

## Repos

| Repo | Branch | Why forked |
|------|--------|-----------|
| [vpavlin/zone-sdk-test](https://github.com/vpavlin/zone-sdk-test) | `basecamp` | Yolo Board UI plugin (pure QML) |
| [jimmy-claw/logos-zone-sequencer-module](https://github.com/jimmy-claw/logos-zone-sequencer-module) | `master` | `--whole-archive` link so ModuleProxy symbols are included; adds `load_from_directory`, `save/load_subscriptions`, `save/load_ui_config` helpers |
| [vpavlin/logos-storage-module](https://github.com/vpavlin/logos-storage-module) | `update_api` | Adds `downloadFile` wrapper (single-line declaration so codegen picks it up) |
| [vpavlin/logos-cpp-sdk](https://github.com/vpavlin/logos-cpp-sdk) | `logos-result-fix-on-latest` | `LogosResult` → JSON serialization in `ModuleProxy::callRemoteMethod` |
| [vpavlin/logos-liblogos](https://github.com/vpavlin/logos-liblogos) | `ipc-fixes` | `informModuleToken` retry loop (1s single-shot is too fragile) |
| [vpavlin/logos-capability-module](https://github.com/vpavlin/logos-capability-module) | `fix-ipc-shadowing` | Remove shadowing of `PluginInterface::logosAPI` — the bug broke all IPC auth |

## Clone

```bash
mkdir -p ~/yolo-board-build && cd ~/yolo-board-build

git clone -b basecamp https://github.com/vpavlin/zone-sdk-test.git
git clone https://github.com/jimmy-claw/logos-zone-sequencer-module.git
git clone -b update_api https://github.com/vpavlin/logos-storage-module.git
git clone -b logos-result-fix-on-latest https://github.com/vpavlin/logos-cpp-sdk.git
git clone -b ipc-fixes https://github.com/vpavlin/logos-liblogos.git
git clone -b fix-ipc-shadowing https://github.com/vpavlin/logos-capability-module.git
```

## Build

```bash
# Plugin (produces yolo_board.so + Main.qml + yolo.png + libzone_sequencer_rs.so)
(cd zone-sdk-test && nix build .#plugin -o result-plugin)

# Standalone app (optional — runs Yolo without Basecamp for smoke tests)
(cd zone-sdk-test && nix build .#app -o result-app)

# LGX bundle (for lgpm install)
(cd zone-sdk-test && nix build .#lgx -o result-lgx)

# Core modules
(cd logos-zone-sequencer-module && nix build .#plugin)
(cd logos-storage-module && nix build)
(cd logos-capability-module && nix build)
```

## Install

```bash
MODULES_DIR=~/.local/share/Logos/LogosBasecampDev/modules
PLUGINS_DIR=~/.local/share/Logos/LogosBasecampDev/plugins

# Capability module (IPC shadowing fix)
mkdir -p "$MODULES_DIR/capability_module"
chmod -R u+w "$MODULES_DIR/capability_module" 2>/dev/null
cp logos-capability-module/result/lib/*.so "$MODULES_DIR/capability_module/"
cat > "$MODULES_DIR/capability_module/manifest.json" << 'EOF'
{
  "name": "capability_module", "version": "1.0.0", "type": "core",
  "main": {"linux-amd64-dev": "capability_module_plugin.so", "linux-x86_64-dev": "capability_module_plugin.so"},
  "manifestVersion": "0.1.0", "dependencies": []
}
EOF

# Zone sequencer
mkdir -p "$MODULES_DIR/liblogos_zone_sequencer_module"
chmod -R u+w "$MODULES_DIR/liblogos_zone_sequencer_module" 2>/dev/null
cp logos-zone-sequencer-module/result/lib/*.so "$MODULES_DIR/liblogos_zone_sequencer_module/"
cat > "$MODULES_DIR/liblogos_zone_sequencer_module/manifest.json" << 'EOF'
{
  "name": "liblogos_zone_sequencer_module", "version": "0.2.0", "type": "core",
  "main": {"linux-amd64-dev": "liblogos_zone_sequencer_module.so", "linux-x86_64-dev": "liblogos_zone_sequencer_module.so"},
  "manifestVersion": "0.1.0", "dependencies": []
}
EOF

# Storage module
mkdir -p "$MODULES_DIR/storage_module"
chmod -R u+w "$MODULES_DIR/storage_module" 2>/dev/null
cp logos-storage-module/result/lib/*.so "$MODULES_DIR/storage_module/"
cat > "$MODULES_DIR/storage_module/manifest.json" << 'EOF'
{
  "name": "storage_module", "version": "1.0.0", "type": "core",
  "main": {"linux-amd64-dev": "storage_module_plugin.so", "linux-x86_64-dev": "storage_module_plugin.so"},
  "manifestVersion": "0.1.0", "dependencies": []
}
EOF

# Yolo Board plugin (ui_qml — Main.qml, icon, and the .so in case Basecamp prefers a C++ plugin)
mkdir -p "$PLUGINS_DIR/yolo_board"
chmod -R u+w "$PLUGINS_DIR/yolo_board" 2>/dev/null
cp zone-sdk-test/result-plugin/lib/*.so "$PLUGINS_DIR/yolo_board/"
cp zone-sdk-test/result-plugin/qml/Main.qml "$PLUGINS_DIR/yolo_board/"
cp zone-sdk-test/result-plugin/lib/yolo.png "$PLUGINS_DIR/yolo_board/"
cat > "$PLUGINS_DIR/yolo_board/metadata.json" << 'EOF'
{
  "name": "yolo_board", "version": "0.1.0", "type": "ui_qml",
  "category": "social", "main": "Main.qml", "icon": "yolo.png",
  "description": "Censorship-resistant bulletin board on the Logos blockchain",
  "dependencies": ["liblogos_zone_sequencer_module", "storage_module"]
}
EOF
```

## Launch

```bash
/path/to/logos-basecamp/result/bin/logos-basecamp
```

For QML iteration without rebuilding:

```bash
QML_PATH=/path/to/zone-sdk-test/src/qml /path/to/logos-basecamp
```

For debug logs:

```bash
QT_FORCE_STDERR_LOGGING=1 /path/to/logos-basecamp
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
├── yolo_board plugin (Main.qml) — pure QML, no C++ backend
│
├── logos_host (forked) per module:
│   ├── capability_module       — IPC token auth
│   ├── liblogos_zone_sequencer_module — zone inscriptions (via libzone_sequencer_rs.so)
│   ├── storage_module          — Codex (via libstorage.so)
│   └── package_manager         — plugin discovery
```

### Call flow (publish text)

```
QML (yolo_board) 
  → logos.callModule("liblogos_zone_sequencer_module", "publish", [data])
  → LogosQmlBridge → LogosAPIClient 
  → QRemoteObjects socket
  → logos_host[zone_sequencer] 
  → ModuleProxy → LogosZoneSequencerModule::publish() 
  → libzone_sequencer_rs.so (Rust FFI)
  → zone node (blockchain)
```

## What Works

- ✅ Load plugin, setup dialog, auto-save/restore config
- ✅ Publishing text messages (signed, on-chain)
- ✅ Polling subscribed channels every 1.5s (staggered, so UI stays responsive)
- ✅ Subscription persistence (`subscriptions.json` in data dir)
- ✅ Named channels (`logos:yolo:alice` encoding)
- ✅ Storage module starts (orange icon in header)
- ✅ File upload to storage (data IS stored, confirmed by storage logs)
- ✅ Drag-and-drop file attachment in the message area
- ✅ Backfill disabled in Basecamp mode (requires async IPC — see FEEDBACK.md)

## What Doesn't Work (Yet)

- ❌ Retrieving the CID after upload via `storage.manifests()` — the method returns `LogosResult` which Basecamp's current `LogosQmlBridge`/`ModuleProxy` cannot serialize across QRemoteObjects (arrives as empty string). Our SDK fork has the fix (convert to JSON before return), but Basecamp's linked SDK shadows it at runtime due to `RTLD_GLOBAL` plugin loading. See FEEDBACK.md §2.
- ❌ Media download (same root cause: needs storage methods that return non-`LogosResult` types)
- ❌ Backfill of historical messages (needs `logos.callModuleAsync` — available in newer SDK, not in current Basecamp)
- ❌ Native file picker (QtQuick.Dialogs is blocked by Basecamp's sandboxed import paths)

## Key Fixes Applied

| Fix | Where | Why |
|-----|-------|-----|
| Remove private `logosAPI` shadowing | capability_module | The shadowed member was always null → `informModuleToken` failed → all IPC auth broken |
| `--whole-archive` for SDK link | zone-sequencer-module CMakeLists.txt | Without it, `ModuleProxy` symbols were stripped → capability_module's `informModuleToken` calls hung for 20s per IPC round-trip |
| LogosResult → JSON in ModuleProxy | cpp-sdk fork | Dynamic QRemoteObjects replicas can't serialize custom types; JSON strings transfer fine |
| `load_from_directory` in zone module | zone-sequencer-module | QML sandbox can't read binary files; module reads `sequencer.key` / `channel.id` itself |
| `save/load_ui_config` + `save/load_subscriptions` | zone-sequencer-module | QML sandbox can't write files; module persists config to `~/.config/logos/yolo_board.json` and subscriptions to data dir |
| Timer-based polling (one channel per tick) | QML | `callModule` is sync; polling all channels at once freezes UI for seconds |
| Defer `callZone("load_ui_config")` via `Timer` | QML | Calling sync IPC in `Component.onCompleted` froze the plugin during load |
