# Yolo Board

A censorship-resistant bulletin board on the Logos blockchain.

Publish text and images as on-chain inscriptions. Anyone with a node URL can read; anyone with a signing key can write. No accounts, no servers, no moderation.

## What's in this repo

| Path | What it is |
|------|-----------|
| `src/qml/Main.qml` | **Basecamp UI plugin** — QML thin client that renders channels, messages, and media inside [Logos Basecamp](https://github.com/jimmyjames/logos-basecamp) |
| `storage-tui/` | **Storage TUI** — Ratatui terminal UI for browsing a Logos Storage (Codex-compatible) node: peer count, local manifests, CID fetch |
| `pinner/` | Standalone CID pinner utility |
| `plugins/chess_ui/` | Chess UI plugin (example / bonus) |
| `docs/` | Architecture, build, and exercise docs |

The backend logic (polling, message cache, subscriptions, upload orchestration) lives in a companion repo: **[vpavlin/logos-yolo-board-module](https://github.com/vpavlin/logos-yolo-board-module)**.

## Basecamp plugin

The QML plugin runs inside [Logos Basecamp](https://github.com/jimmyjames/logos-basecamp) as a `ui_qml` plugin. It calls into `yolo_board_module` over QRO IPC and never touches the blockchain or storage directly.

See **[docs/BUILD.md](docs/BUILD.md)** for full build + install instructions.

**Quick install** (assuming Basecamp and `lgpm` are already set up):

```bash
git clone -b basecamp https://github.com/vpavlin/zone-sdk-test.git
git clone https://github.com/vpavlin/logos-yolo-board-module.git

cd zone-sdk-test && nix build          # produces result/yolo-board.lgx
cd ../logos-yolo-board-module && nix build   # produces result/yolo-board-module.lgx

LGPM=/path/to/lgpm
BC=~/.local/share/Logos/LogosBasecampDev

$LGPM --modules-dir $BC/modules --ui-plugins-dir $BC/plugins install --file logos-yolo-board-module/result/yolo-board-module.lgx
$LGPM --modules-dir $BC/modules --ui-plugins-dir $BC/plugins install --file zone-sdk-test/result/yolo-board.lgx

# Dev Basecamp expects "-dev" variant keys
sed -i 's/"linux-amd64"/"linux-amd64-dev"/g; s/"linux-x86_64"/"linux-x86_64-dev"/g' \
    $BC/modules/*/manifest.json $BC/plugins/*/manifest.json
```

Then launch Basecamp and click **Yolo Board** in the sidebar.

## Storage TUI

A terminal UI for a Logos Storage / Codex-compatible REST node.

```bash
cd storage-tui
cargo build --release
./target/release/logos-storage-tui --url http://<node-ip>:8080
```

Shows connected peers, locally available manifests, and lets you fetch any CID by pasting it into the input box.

## Architecture

```
Basecamp process
├── LogosQmlBridge          (logos.callModule() → IPC)
└── yolo_board (Main.qml)
        │
        │  callModule("yolo_board_module", method, args)
        ▼
logos_host[yolo_board_module]     — all domain logic
   ├─ message cache, subscriptions, media cache
   ├─ upload orchestration (Storage upload → CID → on-chain publish)
   └─ media mirroring into plugin dir (QML sandbox workaround)
        │
        ├──► logos_host[zone_sequencer_module]   (Rust FFI → zone node)
        └──► logos_host[storage_module]          (libstorage / Codex)
```

See [docs/02-architecture.md](docs/02-architecture.md) for the full picture.
