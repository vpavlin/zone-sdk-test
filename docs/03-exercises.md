# Workshop Exercises

These exercises extend zone-board with new features. Each one is self-contained and touches a different part of the codebase.

---

## Exercise 1 — Block-height timestamps

**Goal:** Replace wall-clock timestamps with on-chain slot numbers.

**Why it matters:** Wall-clock timestamps are set by the local machine and are meaningless to other users. The slot number is canonical — it comes directly from the chain and is the same for everyone.

**Where to look:**

- `src/app.rs` — `spawn_indexer_for` — messages are received as `(ZoneMessage, Slot)` tuples
- `src/app.rs` — `DisplayMessage.timestamp` — currently set to `chrono::Local::now()`

**What to change:**

1. In the backfill and live poll paths, pass the `Slot` value through with the message.
2. In the `msg_tx` channel, include the slot number alongside the message.
3. In `drain_background_channels`, format the slot as the timestamp instead of calling `chrono::Local::now()`.

**Hint:** The `Slot` type is an integer. A simple `format!("slot {slot}")` is enough to start.

---

## Exercise 2 — Sender attribution

**Goal:** Show who sent each message.

**Why it matters:** Any channel can receive messages from multiple signers. Without attribution, you can't tell who said what.

**Where to look:**

- The `ZoneMessage` type in the SDK — it contains the `ChannelInscribe` operation
- `ChannelInscribe` has a `signer` field (the author's Ed25519 public key as bytes)
- `src/app.rs` — `DisplayMessage` struct

**What to change:**

1. Add a `sender: Option<String>` field to `DisplayMessage`.
2. When processing an incoming message, extract `signer` from the `ChannelInscribe` op and encode the first 4 bytes as hex (8 chars).
3. In `src/ui.rs`, prepend `[<hex>] ` to the message text if `sender` is set.

**Hint:** To extract the op from a `ZoneMessage`, look at what fields `ZoneMessage` exposes. The SDK source is at `../logos-blockchain/zone-sdk/src/`.

---

## Exercise 3 — Channel discovery with `/list`

**Goal:** Add a `/list` command that shows all channels that have published messages recently.

**Why it matters:** Without discovery, users have to share channel IDs out of band. Scanning recent blocks gives a live view of who's active.

**Where to look:**

- `src/app.rs` — `handle_key` — where commands are parsed
- `zone_messages_in_blocks` — pass `None` as the channel ID (if the SDK supports it) or scan a range without filtering
- `src/app.rs` — `status` field — a simple way to surface results for now

**What to change:**

1. In `handle_key`, add a `/list` branch.
2. Spawn a task that calls `consensus_info().slot`, then scans the last 500 slots with `zone_messages_in_blocks`.
3. Collect all unique `channel_id` values seen in the results.
4. Send the list back via `status_tx` as a comma-separated string of hex IDs (or decoded names if they match the `logos:yolo:` prefix).

**Extension:** Display the results in a popup overlay rather than the status bar.

---

## Exercise 4 — Message search with `/find`

**Goal:** Add `/find <keyword>` to search the local message cache.

**Why it matters:** Channels accumulate many messages. A basic keyword search makes the history navigable.

**Where to look:**

- `src/app.rs` — `handle_key`
- `src/app.rs` — `App.messages` — the in-memory message store
- `src/ui.rs` — consider adding a "search results" view or reusing the messages pane

**What to change:**

1. In `handle_key`, parse `/find <keyword>` and store the keyword in a new `App.search: Option<String>` field.
2. In `ui.rs`, when `app.search` is set, filter the displayed messages to only those whose `text` contains the keyword (case-insensitive).
3. Show the keyword in the pane title so it's clear the view is filtered.
4. Clear `search` when the user presses Escape or submits an empty input.

---

## Exercise 5 — Cursor persistence

**Goal:** Save each channel's last-seen slot to disk so the live poll resumes from where it left off after a restart.

**Why it matters:** Currently, every restart triggers a full backfill from genesis. For active channels with thousands of blocks this is slow. Persisting the cursor means only new blocks are scanned.

**Where to look:**

- `src/config.rs` — add `load_cursors` / `save_cursors` (similar to `load_subscriptions`)
- `src/app.rs` — `spawn_indexer_for` — the `last_slot` variable in the polling sub-task
- `src/app.rs` — `App::save_and_quit` (or wherever subscriptions are saved on exit)

**What to change:**

1. Add `save_cursors(path, HashMap<String, u64>)` and `load_cursors(path) -> HashMap<String, u64>` to `config.rs`.
2. In `spawn_indexer_for`, accept an optional `start_slot: Option<u64>`. If provided, skip the full backfill and start the gap-fill from `start_slot`.
3. In the polling sub-task, send `last_slot` updates back to `App` via a new `cursor_tx` channel.
4. On quit, save all cursors to `cursors.json`.
5. On startup, load cursors and pass the matching one to `spawn_indexer_for` for each channel.

**Caution:** If the saved cursor is far behind the current tip, the gap-fill will still need to scan the missing range. This is correct behaviour.

---

## Extension — Rich channel list with `/list` overlay

Once you've done exercises 3 and 4, combine them: when `/list` is active, render a floating overlay in `ui.rs` that lists discovered channels with their last-seen slot. Pressing Enter on a highlighted channel subscribes to it directly.

This requires:
- A new `App.discovery: Option<Vec<DiscoveredChannel>>` field
- A new rendering path in `ui.rs` that draws a `Block` overlay on top of the main layout
- Keyboard handling in `handle_key` that routes `↑`/`↓`/`Enter`/`Esc` to the overlay when it's active
