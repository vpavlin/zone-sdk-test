use std::{
    collections::{HashMap, HashSet, VecDeque},
    io::Stdout,
    path::PathBuf,
    time::Duration,
};

use crossterm::event::{self, Event, KeyCode, KeyEvent, KeyModifiers};
use futures::StreamExt as _;
use lb_core::mantle::ops::{Op, channel::ChannelId};
use lb_zone_sdk::{
    Slot, ZoneBlock, ZoneMessage,
    adapter::{Node, NodeHttpClient},
    sequencer::{SequencerCheckpoint, SequencerHandle},
};
use ratatui::{Terminal, backend::CrosstermBackend};
use tokio::sync::mpsc;

use crate::config;

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

pub struct DisplayMessage {
    pub text: String,
    pub timestamp: String,
    /// True while the inscription is pending finalization on-chain.
    pub pending: bool,
    /// On-chain block ID once confirmed; used to deduplicate backfill vs live stream.
    pub block_id: Option<[u8; 32]>,
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
    checkpoint_rx: mpsc::Receiver<SequencerCheckpoint>,
    checkpoint_tx: mpsc::Sender<SequencerCheckpoint>,
    /// Signals from indexers: backfill lifecycle + per-channel progress.
    sync_tx: mpsc::Sender<SyncUpdate>,
    sync_rx: mpsc::Receiver<SyncUpdate>,
    /// Signals from indexers: true = block stream connected, false = disconnected.
    conn_tx: mpsc::Sender<bool>,
    conn_rx: mpsc::Receiver<bool>,

    indexer_handles: HashMap<ChannelId, tokio::task::JoinHandle<()>>,
    pub should_quit: bool,
    /// Channels currently running the historical backfill.
    pub syncing: HashSet<ChannelId>,
    /// Per-channel backfill progress: (current_slot, target_slot).
    /// Present only while a backfill is running *and* has emitted at least one update.
    pub sync_progress: HashMap<ChannelId, (u64, u64)>,
    /// Whether at least one block stream is currently live.
    pub node_connected: bool,
}

impl App {
    pub fn new(
        my_channel_id: ChannelId,
        handle: SequencerHandle<NodeHttpClient>,
        node: NodeHttpClient,
        data_dir: PathBuf,
    ) -> Self {
        let (msg_tx, msg_rx) = mpsc::channel(1024);
        let (status_tx, status_rx) = mpsc::channel(64);
        let (checkpoint_tx, checkpoint_rx) = mpsc::channel(64);
        let (sync_tx, sync_rx) = mpsc::channel(64);
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
            checkpoint_tx,
            checkpoint_rx,
            sync_tx,
            sync_rx,
            conn_tx,
            conn_rx,
            indexer_handles: HashMap::new(),
            should_quit: false,
            syncing: HashSet::new(),
            sync_progress: HashMap::new(),
            node_connected: false,
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

        let handle = tokio::spawn(async move {
            // Start block_stream immediately so no live blocks are missed while
            // the historical backfill is running.
            let live_msg_tx = msg_tx.clone();
            let live_node = node.clone();
            let live_conn_tx = conn_tx.clone();
            tokio::spawn(async move {
                loop {
                    match live_node.block_stream().await {
                        Ok(stream) => {
                            let _ = live_conn_tx.send(true).await;
                            let mut stream = Box::pin(stream);
                            while let Some(event) = stream.next().await {
                                for tx in &event.block.transactions {
                                    for op in &tx.mantle_tx.ops {
                                        if let Op::ChannelInscribe(inscribe) = op {
                                            if inscribe.channel_id == channel_id {
                                                let block = ZoneBlock {
                                                    id: inscribe.id(),
                                                    data: inscribe.inscription.clone(),
                                                };
                                                if live_msg_tx
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
                            tracing::warn!(
                                "block stream ended for {}, reconnecting…",
                                hex::encode(channel_id.as_ref())
                            );
                        }
                        Err(e) => {
                            tracing::warn!(
                                "block_stream failed for {}: {e}",
                                hex::encode(channel_id.as_ref())
                            );
                        }
                    }
                    let _ = live_conn_tx.send(false).await;
                    tokio::time::sleep(Duration::from_secs(5)).await;
                }
            });

            // Historical backfill — runs concurrently with the live stream above.
            // Matches the SDK's built-in ZoneIndexer batch size. Larger batches
            // risk timing out the node's get_blocks call under load.
            const BATCH: u64 = 100;

            let _ = sync_tx.send(SyncUpdate::Start(channel_id)).await;

            // Scan up to the current tip (not just lib) so unfinalized-but-stored
            // blocks are included. A gap-fill pass afterwards catches anything that
            // arrived while the main backfill was running.
            let tip = match node.consensus_info().await {
                Ok(info) => info.slot,
                Err(e) => {
                    tracing::warn!(
                        "consensus_info failed for {}: {e}",
                        hex::encode(channel_id.as_ref())
                    );
                    Slot::genesis()
                }
            };

            async fn fetch_range(
                node: &NodeHttpClient,
                msg_tx: &mpsc::Sender<(ChannelId, ZoneBlock)>,
                sync_tx: &mpsc::Sender<SyncUpdate>,
                channel_id: ChannelId,
                from: Slot,
                to: Slot,
                batch: u64,
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
                                        return false;
                                    }
                                }
                            }
                        }
                        Err(e) => {
                            tracing::warn!(
                                "zone_messages_in_blocks failed for {}: {e}",
                                hex::encode(channel_id.as_ref())
                            );
                            break;
                        }
                    }
                    cur = Slot::from(end.into_inner().saturating_add(1));
                    let _ = sync_tx
                        .send(SyncUpdate::Progress {
                            channel_id,
                            current: cur.into_inner().min(to.into_inner()),
                            target: to.into_inner(),
                        })
                        .await;
                }
                true
            }

            if !fetch_range(&node, &msg_tx, &sync_tx, channel_id, Slot::genesis(), tip, BATCH).await {
                return;
            }

            // Gap-fill: catch blocks that arrived while the main backfill was running.
            if let Ok(info) = node.consensus_info().await {
                if info.slot > tip {
                    fetch_range(
                        &node,
                        &msg_tx,
                        &sync_tx,
                        channel_id,
                        Slot::from(tip.into_inner().saturating_add(1)),
                        info.slot,
                        BATCH,
                    )
                    .await;
                }
            }

            let _ = sync_tx.send(SyncUpdate::Done(channel_id)).await;
            // The live block_stream sub-task continues running indefinitely.
        });

        self.indexer_handles.insert(channel_id, handle);
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
        self.spawn_indexer_for(channel_id);
        self.save_subscriptions();
        self.status = format!("subscribed to {}…", &hex::encode(channel_id.as_ref())[..12]);
    }

    /// Remove the currently selected (non-own) channel.
    pub fn unsubscribe_selected(&mut self) {
        let idx = self.selected;
        if self.channels[idx].is_own {
            self.status = "cannot unsubscribe your own channel".to_string();
            return;
        }
        let entry = self.channels.remove(idx);
        if let Some(handle) = self.indexer_handles.remove(&entry.id) {
            handle.abort();
        }
        self.messages.remove(&entry.id);
        if self.selected >= self.channels.len() {
            self.selected = self.channels.len().saturating_sub(1);
        }
        self.save_subscriptions();
        self.status = format!("unsubscribed from {}", entry.label);
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
        let checkpoint_tx = self.checkpoint_tx.clone();

        tokio::spawn(async move {
            // Wrap both wait_ready AND publish_message in the same timeout so a
            // stuck sequencer (e.g. stale checkpoint retry loop) doesn't hang forever.
            let result = tokio::time::timeout(PUBLISH_TIMEOUT, async move {
                handle.wait_ready().await;
                handle.publish_message(text.into_bytes()).await
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
                }
                Ok(Err(e)) => {
                    tracing::warn!("publish error: {e}");
                    let _ = status_tx
                        .send(format!("publish error: {e} — check zone-board.log"))
                        .await;
                }
                Err(_) => {
                    tracing::warn!("publish timed out after {PUBLISH_TIMEOUT:?}");
                    let _ = status_tx
                        .send(format!(
                            "publish timed out after {}s — sequencer may have a stale checkpoint; delete sequencer.checkpoint and restart",
                            PUBLISH_TIMEOUT.as_secs()
                        ))
                        .await;
                }
            }
        });

        self.status = "waiting for sequencer…".to_string();
    }

    async fn handle_key(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                self.should_quit = true;
            }
            KeyCode::Up => {
                self.selected = self.selected.saturating_sub(1);
            }
            KeyCode::Down => {
                if self.selected + 1 < self.channels.len() {
                    self.selected += 1;
                }
            }
            KeyCode::Enter => {
                let input = self.input.trim().to_string();
                self.input.clear();

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
                } else if input == "/unsub" {
                    self.unsubscribe_selected();
                } else if input == "/quit" || input == "/q" {
                    self.should_quit = true;
                } else if !input.is_empty() {
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

    fn drain_background_channels(&mut self) {
        // Incoming finalized messages from indexers — clear matching pending entries
        while let Ok((channel_id, block)) = self.msg_rx.try_recv() {
            let block_id: [u8; 32] = block.id.into();
            let text = String::from_utf8_lossy(&block.data).into_owned();
            let bucket = self.messages.entry(channel_id).or_default();

            // Skip if already present (backfill and live stream may both deliver same block).
            if bucket.iter().any(|m| m.block_id == Some(block_id)) {
                continue;
            }

            // Confirm a matching pending message in-place rather than adding a duplicate.
            let confirmed_pending = bucket.iter_mut().find(|m| m.pending && m.text == text);
            if let Some(m) = confirmed_pending {
                m.pending = false;
                m.block_id = Some(block_id);
            } else {
                bucket.push_back(DisplayMessage {
                    text,
                    timestamp: chrono::Local::now().format("%H:%M:%S").to_string(),
                    pending: false,
                    block_id: Some(block_id),
                });
                while bucket.len() > MAX_MESSAGES_PER_CHANNEL {
                    bucket.pop_front();
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
        Ok(())
    }
}
