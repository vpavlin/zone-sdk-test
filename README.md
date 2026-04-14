# zone-board

A terminal-based bulletin board built on the [Logos blockchain](https://github.com/logos-blockchain/logos-blockchain) Zone SDK. Each user has a **channel** — a persistent, append-only feed of messages anchored on-chain. You can publish to your own channel and subscribe to others.

```
┌──────────────────────────────────────────────────────────────┐
│ ● Zone Board  |  Your channel: 4eb089c5…                     │
├────────────────┬─────────────────────────────────────────────┤
│ Channels       │  [you] 4eb089c5…                            │
│                │                                             │
│ ▶[you] 4eb…⟳  │  12:00:01  Hello world                      │
│  b3f371…       │  12:01:33  Another message                  │
│                │                                             │
├────────────────┴─────────────────────────────────────────────┤
│ published: a3f1b2… (pending finalization)                    │
│ > type a message here▌                                       │
│ ↑↓ select channel  Enter publish  /sub <channel-id>  /quit   │
└──────────────────────────────────────────────────────────────┘
```

---

## Why this exists

This project is a **workshop example** showing how to build a real application on top of a live decentralized blockchain using the Zone SDK. It covers:

- **Identity** — generating and persisting an Ed25519 key pair, deriving a stable channel address from the public key
- **Publishing** — using `ZoneSequencer` to submit inscriptions with crash-resilient checkpointing
- **Reading** — backfilling historical messages with `zone_messages_in_blocks`, then following new blocks live via SSE
- **Race conditions** — how to prevent missing messages between a historical scan and a live stream
- **TUI** — building a responsive terminal UI with `ratatui` driven by a `tokio` async event loop

---

## How it works

### Identity and channels

Your identity is an **Ed25519 key pair** stored in `sequencer.key`. The public key is also your **channel ID** — a 32-byte identifier that is unique to you and derived deterministically:

```rust
let my_channel_id = ChannelId::from(key.public_key().to_bytes());
```

This means there is no registration step: your channel exists the moment you start the app, and anyone who knows your public key (= channel ID) can subscribe to your feed.

### Publishing a message

Messages are published via `ZoneSequencer`, the SDK component responsible for creating and submitting on-chain transactions. The sequencer:

1. Builds a `ChannelInscribe` operation containing your message bytes
2. Signs it with your private key
3. Submits it to the node over HTTP
4. Saves a **checkpoint** (`sequencer.checkpoint`) after each successful submission so it can resume without re-sending on restart

Publishing is asynchronous — the sequencer runs as a background task. When you press Enter, the message appears immediately in the UI as "pending…" and is confirmed once the live block stream delivers it back from the chain.

```
User presses Enter
  → message added to UI as pending
  → tokio::spawn: wait_ready → publish_message → update status
                                         ↓
                          live block stream delivers block
                          → pending entry confirmed in-place
```

#### Sequencer readiness

The sequencer has its own internal block stream subscription and only becomes "ready" after it receives its first block event from the node. This is separate from the indexer's connection dot in the title bar. `wait_ready()` blocks until this happens, ensuring the sequencer has an up-to-date view of the chain before submitting.

Both `wait_ready()` and `publish_message()` are wrapped in a single timeout so a stuck sequencer (e.g. from a stale checkpoint) never hangs the UI indefinitely.

### Reading messages — the gap problem

Reading messages from a channel requires two data sources:

| Source | What it provides |
|--------|-----------------|
| `zone_messages_in_blocks(from, to, channel)` | Historical messages in a slot range (HTTP batch) |
| `block_stream()` | All new blocks as they arrive (SSE) |

The naive approach — backfill first, then subscribe to the live stream — has a **race condition**: blocks that arrive while the backfill is running will be missed.

zone-board solves this by starting the live stream **first**, before fetching any history:

```
time ──────────────────────────────────────────────>

  live stream subscription started
         │
         │   backfill running (genesis → tip)
         │   ╔═══════════════════════════╗
         │   ║  batch 0–10000            ║
         │   ║  batch 10001–20000  ...   ║
         │   ╚═══════════════════════════╝
         │                              │
         │   gap-fill (tip → new tip)   │
         │   ╔═══════════╗              │
         │   ╚═══════════╝              │
         │                              │
         └──────────────────────────────┴──> both active
```

Any block that arrives via the live stream while the backfill is running is buffered in a `tokio::mpsc` channel and processed by the main loop. Duplicates (same block delivered by both sources) are deduplicated by block ID.

A **gap-fill** pass runs after the main backfill: it fetches from the original `tip` to the current tip, covering the window during which the backfill was running.

### Historical backfill efficiency

The node API returns messages in slot ranges. Using 10,000-slot batches keeps the number of HTTP requests small — around 11 requests to cover 110,000 slots — instead of 1,000+ requests with a 100-slot batch.

### Persistence

| File | Contents | Committed? |
|------|----------|-----------|
| `sequencer.key` | 32-byte Ed25519 private key | No (gitignored) |
| `sequencer.checkpoint` | Last confirmed message ID + pending tx list | No (gitignored) |
| `subscriptions.json` | Hex channel IDs to re-subscribe on startup | No (gitignored) |
| `zone-board.log` | Warnings and errors (tail with `tail -f`) | No (gitignored) |

These files are created automatically on first run and are ignored by git.

---

## Getting started

### Prerequisites

- Rust (toolchain pinned to 1.85 via `rust-toolchain.toml`)
- Access to a running Logos blockchain node (URL required)

### Build

```sh
git clone https://github.com/vpavlin/zone-sdk-test
cd zone-sdk-test
cargo build --release
```

The `vendor/core2` directory contains a vendored copy of the `core2` crate (which is yanked on crates.io but required transitively by the SDK). The `[patch.crates-io]` entry in `Cargo.toml` wires this up automatically — no extra steps needed.

### Run

```sh
cargo run --release -- --node-url http://<node-host>:<port>
```

Or set the environment variable:

```sh
NODE_URL=http://localhost:8080 cargo run --release
```

By default all data files are written to the current directory. Use `--data-dir /path/to/dir` (or `DATA_DIR=...`) to store them elsewhere.

### Controls

| Key / Command | Action |
|---------------|--------|
| `↑` / `↓` | Move between channels |
| `Enter` | Publish typed message to your channel |
| `/sub <hex-channel-id>` | Subscribe to another channel |
| `/unsub` | Unsubscribe the currently selected channel |
| `/quit` or `/q` | Exit |
| `Ctrl+C` | Exit |

### Reading logs

The TUI takes over the terminal, so logs are written to `zone-board.log`. Tail it in a second terminal:

```sh
tail -f zone-board.log
```

Set `RUST_LOG=info` for more verbose output (the SDK's sequencer produces useful `info`-level events).

---

## Code tour

```
src/
├── main.rs     clap args, startup sequence, terminal setup
├── app.rs      App state, event loop, sequencer + indexer logic
├── ui.rs       ratatui layout and rendering
└── config.rs   key/checkpoint/subscription persistence
vendor/
└── core2/      vendored yanked crate required by the SDK
```

### `app.rs` — the heart of the app

**`App::spawn_indexer_for(channel_id)`** — starts two concurrent tasks per channel:

1. A **live stream task** that subscribes to `block_stream()` immediately and sends matching blocks to the main loop via `mpsc::Sender`. Reconnects automatically on disconnect.
2. A **backfill task** that scans historical slots in 10,000-slot batches, then runs a gap-fill pass, then exits. Progress is reported via the `status_tx` channel and reflected in the `⟳` sync indicator.

**`App::publish_input(text)`** — spawns a task that calls `handle.wait_ready()` followed by `handle.publish_message()`, both wrapped in a single 120-second timeout. The message appears immediately in the UI as pending and is confirmed when the indexer delivers the on-chain block.

**`App::drain_background_channels()`** — called every 50 ms from the main loop. Drains all `mpsc` receivers: incoming blocks (with dedup), status strings, checkpoints, sync state, and connection state.

---

## Workshop exercises

1. **Add timestamps from the block** — the `zone_messages_in_blocks` stream yields `(ZoneMessage, Slot)`. Use the slot number to show a block height instead of the local wall-clock time.

2. **Sender attribution** — the `ChannelInscribe` op includes a `signer` field (the author's channel ID). Display the first 8 hex chars as a "from" prefix on each message.

3. **Channel discovery** — add a `/list` command that fetches the last N blocks and lists all unique channel IDs seen, so users can find channels to subscribe to.

4. **Message search** — add `/find <keyword>` to search the local message cache.

5. **Unread counts** — track the last-seen message index per channel and show a count badge in the channel list.
