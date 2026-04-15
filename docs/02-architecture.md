# Architecture

This document walks through zone-board's code structure and the key design decisions behind it.

---

## File map

```
src/
├── main.rs     Entry point: parse args, wire components, run event loop
├── app.rs      All application logic: state, events, indexers, sequencer
├── ui.rs       Pure rendering — reads App state, draws ratatui widgets
└── config.rs   Disk I/O: keys, checkpoints, subscriptions, message cache
```

The app follows a simple unidirectional data flow:

```
Background tasks
  (indexers, publisher)
        │  mpsc channels
        ▼
    App state
        │
        ▼
    ui::render()
```

`App` is the only mutable state. Background tasks communicate back via `mpsc` senders; the main loop drains them every 50 ms.

---

## `App` struct (`src/app.rs`)

The central state container:

```rust
pub struct App {
    pub my_channel_id: ChannelId,
    sequencer_handle: SequencerHandle,
    node: NodeHttpClient,

    pub channels: Vec<ChannelEntry>,   // own channel always at index 0
    pub selected: usize,
    pub messages: HashMap<ChannelId, Vec<DisplayMessage>>,
    pub input: String,
    pub status: String,

    indexer_handles: HashMap<ChannelId, IndexerHandles>,
    unread: HashMap<ChannelId, usize>,

    // Background → foreground channels
    msg_tx / msg_rx          // (ChannelId, ZoneMessage, Slot)
    status_tx / status_rx    // String
    checkpoint_tx / checkpoint_rx  // SequencerCheckpoint
    sync_tx / sync_rx        // SyncUpdate
    conn_tx / conn_rx        // bool (node connected?)
    publish_fail_tx / publish_fail_rx  // String (failed message text)
}
```

### `IndexerHandles`

Each subscribed channel gets a pair of handles:

```rust
struct IndexerHandles {
    outer: tokio::task::JoinHandle<()>,   // the backfill task
    live_cancel: tokio::sync::watch::Sender<bool>,  // cancels live sub-tasks
}
```

`handle.abort()` kills the outer (backfill) task. The inner live-stream and polling tasks are signalled via the `watch` channel, which they check in their loops.

---

## Indexer lifecycle (`spawn_indexer_for`)

```
spawn_indexer_for(channel_id)
│
├─ outer task (JoinHandle in indexer_handles)
│   │
│   ├─ 1. tip_at_start = consensus_info().slot
│   ├─ 2. backfill: fetch_range(0, tip_at_start) in 100-slot batches
│   ├─ 3. gap-fill: poll info.slot until it stops moving, scan new range
│   ├─ 4. send SyncUpdate::Done
│   │
│   ├─ spawn sub-task A: block_stream() loop
│   │     checks cancel_rx_stream.has_changed()
│   │     on each block: send to msg_tx, check for cancellation
│   │
│   └─ spawn sub-task B: polling loop (every 3s)
│         checks cancel_rx_poll.has_changed()
│         calls consensus_info().slot
│         if advanced: fetch_range(last_slot+1, tip), update last_slot
```

Cancellation (on `/resync` or `/unsub`):

```rust
let _ = handles.live_cancel.send(true);   // signals sub-tasks A and B
handles.outer.abort();                     // kills the outer task
```

Sub-tasks A and B check `cancel_rx.has_changed()` at the top of each loop iteration and break if `true`.

---

## Event loop (`App::run`)

```
loop {
    terminal.draw(|f| ui::render(f, &app))?;

    // Handle keyboard (non-blocking, 50ms poll)
    if event::poll(Duration::from_millis(50))? {
        if let Event::Key(key) = event::read()? {
            app.handle_key(key).await;
        }
    }

    // Drain background channels
    app.drain_background_channels();

    if app.should_quit { break; }
}
```

`drain_background_channels` processes all pending messages from every `mpsc` receiver in a single pass, keeping the UI responsive.

---

## Input handling (`handle_key`)

```
Enter key
  ├─ input is empty → no-op
  ├─ input starts with '/' →
  │   ├─ /sub <arg>  → subscribe
  │   ├─ /unsub      → unsubscribe selected
  │   ├─ /resync     → wipe cache, restart indexer
  │   ├─ /quit /q    → set should_quit
  │   └─ anything else → status = "unknown command: …"  (NOT published)
  └─ plain text → publish_input(text)
```

The `/` catch-all prevents typo'd commands (e.g. `/resyncc`) from being accidentally published on-chain.

---

## Message confirmation flow

```
publish_input(text)
  → add DisplayMessage { text, pending: true } to own channel
  → tokio::spawn:
      wait_ready() + publish_message()  [120s timeout]
        ├─ ok   → status bar updated
        └─ err  → publish_fail_tx.send(text)

drain_background_channels()
  → publish_fail_rx: mark matching pending entry as failed=true

  → msg_rx: incoming block with matching text
      → replace pending/failed entry with confirmed entry (block_id set)
```

A failed entry (red ✗) can still be confirmed if the transaction eventually lands on-chain (e.g. if the timeout fired but the node actually accepted it).

---

## Persistence (`src/config.rs`)

| File | Function | Format |
|------|----------|--------|
| `sequencer.key` | `load_or_create_key` | Raw 32 bytes |
| `channel.id` | `load_or_create_channel_id` | Raw 32 bytes |
| `sequencer.checkpoint` | `load_checkpoint` / `save_checkpoint` | JSON |
| `sequencer.checkpoint.channel` | sidecar for checkpoint safety | Raw 32 bytes |
| `subscriptions.json` | `load_subscriptions` / `save_subscriptions` | JSON array of hex strings |
| `cache/<hex>.json` | `load_cache` / `save_cache` | JSON array of `DisplayMessage` |

The cache is written on quit and loaded before the indexer starts, so messages are visible immediately on the next run without waiting for a full backfill.

---

## Rendering (`src/ui.rs`)

`ui::render` is a pure function — it reads `App` and produces a frame. No state is mutated here.

Layout:

```
┌──────────────────────────────────────────────────────────┐ ← render_title (1 row)
├────────────┬─────────────────────────────────────────────┤
│            │                                             │ ← render_content
│ render_    │ render_messages                             │
│ channels   │                                             │
│            │                                             │
├────────────┴─────────────────────────────────────────────┤
│ status line                                              │ ← render_bottom (3 rows)
│ > input▌                                                 │
│ help text                                                │
└──────────────────────────────────────────────────────────┘
```

Messages are rendered tail-first: only the last `inner_height` entries are shown so new messages always scroll into view. There is no manual scroll — this is intentional for a bulletin board where you care about what's new.
