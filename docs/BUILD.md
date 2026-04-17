# Yolo Board — Build & Test Instructions

## Overview

Yolo Board is a censorship-resistant bulletin board running on the Logos blockchain. It supports text messages and image attachments uploaded to Logos Storage (Codex). It runs as a UI plugin inside Logos Basecamp.

## Prerequisites

- Nix with flakes enabled
- Logos Basecamp built from [logos-basecamp](https://github.com/logos-co/logos-basecamp)
- Access to a Logos zone node (e.g. `http://192.168.0.203:8080`)

## Repos

| Repo | Branch | Description |
|------|--------|-------------|
| [vpavlin/zone-sdk-test](https://github.com/vpavlin/zone-sdk-test) | `basecamp` | Yolo Board UI plugin |
| [vpavlin/logos-zone-sequencer-module](https://github.com/vpavlin/logos-zone-sequencer-module) | `master` | Zone sequencer core module (Rust FFI wrapper) |
| [vpavlin/logos-storage-module](https://github.com/vpavlin/logos-storage-module) | `update_api` | Storage module (Codex wrapper) |
| [vpavlin/logos-cpp-sdk](https://github.com/vpavlin/logos-cpp-sdk) | `logos-result-serialization-fix` | SDK with LogosResult serialization fix |
| [vpavlin/logos-liblogos](https://github.com/vpavlin/logos-liblogos) | `ipc-fixes` | Core lib with IPC retry + SDK compat fixes |
| [vpavlin/logos-capability-module](https://github.com/vpavlin/logos-capability-module) | `fix-ipc-shadowing` | Capability module with IPC shadowing fix |

## Clone

```bash
mkdir -p ~/yolo-board-build && cd ~/yolo-board-build

git clone -b basecamp git@github.com:vpavlin/zone-sdk-test.git
git clone git@github.com:vpavlin/logos-zone-sequencer-module.git
git clone -b update_api git@github.com:vpavlin/logos-storage-module.git
git clone -b logos-result-serialization-fix git@github.com:vpavlin/logos-cpp-sdk.git
git clone -b ipc-fixes git@github.com:vpavlin/logos-liblogos.git
git clone -b fix-ipc-shadowing git@github.com:vpavlin/logos-capability-module.git
```

## Build Steps

### 1. Build zone-sequencer module

```bash
cd logos-zone-sequencer-module
nix build .#plugin
cd ..
```

### 2. Build storage module

```bash
cd logos-storage-module
nix build
cd ..
```

### 3. Build yolo-board plugin

```bash
cd zone-sdk-test
nix build .#plugin -o result-plugin
cd ..
```

### 4. Build logos-liblogos (patched logos_host)

This is needed for the `LogosResult` → JSON serialization fix and the `informModuleToken` retry logic.

```bash
cd logos-liblogos
nix build --override-input logos-cpp-sdk path:../logos-cpp-sdk
cd ..
```

## Install

### Install modules to Basecamp dev directory

```bash
MODULES_DIR=~/.local/share/Logos/LogosBasecampDev/modules
PLUGINS_DIR=~/.local/share/Logos/LogosBasecampDev/plugins

# Zone sequencer module
mkdir -p $MODULES_DIR/liblogos_zone_sequencer_module
cp logos-zone-sequencer-module/result/lib/*.so $MODULES_DIR/liblogos_zone_sequencer_module/
cat > $MODULES_DIR/liblogos_zone_sequencer_module/manifest.json << 'EOF'
{
  "name": "liblogos_zone_sequencer_module",
  "version": "0.2.0",
  "type": "core",
  "main": {"linux-amd64-dev": "liblogos_zone_sequencer_module.so", "linux-x86_64-dev": "liblogos_zone_sequencer_module.so"},
  "manifestVersion": "0.1.0",
  "dependencies": []
}
EOF

# Storage module
mkdir -p $MODULES_DIR/storage_module
cp logos-storage-module/result/lib/*.so $MODULES_DIR/storage_module/
cat > $MODULES_DIR/storage_module/manifest.json << 'EOF'
{
  "name": "storage_module",
  "version": "1.0.0",
  "type": "core",
  "main": {"linux-amd64-dev": "storage_module_plugin.so", "linux-x86_64-dev": "storage_module_plugin.so"},
  "manifestVersion": "0.1.0",
  "dependencies": []
}
EOF

# Yolo Board plugin
mkdir -p $PLUGINS_DIR/yolo_board
cp zone-sdk-test/result-plugin/lib/*.so $PLUGINS_DIR/yolo_board/
cat > $PLUGINS_DIR/yolo_board/manifest.json << 'EOF'
{
  "name": "yolo_board",
  "version": "0.1.0",
  "type": "ui",
  "category": "social",
  "dependencies": ["liblogos_zone_sequencer_module", "storage_module"],
  "main": {"linux-amd64-dev": "yolo_board.so", "linux-x86_64-dev": "yolo_board.so"},
  "manifestVersion": "0.1.0"
}
EOF
```

## Launch

```bash
# Use the patched logos_host for LogosResult IPC serialization
LOGOS_HOST_PATH=$(readlink -f logos-liblogos/result/bin/logos_host) \
  QML_PATH=/path/to/zone-sdk-test/src/qml \
  /path/to/logos-basecamp/result/bin/logos-basecamp
```

The `QML_PATH` override is optional — it lets you iterate on QML without rebuilding.

## Usage

1. Click **Yolo Board** in the Basecamp sidebar
2. Enter the path to your Zone data directory (must contain `sequencer.key` and `channel.id`)
3. Enter the zone node URL (e.g. `http://192.168.0.203:8080`)
4. Click **Connect**
5. Type a message and click **Publish** — it's inscribed on-chain
6. Click **+** to attach an image — it's uploaded to Logos Storage, CID embedded in the inscription
7. Subscribe to other channels by name (e.g. `alice`) or hex channel ID

## Architecture

```
Basecamp
├── capability_module     (IPC token auth)
├── package_manager       (plugin management)
├── storage_module        (Codex storage — upload/download via libstorage)
├── zone_sequencer_module (zone inscriptions — publish/query via libzone_sequencer_rs)
└── yolo_board (UI)       (Qt/QML chat UI, calls modules via IPC)
```

- **Publishing**: yolo_board → IPC → zone_sequencer_module → Rust FFI → blockchain
- **Media upload**: yolo_board → IPC → storage_module → libstorage → Codex node
- **Message format**: `{"v":1,"text":"hello","media":[{"cid":"zDv...","type":"image/png","name":"photo.png","size":189972}]}`
- **Queries**: Direct FFI to `libzone_sequencer_rs.so` (bundled with plugin) for fast polling

## Key Fixes Applied

1. **capability_module IPC bug**: Private `logosAPI` member shadowed inherited public one → `informModuleToken` always failed
2. **SDK version alignment**: Zone-sequencer module used old SDK without `LogosInstance::id()` → registry URL mismatch
3. **LogosResult serialization**: Custom type can't cross QRemoteObjects wire → convert to JSON string in `ModuleProxy`
4. **QRemoteObjects threading**: IPC calls must run on main thread (thread-bound) → use `QTimer::singleShot(0)` for deferred execution
5. **QML FileDialog crash**: `QtQuick.Dialogs` crashes in `QQuickWidget` embedding → use C++ `QFileDialog` instead
