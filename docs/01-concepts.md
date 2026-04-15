# Zone SDK Concepts

This document explains the core primitives of the Logos blockchain Zone SDK that zone-board is built on. Understanding these makes the code in `app.rs` and `config.rs` much easier to follow.

---

## The chain model

The Logos blockchain is a **slot-based chain**. Each slot may contain a block. Blocks progress through two states:

| State | Meaning |
|-------|---------|
| **Canonical** | The block is part of the current best chain but may still be reorganized away |
| **Immutable / finalized** | The block has passed the **LIB** (Last Irreversible Block) threshold and can never be rolled back |

The node exposes two useful slot pointers via `consensus_info()`:
- `slot` — the current canonical tip
- `lib_slot` — the highest finalized slot

For reading historical messages you need `slot` as the upper bound (on some testnets `lib_slot` lags far behind the canonical tip, making it an unreliable target).

---

## Channels

A **channel** is a 32-byte identifier (`ChannelId`) that acts as an address for a feed of messages. It is completely independent of the signing key — you choose the channel ID separately.

### Human-readable names

The SDK accepts any 32 bytes as a channel ID. zone-board uses a naming convention:

```
"logos:yolo:<name>"  zero-padded to 32 bytes
```

This gives all named channels a shared namespace prefix, making them easy to discover and display. The prefix is stripped in the UI so only the plain name is shown.

```rust
// Encoding a name
let full = format!("logos:yolo:{name}");
let mut arr = [0u8; 32];
arr[..full.len()].copy_from_slice(full.as_bytes());
let channel_id = ChannelId::from(arr);
```

---

## ZoneSequencer — publishing

`ZoneSequencer` is the SDK component responsible for writing to a channel. It:

1. Builds a `ChannelInscribe` operation containing your payload bytes
2. Signs it with your Ed25519 key
3. Submits it to the node over HTTP
4. Persists a **checkpoint** (`SequencerCheckpoint`) after each successful submission

The checkpoint makes publishing crash-resilient: if the process dies mid-transaction, the sequencer resumes from the last confirmed state on restart rather than re-submitting stale transactions.

### Sequencer readiness

The sequencer subscribes to its own block stream internally and becomes "ready" only after it receives its first block event. Always call `handle.wait_ready()` before `handle.publish_message()` to ensure the sequencer has an up-to-date chain view:

```rust
handle.wait_ready().await?;
handle.publish_message(text.into_bytes()).await?;
```

zone-board wraps both in a 120-second timeout so a stuck sequencer never freezes the UI.

### Checkpoint safety

The checkpoint is channel-specific. zone-board saves a `.channel` sidecar file alongside the checkpoint. On startup, if the channel IDs don't match (e.g. you changed `--channel`), the stale checkpoint is discarded automatically.

---

## ZoneIndexer — reading

`ZoneIndexer` is the SDK component for reading messages from any channel. The primary API used by zone-board is:

```rust
zone_messages_in_blocks(from_slot, to_slot, channel_id).await
// Returns: Vec<(ZoneMessage, Slot)>
```

This performs a server-side scan over the canonical chain between two slot numbers and returns all messages published to the given channel in that range.

### Block-ID deduplication

Each `ZoneMessage` carries a `block_id` (32-byte hash). zone-board tracks which block IDs it has already shown and skips duplicates. This is essential because the backfill and the live poller can both deliver the same block.

---

## Live message delivery

Two strategies, run concurrently:

### 1. `block_stream()` — SSE

The node provides a Server-Sent Events stream that delivers each new canonical block as it arrives. This gives low latency (messages appear within milliseconds of the block being produced).

**The catch — reconnection gaps:**

```
SSE active          stream drops     reconnects
────────────────── X               ──────────────>
                    └─ gap ─────────┘
                       blocks here
                       are LOST
```

When the stream reconnects it starts from the current head. Any blocks produced during the gap are silently skipped. They will never be re-delivered by the stream.

### 2. Slot polling — reliable backstop

Every 3 seconds, zone-board calls `consensus_info()` to check whether the canonical tip has advanced, then scans the new range with `zone_messages_in_blocks`. The `last_slot` cursor only advances on a successful scan, so transient errors are retried automatically.

This catches any blocks missed during an SSE reconnection gap, at the cost of up to 3 seconds of additional latency.

Running both together gives you **low latency** (SSE) with **reliability** (polling backstop).

---

## Message lifecycle in zone-board

```
User presses Enter
  → message added to UI as "pending…"
  → tokio::spawn: wait_ready() → publish_message()
      ├─ success: status bar updated
      └─ error / timeout: message marked as ✗ failed

Node finalizes the block
  → block_stream() or polling delivers the block
  → pending/failed entry replaced with confirmed message
```
