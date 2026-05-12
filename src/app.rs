use std::{
    collections::{HashMap, HashSet, VecDeque},
    io::Stdout,
    path::PathBuf,
    time::Duration,
};

use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyModifiers};
use futures::StreamExt as _;
use lb_core::mantle::ops::channel::ChannelId;
use lb_zone_sdk::{
    Slot, ZoneBlock, ZoneMessage,
    adapter::{Node, NodeHttpClient},
    sequencer::{SequencerCheckpoint, SequencerHandle},
};
use ratatui::{Terminal, backend::CrosstermBackend};
use tokio::sync::mpsc;

use serde::{Deserialize, Serialize};

use crate::{config, storage::StorageClient};

/// Extract the reply-to block_id from a message payload, if present.
fn parse_reply_to(text: &str) -> Option<[u8; 32]> {
    let v: serde_json::Value = serde_json::from_str(text).ok()?;
    let rt = v["rt"].as_str()?;
    let bytes = hex::decode(rt).ok()?;
    bytes.try_into().ok()
}

fn expand_tilde(path: &str) -> String {
    if let Some(rest) = path.strip_prefix("~/") {
        if let Some(home) = std::env::var_os("HOME") {
            return format!("{}/{rest}", home.to_string_lossy());
        }
    } else if path == "~" {
        if let Some(home) = std::env::var_os("HOME") {
            return home.to_string_lossy().into_owned();
        }
    }
    path.to_string()
}

const MAX_MESSAGES_PER_CHANNEL: usize = 200;
/// How long to wait for the sequencer to respond before giving up.
/// ZK proof generation (rapidsnark) can take 10–60 s on slower hardware.
const PUBLISH_TIMEOUT: Duration = Duration::from_secs(120);

pub struct ChannelEntry {
    pub id: ChannelId,
    /// Short display label (≤ 20 chars).
    pub label: String,
    pub is_own: bool,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Focus {
    Channels,
    Messages,
    Thread,
}

/// Signals emitted by an indexer's historical backfill task.
pub enum SyncUpdate {
    Start(ChannelId),
    Progress {
        channel_id: ChannelId,
        current: u64,
        target: u64,
    },
    Done(ChannelId),
}

#[derive(Clone, Serialize, Deserialize)]
pub struct DisplayMessage {
    pub text: String,
    pub timestamp: String,
    /// True while the inscription is pending finalization on-chain.
    /// Never written to the cache (always false when loaded).
    #[serde(default)]
    pub pending: bool,
    /// True if the publish attempt failed (timeout or sequencer error).
    /// The message will not be confirmed and should be shown as failed.
    #[serde(default)]
    pub failed: bool,
    /// On-chain block ID once confirmed; used to deduplicate backfill vs live stream.
    #[serde(with = "block_id_serde")]
    pub block_id: Option<[u8; 32]>,
}

mod block_id_serde {
    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    pub fn serialize<S: Serializer>(v: &Option<[u8; 32]>, s: S) -> Result<S::Ok, S::Error> {
        v.as_ref().map(hex::encode).serialize(s)
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<[u8; 32]>, D::Error> {
        let opt: Option<String> = Option::deserialize(d)?;
        match opt {
            None => Ok(None),
            Some(h) => {
                let bytes = hex::decode(&h).map_err(serde::de::Error::custom)?;
                let arr: [u8; 32] = bytes.try_into().map_err(|_| {
                    serde::de::Error::custom("block_id must be 32 bytes")
                })?;
                Ok(Some(arr))
            }
        }
    }
}

/// Handles for a running indexer: the outer backfill task plus a cancel signal
/// for the inner live-stream sub-task (which is spawned independently and is
/// NOT automatically stopped when the outer `JoinHandle` is aborted).
struct IndexerHandles {
    /// The outer task running the historical backfill + progress signals.
    outer: tokio::task::JoinHandle<()>,
    /// Sending `true` stops the live-stream sub-task gracefully.
    /// Dropping the sender also terminates the receiver, stopping the stream.
    live_cancel: tokio::sync::watch::Sender<bool>,
}

/// A message that was published locally and is awaiting on-chain confirmation.
struct PendingMessage {
    channel_id: ChannelId,
    text: String,
    timestamp: String,
}

pub struct App {
    pub my_channel_id: ChannelId,
    handle: SequencerHandle<NodeHttpClient>,
    node: NodeHttpClient,
    data_dir: PathBuf,

    pub channels: Vec<ChannelEntry>,
    pub selected: usize,
    pub messages: HashMap<ChannelId, VecDeque<DisplayMessage>>,
    /// How many messages were present the last time each channel was selected.
    /// unread = messages[ch].len() - seen_count[ch]
    pub seen_count: HashMap<ChannelId, usize>,
    pub input: String,
    pub status: String,

    msg_tx: mpsc::Sender<(ChannelId, ZoneBlock)>,
    msg_rx: mpsc::Receiver<(ChannelId, ZoneBlock)>,
    status_rx: mpsc::Receiver<String>,
    status_tx: mpsc::Sender<String>,
    /// Sends the text of a message whose publish attempt failed, so the UI
    /// can mark the matching pending entry as failed instead of pending forever.
    publish_fail_tx: mpsc::Sender<String>,
    publish_fail_rx: mpsc::Receiver<String>,
    /// Lets background tasks (upload) inject a pending message into the feed.
    pending_add_tx: mpsc::Sender<PendingMessage>,
    pending_add_rx: mpsc::Receiver<PendingMessage>,
    checkpoint_rx: mpsc::Receiver<SequencerCheckpoint>,
    checkpoint_tx: mpsc::Sender<SequencerCheckpoint>,
    /// Signals from indexers: backfill lifecycle + per-channel progress.
    /// Unbounded so backfill tasks never block waiting for the UI to drain.
    sync_tx: mpsc::UnboundedSender<SyncUpdate>,
    sync_rx: mpsc::UnboundedReceiver<SyncUpdate>,
    /// Signals from indexers: true = block stream connected, false = disconnected.
    conn_tx: mpsc::Sender<bool>,
    conn_rx: mpsc::Receiver<bool>,

    storage: Option<StorageClient>,

    indexer_handles: HashMap<ChannelId, IndexerHandles>,
    pub should_quit: bool,
    /// Channels currently running the historical backfill.
    pub syncing: HashSet<ChannelId>,
    /// Per-channel backfill progress: (current_slot, target_slot).
    /// Present only while a backfill is running *and* has emitted at least one update.
    pub sync_progress: HashMap<ChannelId, (u64, u64)>,
    /// Whether at least one block stream is currently live.
    pub node_connected: bool,

    /// Which UI panel has keyboard focus.
    pub focus: Focus,
    /// Index of the selected message counting from the bottom (0 = most recent).
    /// Only meaningful when focus == Messages or Thread.
    pub msg_selected: usize,
    /// Block ID of the message whose thread is currently open.
    pub thread_view: Option<[u8; 32]>,
    /// Thread replies indexed by parent block_id.
    pub thread_replies: HashMap<[u8; 32], VecDeque<DisplayMessage>>,
}

impl App {
    pub fn new(
        my_channel_id: ChannelId,
        handle: SequencerHandle<NodeHttpClient>,
        node: NodeHttpClient,
        data_dir: PathBuf,
        storage: Option<StorageClient>,
    ) -> Self {
        let (msg_tx, msg_rx) = mpsc::channel(1024);
        let (status_tx, status_rx) = mpsc::channel(64);
        let (publish_fail_tx, publish_fail_rx) = mpsc::channel(64);
        let (pending_add_tx, pending_add_rx) = mpsc::channel(64);
        let (checkpoint_tx, checkpoint_rx) = mpsc::channel(64);
        let (sync_tx, sync_rx) = mpsc::unbounded_channel();
        let (conn_tx, conn_rx) = mpsc::channel(64);

        let own_label = format!("[you] {}", config::channel_id_label(my_channel_id));

        App {
            my_channel_id,
            handle,
            node,
            data_dir,
            channels: vec![ChannelEntry {
                id: my_channel_id,
                label: own_label,
                is_own: true,
            }],
            selected: 0,
            messages: HashMap::new(),
            seen_count: HashMap::new(),
            input: String::new(),
            status: String::new(),
            msg_tx,
            msg_rx,
            status_tx,
            status_rx,
            publish_fail_tx,
            publish_fail_rx,
            pending_add_tx,
            pending_add_rx,
            checkpoint_tx,
            checkpoint_rx,
            sync_tx,
            sync_rx,
            conn_tx,
            conn_rx,
            storage,

            indexer_handles: HashMap::new(),
            should_quit: false,
            syncing: HashSet::new(),
            sync_progress: HashMap::new(),
            node_connected: false,

            focus: Focus::Channels,
            msg_selected: 0,
            thread_view: None,
            thread_replies: HashMap::new(),
        }
    }

    /// Subscribe to a channel: backfill historical messages, then follow live.
    pub fn spawn_indexer_for(&mut self, channel_id: ChannelId) {
        if self.indexer_handles.contains_key(&channel_id) {
            return;
        }
        let node = self.node.clone();
        let msg_tx = self.msg_tx.clone();
        let sync_tx = self.sync_tx.clone();
        let conn_tx = self.conn_tx.clone();
        let data_dir = self.data_dir.clone();
        let resume_slot = Slot::from(config::load_index_slot(&data_dir, channel_id));

        // Cancellation signal for the live-stream sub-task.
        // Sending `true` (or simply dropping the sender) stops the inner task.
        let (live_cancel, cancel_rx) = tokio::sync::watch::channel(false);

        let handle = tokio::spawn(async move {
            // The /blocks API (used by zone_messages_in_blocks) only returns
            // *immutable* (past-LIB) blocks — scanning to the tip slot has no
            // extra benefit. Use lib_slot as the authoritative endpoint, matching
            // the SDK's own ZoneIndexer::next_messages() implementation.
            const BATCH: u64 = 100;

            let _ = sync_tx.send(SyncUpdate::Start(channel_id));

            // Use consensus tip (not lib_slot) as the backfill target.
            // On this testnet lib_slot may be stuck near genesis while the canonical
            // chain has thousands of slots — scanning genesis→lib_slot would return
            // nothing. zone_messages_in_blocks (ScanImmutableBlockIds server-side)
            // scans the canonical chain and works fine with the tip as the upper bound.
            let tip_at_start = match node.consensus_info().await {
                Ok(info) => {
                    let _ = conn_tx.send(true).await;
                    info.slot
                }
                Err(e) => {
                    tracing::warn!(
                        "consensus_info failed for {}: {e}",
                        hex::encode(channel_id.as_ref())
                    );
                    let _ = conn_tx.send(false).await;
                    Slot::genesis()
                }
            };

            async fn fetch_range(
                node: &NodeHttpClient,
                msg_tx: &mpsc::Sender<(ChannelId, ZoneBlock)>,
                sync_tx: &mpsc::UnboundedSender<SyncUpdate>,
                channel_id: ChannelId,
                from: Slot,
                to: Slot,
                batch: u64,
                data_dir: &std::path::Path,
            ) -> bool {
                let mut cur = from;
                while cur <= to {
                    let end = Slot::from(
                        cur.into_inner()
                            .saturating_add(batch - 1)
                            .min(to.into_inner()),
                    );
                    match node.zone_messages_in_blocks(cur, end, channel_id).await {
                        Ok(stream) => {
                            futures::pin_mut!(stream);
                            while let Some((msg, _slot)) = stream.next().await {
                                if let ZoneMessage::Block(block) = msg {
                                    if msg_tx.send((channel_id, block)).await.is_err() {
                                        return false; // receiver dropped — app shutting down
                                    }
                                }
                            }
                            // Advance only on success so a failed batch is retried.
                            cur = Slot::from(end.into_inner().saturating_add(1));
                            // Persist progress so resync can resume from here.
                            config::save_index_slot(data_dir, channel_id, cur.into_inner());
                        }
                        Err(e) => {
                            tracing::warn!(
                                "zone_messages_in_blocks [{}-{}] failed for {}: {e}, retrying…",
                                cur.into_inner(),
                                end.into_inner(),
                                hex::encode(channel_id.as_ref())
                            );
                            tokio::time::sleep(Duration::from_secs(2)).await;
                            // cur is NOT advanced — the same batch will be retried
                        }
                    }
                    let _ = sync_tx.send(SyncUpdate::Progress {
                        channel_id,
                        current: cur.into_inner().min(to.into_inner()),
                        target: to.into_inner(),
                    });
                }
                true
            }

            // Main backfill: resume slot → canonical tip at startup.
            if !fetch_range(&node, &msg_tx, &sync_tx, channel_id, resume_slot, tip_at_start, BATCH, &data_dir).await {
                return;
            }

            // Convergent gap-fill: keep scanning forward until the tip stabilises.
            // Catches blocks added to the canonical chain while the main backfill ran.
            let mut prev_tip = tip_at_start;
            loop {
                let new_tip = match node.consensus_info().await {
                    Ok(info) => info.slot,
                    Err(_) => break,
                };
                if new_tip <= prev_tip {
                    break; // caught up
                }
                let from = Slot::from(prev_tip.into_inner().saturating_add(1));
                if !fetch_range(&node, &msg_tx, &sync_tx, channel_id, from, new_tip, BATCH, &data_dir).await {
                    return;
                }
                prev_tip = new_tip;
            }

            let _ = sync_tx.send(SyncUpdate::Done(channel_id));

            // ── Live delivery ────────────────────────────────────────────────────
            //
            // Two concurrent sub-tasks, both sharing the cancel_rx watch channel:
            //
            // 1. block_stream() sub-task — delivers canonical (tip-level) blocks the
            //    moment they arrive, before they are finalized. This is the fast path
            //    and is what makes pending messages confirm quickly. It reconnects
            //    automatically on disconnect, but reconnection introduces a gap.
            //
            // 2. lib-slot polling sub-task — every 3 s, checks consensus_info().
            //    lib_slot and scans any newly-immutable slot range via
            //    zone_messages_in_blocks. This is the reliable backstop: it catches
            //    anything missed by the stream during a reconnect window, and never
            //    loses messages because last_lib only advances on success.
            //
            // Duplicates (same block delivered by both) are dropped by the block_id
            // dedup in drain_background_channels.

            // ── Sub-task 1: block_stream (canonical / low-latency) ───────────────
            {
                use lb_core::mantle::ops::Op;
                let stream_msg_tx = msg_tx.clone();
                let stream_node = node.clone();
                let stream_conn_tx = conn_tx.clone();
                let mut cancel_rx_stream = cancel_rx.clone();

                tokio::spawn(async move {
                    loop {
                        if *cancel_rx_stream.borrow() {
                            return;
                        }

                        let stream_result = tokio::select! {
                            biased;
                            _ = cancel_rx_stream.changed() => return,
                            r = stream_node.block_stream() => r,
                        };

                        match stream_result {
                            Ok(stream) => {
                                let _ = stream_conn_tx.send(true).await;
                                let mut stream = Box::pin(stream);
                                loop {
                                    let event = tokio::select! {
                                        biased;
                                        _ = cancel_rx_stream.changed() => return,
                                        ev = stream.next() => ev,
                                    };
                                    match event {
                                        Some(event) => {
                                            for tx in &event.block.transactions {
                                                for op in &tx.mantle_tx.ops {
                                                    if let Op::ChannelInscribe(inscribe) = op {
                                                        if inscribe.channel_id == channel_id {
                                                            let block = ZoneBlock {
                                                                id: inscribe.id(),
                                                                data: inscribe.inscription.clone(),
                                                            };
                                                            if stream_msg_tx
                                                                .send((channel_id, block))
                                                                .await
                                                                .is_err()
                                                            {
                                                                return;
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                        None => {
                                            tracing::warn!(
                                                "block stream ended for {}, reconnecting…",
                                                hex::encode(channel_id.as_ref())
                                            );
                                            break;
                                        }
                                    }
                                }
                            }
                            Err(e) => {
                                tracing::warn!(
                                    "block_stream connect failed for {}: {e}",
                                    hex::encode(channel_id.as_ref())
                                );
                            }
                        }

                        let _ = stream_conn_tx.send(false).await;
                        tokio::select! {
                            biased;
                            _ = cancel_rx_stream.changed() => return,
                            _ = tokio::time::sleep(Duration::from_secs(5)) => {}
                        }
                    }
                });
            }

            // ── Sub-task 2: lib-slot polling (finalized / reliable) ──────────────
            {
                let poll_msg_tx = msg_tx;
                let poll_node = node;
                let poll_conn_tx = conn_tx;
                let mut cancel_rx_poll = cancel_rx.clone();

                tokio::spawn(async move {
                    let mut last_lib = prev_tip;
                    loop {
                        // Sleep before each poll so we don't re-scan what we just fetched.
                        tokio::select! {
                            biased;
                            _ = cancel_rx_poll.changed() => return,
                            _ = tokio::time::sleep(Duration::from_secs(3)) => {}
                        }

                        if *cancel_rx_poll.borrow() {
                            return;
                        }

                        match poll_node.consensus_info().await {
                            Ok(info) => {
                                let _ = poll_conn_tx.send(true).await;
                                if info.slot > last_lib {
                                    let from = Slot::from(last_lib.into_inner().saturating_add(1));
                                    match poll_node
                                        .zone_messages_in_blocks(from, info.slot, channel_id)
                                        .await
                                    {
                                        Ok(stream) => {
                                            futures::pin_mut!(stream);
                                            while let Some((msg, _slot)) = stream.next().await {
                                                if let ZoneMessage::Block(block) = msg {
                                                    if poll_msg_tx
                                                        .send((channel_id, block))
                                                        .await
                                                        .is_err()
                                                    {
                                                        return;
                                                    }
                                                }
                                            }
                                            last_lib = info.slot;
                                        }
                                        Err(e) => {
                                            tracing::warn!(
                                                "tip poll zone_messages_in_blocks [{}-{}] failed for {}: {e}",
                                                from.into_inner(),
                                                info.slot.into_inner(),
                                                hex::encode(channel_id.as_ref())
                                            );
                                            // last_lib NOT advanced — retried next cycle
                                        }
                                    }
                                }
                            }
                            Err(e) => {
                                tracing::warn!(
                                    "lib poll consensus_info failed for {}: {e}",
                                    hex::encode(channel_id.as_ref())
                                );
                                let _ = poll_conn_tx.send(false).await;
                            }
                        }
                    }
                });
            }

            drop(cancel_rx); // release outer reference; both sub-tasks hold their own clones
        });

        self.indexer_handles.insert(channel_id, IndexerHandles {
            outer: handle,
            live_cancel,
        });
    }

    /// Add a channel to the subscription list and start polling it.
    pub fn subscribe(&mut self, channel_id: ChannelId) {
        if self.channels.iter().any(|c| c.id == channel_id) {
            self.status = "already subscribed".to_string();
            return;
        }
        let label = config::channel_id_label(channel_id);
        self.channels.push(ChannelEntry {
            id: channel_id,
            label,
            is_own: false,
        });
        self.load_cache_for(channel_id);
        self.spawn_indexer_for(channel_id);
        self.save_subscriptions();
        self.status = format!("subscribed to {}…", &hex::encode(channel_id.as_ref())[..12]);
    }

    /// Re-sync the currently selected channel from scratch.
    pub fn resync_selected(&mut self) {
        let id = self.channels[self.selected].id;
        // Stop both the outer backfill task and the inner live-stream sub-task.
        if let Some(handles) = self.indexer_handles.remove(&id) {
            let _ = handles.live_cancel.send(true); // signal inner task to stop
            handles.outer.abort();                  // kill outer backfill task
        }
        // Clear messages and seen state so the channel starts fresh
        self.messages.remove(&id);
        self.seen_count.remove(&id);
        self.syncing.remove(&id);
        self.sync_progress.remove(&id);
        // Remove the on-disk cache and saved slot so the full backfill runs again
        let cache = self.cache_path(id);
        let _ = std::fs::remove_file(&cache);
        config::clear_index_slot(&self.data_dir, id);
        // Restart the indexer
        self.spawn_indexer_for(id);
        self.status = format!("resyncing {}…", self.channels[self.selected].label);
    }

    /// Remove the currently selected (non-own) channel.
    pub fn unsubscribe_selected(&mut self) {
        let idx = self.selected;
        if self.channels[idx].is_own {
            self.status = "cannot unsubscribe your own channel".to_string();
            return;
        }
        let entry = self.channels.remove(idx);
        if let Some(handles) = self.indexer_handles.remove(&entry.id) {
            let _ = handles.live_cancel.send(true);
            handles.outer.abort();
        }
        self.messages.remove(&entry.id);
        if self.selected >= self.channels.len() {
            self.selected = self.channels.len().saturating_sub(1);
        }
        self.save_subscriptions();
        self.status = format!("unsubscribed from {}", entry.label);
    }

    fn cache_path(&self, channel_id: ChannelId) -> std::path::PathBuf {
        let dir = self.data_dir.join("cache");
        std::fs::create_dir_all(&dir).ok();
        dir.join(format!("{}.json", hex::encode(channel_id.as_ref())))
    }

    /// Load cached messages for a channel from disk into the in-memory store.
    pub fn load_cache_for(&mut self, channel_id: ChannelId) {
        let path = self.cache_path(channel_id);
        if !path.exists() {
            return;
        }
        let Ok(data) = std::fs::read(&path) else { return };
        let Ok(msgs): Result<VecDeque<DisplayMessage>, _> = serde_json::from_slice(&data) else {
            return;
        };
        let count = msgs.len();
        self.messages.insert(channel_id, msgs);
        // Pre-seed seen_count so cached messages never show as unread
        self.seen_count.insert(channel_id, count);
    }

    /// Save all confirmed messages for every channel to disk.
    fn save_cache(&self) {
        for ch in &self.channels {
            let Some(msgs) = self.messages.get(&ch.id) else { continue };
            let confirmed: VecDeque<&DisplayMessage> =
                msgs.iter().filter(|m| !m.pending && m.block_id.is_some()).collect();
            if confirmed.is_empty() {
                continue;
            }
            let path = self.cache_path(ch.id);
            if let Ok(data) = serde_json::to_vec(&confirmed) {
                std::fs::write(&path, data).ok();
            }
        }
    }

    fn save_subscriptions(&self) {
        let ids: Vec<String> = self
            .channels
            .iter()
            .filter(|c| !c.is_own)
            .map(|c| hex::encode(c.id.as_ref()))
            .collect();
        config::save_subscriptions(&self.data_dir.join("subscriptions.json"), &ids);
    }

    /// Add a message to the channel's feed immediately (optimistic / pending).
    fn add_pending_message(&mut self, pending: PendingMessage) {
        let msg = DisplayMessage {
            text: pending.text,
            timestamp: pending.timestamp,
            pending: true,
            failed: false,
            block_id: None,
        };
        let bucket = self.messages.entry(pending.channel_id).or_default();
        bucket.push_back(msg);
        while bucket.len() > MAX_MESSAGES_PER_CHANNEL {
            bucket.pop_front();
        }
    }

    async fn publish_input(&mut self, text: String) {
        let timestamp = chrono::Local::now().format("%H:%M:%S").to_string();

        // Show the message immediately in the feed as pending
        self.add_pending_message(PendingMessage {
            channel_id: self.my_channel_id,
            text: text.clone(),
            timestamp,
        });

        let mut handle = self.handle.clone();
        let status_tx = self.status_tx.clone();
        let fail_tx = self.publish_fail_tx.clone();
        let checkpoint_tx = self.checkpoint_tx.clone();

        tokio::spawn(async move {
            // Wrap both wait_ready AND publish_message in the same timeout so a
            // stuck sequencer (e.g. stale checkpoint retry loop) doesn't hang forever.
            let result = tokio::time::timeout(PUBLISH_TIMEOUT, async {
                handle.wait_ready().await;
                handle.publish_message(text.as_bytes().to_vec()).await
            })
            .await;

            match result {
                Ok(Ok(r)) => {
                    let hash: [u8; 32] = r.inscription_id.into();
                    let _ = status_tx
                        .send(format!(
                            "published: {} (pending finalization)",
                            &hex::encode(hash)[..16]
                        ))
                        .await;
                    let _ = checkpoint_tx.send(r.checkpoint).await;
                    // Success: the indexer will confirm the pending entry when the
                    // block arrives via block_stream or the polling loop.
                }
                Ok(Err(e)) => {
                    tracing::warn!("publish error: {e}");
                    let _ = status_tx
                        .send(format!("publish error: {e} — check zone-board.log"))
                        .await;
                    let _ = fail_tx.send(text).await;
                }
                Err(_) => {
                    tracing::warn!("publish timed out after {PUBLISH_TIMEOUT:?}");
                    let _ = status_tx
                        .send(format!(
                            "publish timed out after {}s — delete sequencer.checkpoint and restart",
                            PUBLISH_TIMEOUT.as_secs()
                        ))
                        .await;
                    let _ = fail_tx.send(text).await;
                }
            }
        });

        self.status = "waiting for sequencer…".to_string();
    }

    async fn upload_and_publish(&mut self, path: String, caption: String) {
        let Some(client) = self.storage.clone() else {
            self.status = "no storage URL configured — pass --storage-url".to_string();
            return;
        };

        self.status = format!("uploading {}…", path);
        let status_tx = self.status_tx.clone();
        let pending_tx = self.pending_add_tx.clone();
        let mut handle = self.handle.clone();
        let fail_tx = self.publish_fail_tx.clone();
        let checkpoint_tx = self.checkpoint_tx.clone();
        let my_channel_id = self.my_channel_id;

        tokio::spawn(async move {
            let upload = client.upload_file(&path).await;
            match upload {
                Err(e) => {
                    let _ = status_tx.send(format!("upload failed: {e}")).await;
                }
                Ok(r) => {
                    let payload = serde_json::json!({
                        "text": caption,
                        "media": [{
                            "cid":  r.cid,
                            "type": r.mime,
                            "name": r.filename,
                            "size": r.size,
                        }]
                    })
                    .to_string();

                    // Show as pending immediately so it appears in the feed
                    let _ = pending_tx.send(PendingMessage {
                        channel_id: my_channel_id,
                        text: payload.clone(),
                        timestamp: chrono::Local::now().format("%H:%M:%S").to_string(),
                    }).await;

                    let _ = status_tx
                        .send(format!("uploaded {} → {} — publishing…", r.filename, &r.cid[..12]))
                        .await;

                    let result = tokio::time::timeout(PUBLISH_TIMEOUT, async {
                        handle.wait_ready().await;
                        handle.publish_message(payload.as_bytes().to_vec()).await
                    })
                    .await;

                    match result {
                        Ok(Ok(res)) => {
                            let hash: [u8; 32] = res.inscription_id.into();
                            let _ = status_tx
                                .send(format!("published: {} (pending)", &hex::encode(hash)[..16]))
                                .await;
                            let _ = checkpoint_tx.send(res.checkpoint).await;
                        }
                        Ok(Err(e)) => {
                            let _ = status_tx.send(format!("publish error: {e}")).await;
                            let _ = fail_tx.send(payload).await;
                        }
                        Err(_) => {
                            let _ = status_tx
                                .send(format!("publish timed out after {}s", PUBLISH_TIMEOUT.as_secs()))
                                .await;
                            let _ = fail_tx.send(payload).await;
                        }
                    }
                }
            }
        });
    }

    async fn handle_key(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                self.should_quit = true;
            }
            KeyCode::Tab => {
                self.focus = match self.focus {
                    Focus::Channels => Focus::Messages,
                    Focus::Messages => {
                        if self.thread_view.is_some() { Focus::Thread } else { Focus::Channels }
                    }
                    Focus::Thread => Focus::Channels,
                };
            }
            KeyCode::Esc => {
                match self.focus {
                    Focus::Thread => {
                        self.thread_view = None;
                        self.focus = Focus::Messages;
                    }
                    Focus::Messages => {
                        self.focus = Focus::Channels;
                    }
                    Focus::Channels => {}
                }
            }
            KeyCode::Up => {
                match self.focus {
                    Focus::Channels => {
                        self.selected = self.selected.saturating_sub(1);
                        self.msg_selected = 0;
                    }
                    Focus::Messages => {
                        // Scroll toward older messages (higher index from bottom)
                        let channel_id = self.channels[self.selected].id;
                        let len = self.messages.get(&channel_id).map(|m| m.len()).unwrap_or(0);
                        if len > 0 && self.msg_selected + 1 < len {
                            self.msg_selected += 1;
                        }
                    }
                    Focus::Thread => {}
                }
            }
            KeyCode::Down => {
                match self.focus {
                    Focus::Channels => {
                        if self.selected + 1 < self.channels.len() {
                            self.selected += 1;
                            self.msg_selected = 0;
                        }
                    }
                    Focus::Messages => {
                        // Scroll toward newer messages
                        self.msg_selected = self.msg_selected.saturating_sub(1);
                    }
                    Focus::Thread => {}
                }
            }
            KeyCode::Enter => {
                let input = self.input.trim().to_string();
                self.input.clear();

                if input.is_empty() {
                    // In Messages focus with no input: open thread for selected message
                    if self.focus == Focus::Messages {
                        self.open_selected_thread();
                    }
                    return;
                }

                if let Some(rest) = input.strip_prefix("/sub ") {
                    let arg = rest.trim();
                    // Accept either a 64-char hex ID or a human-readable name
                    let channel_id = if arg.len() == 64 {
                        match hex::decode(arg) {
                            Ok(bytes) => match <[u8; 32]>::try_from(bytes) {
                                Ok(arr) => Some(ChannelId::from(arr)),
                                Err(_) => None,
                            },
                            Err(_) => None,
                        }
                    } else {
                        None
                    }
                    .unwrap_or_else(|| {
                        // Treat as a name: apply logos:yolo: prefix and zero-pad
                        let full = format!("{}{arg}", config::CHANNEL_PREFIX);
                        let name_bytes = full.as_bytes();
                        let mut arr = [0u8; 32];
                        let len = name_bytes.len().min(32);
                        arr[..len].copy_from_slice(&name_bytes[..len]);
                        ChannelId::from(arr)
                    });
                    self.subscribe(channel_id);
                } else if let Some(rest) = input.strip_prefix("/upload ") {
                    // /upload <path>  — path is the entire remainder (spaces ok, ~ expanded)
                    let path = expand_tilde(rest.trim());
                    self.upload_and_publish(path, String::new()).await;
                } else if input == "/unsub" {
                    self.unsubscribe_selected();
                } else if input == "/resync" {
                    self.resync_selected();
                } else if input == "/quit" || input == "/q" {
                    self.should_quit = true;
                } else if input.starts_with('/') {
                    self.status = format!("unknown command: {input}");
                } else if self.focus == Focus::Thread {
                    // Publish as a reply to the open thread
                    if let Some(parent_id) = self.thread_view {
                        self.publish_reply(parent_id, input).await;
                    }
                } else {
                    self.publish_input(input).await;
                }
            }
            KeyCode::Char(c) => {
                self.input.push(c);
            }
            KeyCode::Backspace => {
                self.input.pop();
            }
            _ => {}
        }
    }

    /// Overall sync progress across all channels: (min_pct, n_syncing).
    /// Uses the slowest channel so the indicator doesn't vanish until everyone is done.
    pub fn global_sync_progress(&self) -> Option<u64> {
        if self.syncing.is_empty() {
            return None;
        }
        let min_pct = self
            .syncing
            .iter()
            .map(|id| {
                self.sync_progress
                    .get(id)
                    .filter(|&&(_, tgt)| tgt > 0)
                    .map(|&(cur, tgt)| (cur.saturating_mul(100) / tgt).min(100))
                    .unwrap_or(0)
            })
            .min()
            .unwrap_or(0);
        Some(min_pct)
    }

    pub fn unread_count(&self, channel_id: ChannelId) -> usize {
        let total = self.messages.get(&channel_id).map(|m| m.len()).unwrap_or(0);
        let seen = self.seen_count.get(&channel_id).copied().unwrap_or(0);
        total.saturating_sub(seen)
    }

    /// Number of confirmed thread replies for a given parent block_id.
    pub fn reply_count(&self, block_id: [u8; 32]) -> usize {
        self.thread_replies.get(&block_id).map(|v| v.len()).unwrap_or(0)
    }

    /// Open the thread for the currently selected message (Messages focus).
    fn open_selected_thread(&mut self) {
        let channel_id = self.channels[self.selected].id;
        let msgs = match self.messages.get(&channel_id) {
            Some(m) if !m.is_empty() => m,
            _ => return,
        };
        let idx = msgs.len().saturating_sub(1 + self.msg_selected);
        if let Some(block_id) = msgs[idx].block_id {
            self.thread_view = Some(block_id);
            self.focus = Focus::Thread;
        } else {
            self.status = "cannot thread a pending/failed message".to_string();
        }
    }

    async fn publish_reply(&mut self, parent_id: [u8; 32], text: String) {
        let timestamp = chrono::Local::now().format("%H:%M:%S").to_string();
        let payload = serde_json::json!({
            "v": 1,
            "text": text,
            "rt": hex::encode(parent_id),
        }).to_string();

        // Optimistic pending entry in thread panel
        let bucket = self.thread_replies.entry(parent_id).or_default();
        bucket.push_back(DisplayMessage {
            text: payload.clone(),
            timestamp,
            pending: true,
            failed: false,
            block_id: None,
        });

        let mut handle = self.handle.clone();
        let status_tx = self.status_tx.clone();
        let checkpoint_tx = self.checkpoint_tx.clone();

        tokio::spawn(async move {
            let result = tokio::time::timeout(PUBLISH_TIMEOUT, async {
                handle.wait_ready().await;
                handle.publish_message(payload.as_bytes().to_vec()).await
            }).await;

            match result {
                Ok(Ok(r)) => {
                    let hash: [u8; 32] = r.inscription_id.into();
                    let _ = status_tx.send(format!("reply published: {}", &hex::encode(hash)[..16])).await;
                    let _ = checkpoint_tx.send(r.checkpoint).await;
                }
                Ok(Err(e)) => {
                    let _ = status_tx.send(format!("reply error: {e}")).await;
                }
                Err(_) => {
                    let _ = status_tx.send(format!("reply timed out after {}s", PUBLISH_TIMEOUT.as_secs())).await;
                }
            }
        });

        self.status = "sending reply…".to_string();
    }

    fn drain_background_channels(&mut self) {
        // Incoming finalized messages from indexers — clear matching pending entries
        while let Ok((channel_id, block)) = self.msg_rx.try_recv() {
            let block_id: [u8; 32] = block.id.into();
            let text = String::from_utf8_lossy(&block.data).into_owned();

            // Route thread replies to thread_replies, not the main feed
            if let Some(parent_id) = parse_reply_to(&text) {
                let bucket = self.thread_replies.entry(parent_id).or_default();
                if bucket.iter().any(|m| m.block_id == Some(block_id)) {
                    continue;
                }
                let confirmed = bucket.iter_mut().find(|m| (m.pending || m.failed) && m.text == text);
                if let Some(m) = confirmed {
                    m.pending = false;
                    m.failed = false;
                    m.block_id = Some(block_id);
                } else {
                    bucket.push_back(DisplayMessage {
                        text,
                        timestamp: chrono::Local::now().format("%H:%M:%S").to_string(),
                        pending: false,
                        failed: false,
                        block_id: Some(block_id),
                    });
                    while bucket.len() > MAX_MESSAGES_PER_CHANNEL {
                        bucket.pop_front();
                    }
                }
                continue;
            }

            let bucket = self.messages.entry(channel_id).or_default();

            // Skip if already present (backfill and live stream may both deliver same block).
            if bucket.iter().any(|m| m.block_id == Some(block_id)) {
                continue;
            }

            // Confirm a matching pending message in-place rather than adding a duplicate.
            let confirmed_pending = bucket
                .iter_mut()
                .find(|m| (m.pending || m.failed) && m.text == text);
            if let Some(m) = confirmed_pending {
                m.pending = false;
                m.failed = false;
                m.block_id = Some(block_id);
            } else {
                bucket.push_back(DisplayMessage {
                    text,
                    timestamp: chrono::Local::now().format("%H:%M:%S").to_string(),
                    pending: false,
                    failed: false,
                    block_id: Some(block_id),
                });
                while bucket.len() > MAX_MESSAGES_PER_CHANNEL {
                    bucket.pop_front();
                }
            }
        }

        // Pending messages injected by background tasks (e.g. upload)
        while let Ok(pending) = self.pending_add_rx.try_recv() {
            self.add_pending_message(pending);
        }

        // Failed publish notifications — mark the matching pending entry as failed.
        while let Ok(text) = self.publish_fail_rx.try_recv() {
            if let Some(bucket) = self.messages.get_mut(&self.my_channel_id) {
                if let Some(m) = bucket.iter_mut().find(|m| m.pending && m.text == text) {
                    m.pending = false;
                    m.failed = true;
                }
            }
        }

        // Status updates from async publish tasks
        while let Ok(status) = self.status_rx.try_recv() {
            self.status = status;
        }

        // Checkpoint updates
        while let Ok(checkpoint) = self.checkpoint_rx.try_recv() {
            config::save_checkpoint(
                &self.data_dir.join("sequencer.checkpoint"),
                &checkpoint,
                self.my_channel_id,
            );
        }

        // Backfill lifecycle + per-channel progress
        while let Ok(update) = self.sync_rx.try_recv() {
            match update {
                SyncUpdate::Start(id) => {
                    self.syncing.insert(id);
                }
                SyncUpdate::Progress { channel_id, current, target } => {
                    self.sync_progress.insert(channel_id, (current, target));
                }
                SyncUpdate::Done(id) => {
                    self.syncing.remove(&id);
                    self.sync_progress.remove(&id);
                    // All messages present at sync completion are historical — not "new".
                    // Only messages arriving via the live stream after this point are unread.
                    let total = self.messages.get(&id).map(|m| m.len()).unwrap_or(0);
                    self.seen_count.entry(id).or_insert(total);
                    let label = self.channels.iter()
                        .find(|c| c.id == id)
                        .map(|c| c.label.as_str())
                        .unwrap_or("channel");
                    self.status = format!("sync done: {} — {total} message(s)", label);
                }
            }
        }

        // Connection state — true if any indexer has an active block stream
        while let Ok(connected) = self.conn_rx.try_recv() {
            self.node_connected = connected;
        }

        // Mark the currently visible channel as fully read
        let selected_id = self.channels[self.selected].id;
        let total = self.messages.get(&selected_id).map(|m| m.len()).unwrap_or(0);
        self.seen_count.insert(selected_id, total);
    }

    pub async fn run(
        &mut self,
        terminal: &mut Terminal<CrosstermBackend<Stdout>>,
    ) -> Result<(), Box<dyn std::error::Error>> {
        loop {
            self.drain_background_channels();

            terminal.draw(|f| crate::ui::render(f, self))?;

            if event::poll(Duration::from_millis(50))? {
                if let Event::Key(key) = event::read()? {
                    self.handle_key(key).await;
                }
            }

            if self.should_quit {
                break;
            }
        }
        self.save_cache();
        Ok(())
    }
}
