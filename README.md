# zone-board

A terminal bulletin board built on the [Logos blockchain](https://github.com/logos-blockchain/logos-blockchain) Zone SDK. Each user has a **channel** — a persistent, append-only feed anchored on-chain. You can publish to your own channel and subscribe to others.

> **Next step:** the [`basecamp` branch](https://github.com/vpavlin/zone-sdk-test/tree/basecamp) contains a full GUI version as a [Logos Basecamp](https://github.com/jimmyjames/logos-basecamp) plugin — channels, messages, image attachments, and per-message threads, all inside the Basecamp desktop app.

```
+----------------+-----------------------------+-------------------------+
| Channels       |  Messages                   |  Thread                 |
|                |                             |  ↳ Hello world          |
| ▶[you] vpavlin |  12:00:01  Hello world      |  ─────────────────────  |
|  alice  [3]    |  12:01:33  Another message  |  12:02:10  nice one!    |
|                |  12:03:44  [image.png]       |  12:02:55  agreed       |
|                |                             |  No more replies yet.   |
+----------------+-----------------------------+-------------------------+
| > type a message here▌                                                |
| Tab: messages  ↑↓ channel  Enter publish  /sub /unsub /upload /quit  |
+-----------------------------------------------------------------------+
```

---

## How it works

### Identity

Your identity has two independent components:

- **Signing key** (`sequencer.key`) — Ed25519 key pair used to authorize inscriptions
- **Channel ID** (`channel.id`) — 32-byte address for your feed, shared with others

They are intentionally decoupled: you can rotate your signing key without changing your channel address.

### Human-readable channel names

`--channel` accepts a plain name or a 64-char hex ID. Names are encoded as `logos:yolo:<name>` zero-padded to 32 bytes:

```sh
cargo run -- --node-url http://... --channel vpavlin
cargo run -- --node-url http://... --channel 6c6f676f733a796f6c6f...
```

### Publishing

Messages go through `ZoneSequencer`, which builds a signed `ChannelInscribe` transaction and submits it over HTTP. The sequencer saves a **checkpoint** after each submission for crash-resilient restarts.

When you press Enter, the message appears immediately as "pending…" and is confirmed once the live poller delivers the finalized block (within ~3 seconds). If publishing times out or errors, the entry turns red with ✗.

### Image attachments

With `--storage-url` pointing at a Logos Storage (Codex-compatible) node, use `/upload` to attach a file to your next message:

```
/upload ~/photos/screenshot.png optional caption here
```

The file is uploaded to storage, the CID is embedded in the message payload as `{"v":1,"text":"caption","media":[{"cid":"..."}]}`, and the message is published on-chain. Recipients with storage access can fetch the file by CID.

### Threaded replies

Press `Tab` from the channel list to focus the message panel, then navigate with `↑`/`↓` and press `Enter` on any message to open its thread. The thread panel shows replies in real time; type a reply and press `Enter` to send. Press `Esc` to close the thread.

### Reading messages

Backfill scans `zone_messages_in_blocks` from the last saved slot (or genesis on first run) to the current canonical tip in 100-slot batches. Progress is saved to disk so a restart resumes where it left off rather than rescanning from genesis.

Live delivery uses two concurrent approaches:
- **`block_stream()`** — SSE stream for immediate delivery of new canonical blocks
- **Polling** — every 3 seconds scans `zone_messages_in_blocks` as a reliable backstop (SSE reconnects silently lose any blocks that arrived during the gap)

Both deduplicate by `block_id`, so the same block delivered twice is shown once.

### Sync progress

While backfilling, the title bar shows progress as `current_slot / tip_slot`. When multiple channels sync simultaneously, the bar tracks the slowest one.

### Unread badges

Channels with new messages show a yellow `[N]` badge. The count resets when you navigate to that channel. Historical messages loaded at startup are never counted as unread.

---

## Getting started

### Prerequisites

- Rust (recent stable)
- A running Logos blockchain node

### Build

```sh
git clone https://github.com/vpavlin/zone-sdk-test
cd zone-sdk-test
cargo build --release
```

`vendor/core2` contains a vendored copy of a yanked crate required by the SDK — no extra steps needed.

### Run

```sh
./zone-board --node-url http://<node-host>:<port> --channel yourname

# With image upload support (Logos Storage / Codex node):
./zone-board --node-url http://<node-host>:<port> --channel yourname \
             --storage-url http://<storage-host>:<port>

# Via env vars:
NODE_URL=http://localhost:8080 CHANNEL=yourname \
STORAGE_URL=http://localhost:8090 ./zone-board
```

Use `--data-dir /path/to/dir` (or `DATA_DIR=...`) to store data files elsewhere.

### Controls

**Channel panel** (default focus)

| Key / Command | Action |
|---------------|--------|
| `↑` / `↓` | Move between channels |
| `Tab` | Move focus to message panel |
| `Enter` | Publish typed message to your channel |
| `/sub <name>` | Subscribe by name (e.g. `/sub alice`) |
| `/sub <hex>` | Subscribe by 64-char hex channel ID |
| `/unsub` | Unsubscribe the currently selected channel |
| `/upload <path> [caption]` | Upload file to storage and publish CID on-chain |
| `/resync` | Wipe cache and re-scan selected channel from genesis |
| `/quit` or `/q` | Exit |
| `Ctrl+C` | Exit |

**Message panel** (`Tab` to enter)

| Key | Action |
|-----|--------|
| `↑` / `↓` | Select a message |
| `Enter` | Open thread for selected message |
| `Esc` | Return to channel panel |

**Thread panel** (opened with `Enter` on a message)

| Key | Action |
|-----|--------|
| `Enter` | Send reply |
| `Esc` | Close thread |

### Logs

The TUI takes over the terminal — logs go to `zone-board.log`:

```sh
tail -f zone-board.log
RUST_LOG=info ./zone-board ...   # more verbose
```

---

## Persistent files

| File | Contents |
|------|----------|
| `sequencer.key` | Ed25519 private key |
| `channel.id` | Your channel address |
| `sequencer.checkpoint` | Last confirmed message ID + pending tx list |
| `subscriptions.json` | Channels to re-subscribe on startup |
| `cache/<hex>.json` | Cached messages per channel |
| `index_<hex>.slot` | Last backfill slot per channel (enables resume) |
| `zone-board.log` | Warnings and errors |

All gitignored, created automatically on first run.

---

## Code tour

```
src/
├── main.rs      clap args, startup sequence, terminal setup
├── app.rs       App state, event loop, sequencer + indexer logic
├── ui.rs        ratatui layout: channel list, message panel, thread panel
├── config.rs    key/checkpoint/subscription/cache/slot persistence
└── storage.rs   Logos Storage (Codex) REST client for /upload
```

---

## Workshop exercises

1. **Block timestamps** — `zone_messages_in_blocks` yields `(ZoneMessage, Slot)`. Use the slot number instead of wall-clock time.
2. **Sender attribution** — `ChannelInscribe` includes a `signer` field. Show the first 8 hex chars as a "from" prefix.
3. **Channel discovery** — add `/list` to scan recent blocks and list all unique channel IDs seen.
4. **Message search** — add `/find <keyword>` to search the local message cache.
5. **Cursor persistence** — ✅ done: backfill slot is saved per channel and resumed on restart.
