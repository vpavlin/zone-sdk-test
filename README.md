# zone-board

A terminal bulletin board built on the [Logos blockchain](https://github.com/logos-blockchain/logos-blockchain) Zone SDK. Each user has a **channel** — a persistent, append-only feed anchored on-chain. You can publish to your own channel and subscribe to others.

```
+---------------------------------------------------------------------+
| ● Zone Board  |  Your channel: vpavlin  (6c6f676f733a796f6c)        |
|               ⟳ [████████████░░░░░░░░]  62%                         |
+----------------+----------------------------------------------------+
| Channels       |  [you] vpavlin                                     |
|                |                                                    |
| ▶[you] vpavlin |  12:00:01  Hello world                             |
|  alice  [3]    |  12:01:33  Another message                         |
|                |                                                    |
+----------------+----------------------------------------------------+
| published: a3f1b2... (pending finalization)                         |
| > type a message here▌                                              |
| ↑↓ select channel  Enter publish  /sub <name|hex>  /unsub  /resync  /quit |
+---------------------------------------------------------------------+
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

### Reading messages

Backfill scans `zone_messages_in_blocks` from genesis to the current canonical tip in 100-slot batches, followed by a gap-fill loop that catches any blocks that became canonical during the scan.

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
# or via env vars
NODE_URL=http://localhost:8080 CHANNEL=yourname ./zone-board
```

Use `--data-dir /path/to/dir` (or `DATA_DIR=...`) to store data files elsewhere.

### Controls

| Key / Command | Action |
|---------------|--------|
| `↑` / `↓` | Move between channels |
| `Enter` | Publish typed message to your channel |
| `/sub <name>` | Subscribe by name (e.g. `/sub alice`) |
| `/sub <hex>` | Subscribe by 64-char hex channel ID |
| `/unsub` | Unsubscribe the currently selected channel |
| `/resync` | Wipe cache and re-scan selected channel from genesis |
| `/quit` or `/q` | Exit |
| `Ctrl+C` | Exit |

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
| `zone-board.log` | Warnings and errors |

All gitignored, created automatically on first run.

---

## Code tour

```
src/
├── main.rs     clap args, startup sequence, terminal setup
├── app.rs      App state, event loop, sequencer + indexer logic
├── ui.rs       ratatui layout and rendering
└── config.rs   key/checkpoint/subscription/cache persistence
```

---

## Workshop exercises

1. **Block timestamps** — `zone_messages_in_blocks` yields `(ZoneMessage, Slot)`. Use the slot number instead of wall-clock time.
2. **Sender attribution** — `ChannelInscribe` includes a `signer` field. Show the first 8 hex chars as a "from" prefix.
3. **Channel discovery** — add `/list` to scan recent blocks and list all unique channel IDs seen.
4. **Message search** — add `/find <keyword>` to search the local message cache.
5. **Cursor persistence** — save `last_lib` per channel so the live poll resumes where it left off after a restart.
