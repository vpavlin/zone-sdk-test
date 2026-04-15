# zone-board

A terminal-based bulletin board built on the [Logos blockchain](https://github.com/logos-blockchain/logos-blockchain) Zone SDK. Each user has a **channel** — a persistent, append-only feed of messages anchored on-chain. You can publish to your own channel and subscribe to others.

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

## Why this exists

This project is a **workshop example** showing how to build a real application on top of a live decentralized blockchain using the Zone SDK. It covers:

- **Identity** — generating and persisting an Ed25519 key pair, with a channel address decoupled from the signing key
- **Human-readable channels** — encoding UTF-8 names into 32-byte channel IDs using a namespace prefix
- **Publishing** — using `ZoneSequencer` to submit inscriptions with crash-resilient checkpointing
- **Reading** — backfilling historical messages with `zone_messages_in_blocks`, then tailing new finalized blocks by polling `consensus_info().lib_slot`
- **Reliability** — why SSE reconnection gaps cause silent message loss, and how lib-slot polling eliminates that class of bug
- **TUI** — building a responsive terminal UI with `ratatui` driven by a `tokio` async event loop

---

## How it works

### Identity and channels

Your identity has two independent components:

- **Signing key** (`sequencer.key`) — an Ed25519 key pair used to authorize inscriptions. Never shared.
- **Channel ID** (`channel.id`) — a 32-byte address for your feed. This is what you share with others so they can subscribe to you.

On first run a random channel ID is generated and saved. The two are intentionally decoupled: the SDK only requires that the signer is *authorized* for the channel, not that the channel ID equals the public key. This means you can rotate your signing key without changing your channel address, or share a channel between multiple signers.

#### Human-readable channel names

The `--channel` flag accepts either a hex ID or a plain name. Names are stored as `logos:yolo:<name>` zero-padded to 32 bytes, giving all named channels a shared namespace:

```sh
# Pick a name (max 21 chars)
cargo run -- --node-url http://... --channel vpavlin

# Use a raw 32-byte hex ID
cargo run -- --node-url http://... --channel 6c6f676f733a796f6c6f...
```

The UI automatically decodes the `logos:yolo:` prefix so only `vpavlin` is shown in the sidebar and title bar. The full hex is shown in the title bar alongside the name so you can share it.

---

### Publishing a message

Messages are published via `ZoneSequencer`, the SDK component responsible for creating and submitting on-chain transactions. The sequencer:

1. Builds a `ChannelInscribe` operation containing your message bytes
2. Signs it with your private key
3. Submits it to the node over HTTP
4. Saves a **checkpoint** (`sequencer.checkpoint`) after each successful submission so it can resume without re-sending on restart

Publishing is asynchronous — the sequencer runs as a background task. When you press Enter, the message appears immediately in the UI as "pending…" and is confirmed once the polling loop delivers the finalized block back from the chain (within ~3 seconds).

```
User presses Enter
  → message added to UI as pending
  → tokio::spawn: wait_ready() → publish_message() → update status
                                          |
                          node finalizes the block (LIB advances)
                          → live poll delivers block via zone_messages_in_blocks
                          → pending entry confirmed in-place
```

#### Sequencer readiness

The sequencer has its own internal block stream subscription and only becomes "ready" after it receives its first block event from the node. `wait_ready()` blocks until this happens, ensuring the sequencer has an up-to-date view of the chain before submitting.

Both `wait_ready()` and `publish_message()` are wrapped in a single 120-second timeout so a stuck sequencer never hangs the UI indefinitely.

#### Checkpoint safety

The checkpoint is tied to a specific channel ID via a `.channel` sidecar file. If you switch channels (e.g. change `--channel`), the old checkpoint is automatically discarded on startup instead of causing the sequencer to loop trying to resubmit stale transactions for the wrong channel.

---

### Reading messages — why this is tricky

#### The /blocks API only returns finalized blocks

The node's `/blocks` endpoint (used internally by `zone_messages_in_blocks`) runs a server-side scan over the **immutable** (past-LIB) chain. It ignores any block that has not yet passed the finality threshold, regardless of what slot range you request.

This means the "tip slot" from `consensus_info().slot` is not the right backfill target — slots above the LIB return empty results. The correct endpoint is `consensus_info().lib_slot`, which is exactly what the SDK's own `ZoneIndexer` uses.

#### The SSE reconnect gap problem

An earlier version of this app used `block_stream()` (a Server-Sent Events stream) for live message delivery. The stream delivers canonical blocks as soon as they appear, which gives low latency. But there is a catch:

```
time ────────────────────────────────────────────────────────>

  SSE stream active           stream drops     stream reconnects
  ─────────────────────────── X               ───────────────>
                               └─── gap ──────┘
                                    blocks here
                                    are LOST FOREVER
```

When the SSE stream reconnects, it starts from the *current* head. Any blocks that arrived during the gap are skipped. Once those blocks become finalized (past LIB), the backfill has already completed and won't re-scan them. They are silently lost.

#### The fix: lib-slot polling

Instead of the SSE stream, zone-board polls `consensus_info().lib_slot` every 3 seconds. When the LIB slot advances, it scans the new range with `zone_messages_in_blocks`:

```
time ─────────────────────────────────────────────────────────>

  backfill: genesis ──────────────────────> lib_at_start
  gap-fill: lib_at_start ──> lib (repeated until stable)

  live poll:   t+3s     t+6s     t+9s     t+12s ...
               │        │        │        │
               └─scan───┴─scan───┴─scan───┴─scan→
               last_lib         last_lib advances on success only
```

If a poll request fails, `last_lib` is not advanced — the same range is retried on the next cycle. This guarantees that every finalized message is eventually delivered, regardless of transient network errors.

The trade-off compared to SSE: messages appear within ~3 seconds of finalization rather than instantly. For a bulletin board this is entirely acceptable.

#### Deduplication

Both the backfill and the live poll can deliver the same block (e.g. a block finalized during the gap-fill). Each `DisplayMessage` stores the on-chain `block_id` (32-byte hash). Incoming blocks are skipped if a matching `block_id` is already in the channel's message list.

#### Local message cache

To avoid re-scanning the full chain history on every startup, confirmed messages are saved to `cache/<channel_hex>.json` on quit. On the next run the cache is loaded before the indexer starts, so messages appear immediately. The backfill still runs to catch anything published since the last session, but it's usually fast.

#### /resync

`/resync` wipes the cache and restarts the indexer for the selected channel from genesis. Useful if the cache is suspected stale or messages appear out of order.

---

### Sync progress indicator

While a channel is backfilling, the title bar shows a progress bar:

```
⟳ [████████████░░░░░░░░]  62%
```

Progress is computed as `current_slot / lib_slot_at_start × 100`. When multiple channels are syncing simultaneously, the bar shows the percentage of the *slowest* channel so it doesn't vanish before everything is done.

### Unread message badges

Channels with messages you haven't seen yet show a yellow badge in the sidebar:

```
  alice  [3]
```

The count resets when you navigate to that channel. Messages that are already present when the sync completes (historical messages) are never counted as unread.

---

### Persistence

| File | Contents | Committed? |
|------|----------|-----------|
| `sequencer.key` | 32-byte Ed25519 private key | No (gitignored) |
| `channel.id` | 32-byte channel address | No (gitignored) |
| `sequencer.checkpoint` | Last confirmed message ID + pending tx list | No (gitignored) |
| `sequencer.checkpoint.channel` | Channel ID the checkpoint belongs to | No (gitignored) |
| `subscriptions.json` | Channel IDs to re-subscribe on startup | No (gitignored) |
| `cache/<hex>.json` | Cached confirmed messages per channel | No (gitignored) |
| `zone-board.log` | Warnings and errors (tail with `tail -f`) | No (gitignored) |

These files are created automatically on first run and are ignored by git.

---

## Getting started

### Prerequisites

- Rust (toolchain pinned to 1.93 via the release workflow; any recent stable works locally)
- Access to a running Logos blockchain node (URL required)

### Build

```sh
git clone https://github.com/vpavlin/zone-sdk-test
cd zone-sdk-test
cargo build --release
```

The `vendor/core2` directory contains a vendored copy of the `core2` crate (which is yanked on crates.io but required transitively by the SDK). The `[patch.crates-io]` entry in `Cargo.toml` wires this up automatically — no extra steps needed.

### Download a pre-built binary

Pre-built binaries for Linux (x86\_64, aarch64) and macOS (arm64, x86\_64) are attached to each [GitHub release](https://github.com/vpavlin/zone-sdk-test/releases).

### Run

```sh
# With a human-readable channel name
./zone-board --node-url http://<node-host>:<port> --channel yourname

# With just a node URL (generates a random channel ID on first run)
./zone-board --node-url http://<node-host>:<port>
```

Or via environment variables:

```sh
NODE_URL=http://localhost:8080 CHANNEL=yourname ./zone-board
```

By default all data files are written to the current directory. Use `--data-dir /path/to/dir` (or `DATA_DIR=...`) to store them elsewhere.

### Controls

| Key / Command | Action |
|---------------|--------|
| `↑` / `↓` | Move between channels |
| `Enter` | Publish typed message to your channel |
| `/sub <name>` | Subscribe by human-readable name (e.g. `/sub alice`) |
| `/sub <hex>` | Subscribe by 64-char hex channel ID |
| `/unsub` | Unsubscribe the currently selected channel |
| `/resync` | Wipe cache and re-scan the selected channel from genesis |
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
└── config.rs   key/checkpoint/subscription/cache persistence
vendor/
└── core2/      vendored yanked crate required by the SDK
```

### `app.rs` — the heart of the app

**`App::spawn_indexer_for(channel_id)`** — starts an indexer for a channel in two phases:

1. **Backfill task** (outer `tokio::spawn`): scans `zone_messages_in_blocks` from genesis to the current `lib_slot` in 100-slot batches. After the main scan, a convergent gap-fill loop re-checks `lib_slot` until it stops moving, catching any blocks that became immutable while the backfill was running. Emits `SyncUpdate` progress events for the progress bar.

2. **Live poll sub-task** (inner `tokio::spawn`, started after backfill completes): wakes every 3 seconds, calls `consensus_info()` to check whether `lib_slot` has advanced, and if so fetches the new slot range via `zone_messages_in_blocks`. The `last_lib` cursor only advances on a successful fetch, so transient errors are retried automatically.

Both tasks share a `tokio::sync::watch` cancellation channel. Calling `live_cancel.send(true)` (from `/resync` or `/unsub`) stops the poll sub-task gracefully; `handle.abort()` kills the outer task.

**`App::publish_input(text)`** — spawns a task that calls `handle.wait_ready()` followed by `handle.publish_message()`, both wrapped in a single 120-second timeout. The message appears immediately in the UI as pending and is confirmed when the live poll delivers the on-chain block.

**`App::drain_background_channels()`** — called every 50 ms from the main loop. Drains all `mpsc` receivers: incoming blocks (with dedup by `block_id`), status strings, checkpoints, sync progress, and connection state.

---

## Workshop exercises

1. **Add timestamps from the block** — the `zone_messages_in_blocks` stream yields `(ZoneMessage, Slot)`. Use the slot number to show a block height instead of the local wall-clock time.

2. **Sender attribution** — the `ChannelInscribe` op includes a `signer` field (the author's public key). Display the first 8 hex chars as a "from" prefix on each message.

3. **Channel discovery** — add a `/list` command that fetches the last N blocks and lists all unique channel IDs seen, so users can find channels to subscribe to.

4. **Message search** — add `/find <keyword>` to search the local message cache.

5. **Cursor persistence** — save `last_lib` per channel to disk so the live poll resumes from where it left off after a restart, rather than re-running the full backfill each time.
