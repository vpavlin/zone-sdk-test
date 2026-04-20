// zone-cid-pinner — follow zone channels and pin every CID seen into a local
// Logos Storage node. Designed to run on a publicly reachable VM so NAT'd
// peers can source content through it.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result, anyhow};
use clap::Parser;
use futures_util::StreamExt;
use lb_common_http_client::CommonHttpClient;
use lb_core::mantle::ops::channel::ChannelId;
use logos_blockchain_zone_sdk::indexer::{Cursor, ZoneIndexer};
use once_cell::sync::Lazy;
use regex::Regex;
use reqwest::Url;
use serde::Deserialize;
use tokio::sync::RwLock;
use tracing::{debug, error, info, warn};

const CHANNEL_NAME_PREFIX: &[u8] = b"logos:yolo:";

// CIDv1 base32 ("b…") or legacy base58btc multibase ("z…"). Loose — we rely on
// the storage node to reject anything it doesn't like.
static CID_REGEX: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"\b[zb][A-Za-z0-9]{40,}\b").expect("valid regex"));

#[derive(Parser, Debug)]
#[command(
    about = "Follow zone channels and pin any CID they publish into a local Logos Storage node"
)]
struct Args {
    /// Logos blockchain node URL, e.g. http://node:8080
    #[arg(long, env = "NODE_URL")]
    node_url: String,

    /// Logos Storage node REST URL, e.g. http://localhost:8090
    #[arg(long, env = "STORAGE_URL")]
    storage_url: String,

    /// REST API prefix on the storage node. Use /api/codex/v1 for older
    /// Codex-based builds, /api/storage/v1 for newer logos-storage-nim.
    #[arg(long, env = "STORAGE_API_PREFIX", default_value = "/api/storage/v1")]
    api_prefix: String,

    /// Comma-separated channel names or 64-char hex channel IDs.
    #[arg(long, env = "CHANNELS", value_delimiter = ',', required = true)]
    channels: Vec<String>,

    /// Directory for cursor + dedupe state.
    #[arg(long, env = "STATE_DIR", default_value = "./state")]
    state_dir: PathBuf,

    /// Skip CIDs whose reported size exceeds this; also a hard cap on streamed
    /// bytes per fetch. Set to 0 to disable (not recommended).
    #[arg(long, env = "MAX_BYTES", default_value_t = 1_048_576)]
    max_bytes: u64,

    /// Poll interval per channel (seconds).
    #[arg(long, env = "POLL_INTERVAL", default_value_t = 3)]
    poll_interval_secs: u64,

    /// Slot lookback when bootstrapping a fresh channel (no cursor yet).
    /// At ~1s slots, 100 000 ≈ 28h of history.
    #[arg(long, env = "LOOKBACK_SLOTS", default_value_t = 100_000)]
    lookback_slots: u64,

    /// Per-fetch streaming timeout (seconds).
    #[arg(long, env = "FETCH_TIMEOUT", default_value_t = 300)]
    fetch_timeout_secs: u64,

    /// Also scan raw message text for bare CIDs (not just the YOLO board JSON
    /// `media[]` schema). Useful for channels that post CIDs as plain text.
    #[arg(long, env = "SCAN_RAW")]
    scan_raw: bool,

    /// After fetching, query the manifest locally to confirm the CID persisted.
    #[arg(long, env = "VERIFY")]
    verify: bool,

    /// Messages per poll batch.
    #[arg(long, default_value_t = 100)]
    batch_limit: usize,
}

// ── YOLO Board message payload schema ─────────────────────────────────────────
// { "v": 1, "text": "...", "media": [{"cid":"...","type":"...","name":"...","size":N}, ...] }

#[derive(Deserialize)]
struct Payload {
    #[serde(default)]
    media: Option<Vec<Media>>,
}

#[derive(Deserialize, Debug)]
struct Media {
    cid: String,
    #[serde(default)]
    size: u64,
    #[serde(default)]
    name: String,
    #[serde(default, rename = "type")]
    mime: String,
}

fn encode_channel(input: &str) -> Result<String> {
    if input.len() == 64 && input.chars().all(|c| c.is_ascii_hexdigit()) {
        return Ok(input.to_lowercase());
    }
    let mut bytes = Vec::with_capacity(32);
    bytes.extend_from_slice(CHANNEL_NAME_PREFIX);
    bytes.extend_from_slice(input.as_bytes());
    if bytes.len() > 32 {
        return Err(anyhow!(
            "channel name too long (max {} chars): {}",
            32 - CHANNEL_NAME_PREFIX.len(),
            input
        ));
    }
    bytes.resize(32, 0);
    Ok(hex::encode(bytes))
}

fn display_channel(hex_id: &str) -> String {
    if let Ok(bytes) = hex::decode(hex_id) {
        if bytes.len() == 32 && bytes.starts_with(CHANNEL_NAME_PREFIX) {
            let name = &bytes[CHANNEL_NAME_PREFIX.len()..];
            let end = name.iter().rposition(|b| *b != 0).map(|i| i + 1).unwrap_or(0);
            return String::from_utf8_lossy(&name[..end]).into_owned();
        }
    }
    let tail = hex_id.len().min(8);
    format!("{}…", &hex_id[..tail])
}

fn channel_id_from_hex(hex_id: &str) -> Result<ChannelId> {
    let bytes: [u8; 32] = hex::decode(hex_id)
        .context("channel id hex decode")?
        .try_into()
        .map_err(|_| anyhow!("channel id must be 32 bytes"))?;
    Ok(ChannelId::from(bytes))
}

fn cursor_for_slot(slot: u64) -> Option<Cursor> {
    serde_json::from_str::<Cursor>(&format!(r#"{{"slot":{slot},"last_id":null}}"#)).ok()
}

// ── Dedupe / state ────────────────────────────────────────────────────────────

struct Dedupe {
    path: PathBuf,
    set: RwLock<HashSet<String>>,
}

impl Dedupe {
    async fn load(state_dir: &Path) -> Result<Self> {
        let path = state_dir.join("fetched.json");
        let set = if path.exists() {
            let data = tokio::fs::read(&path).await?;
            serde_json::from_slice::<HashSet<String>>(&data).unwrap_or_default()
        } else {
            HashSet::new()
        };
        Ok(Self {
            path,
            set: RwLock::new(set),
        })
    }

    async fn contains(&self, cid: &str) -> bool {
        self.set.read().await.contains(cid)
    }

    async fn insert(&self, cid: String) {
        let mut g = self.set.write().await;
        if !g.insert(cid) {
            return;
        }
        let data = serde_json::to_vec(&*g).unwrap_or_default();
        drop(g);
        if let Err(e) = tokio::fs::write(&self.path, data).await {
            warn!("dedupe persist: {e}");
        }
    }
}

async fn load_cursor(state_dir: &Path, channel_hex: &str) -> Option<Cursor> {
    let path = state_dir.join(format!("{channel_hex}.cursor.json"));
    let data = tokio::fs::read(&path).await.ok()?;
    serde_json::from_slice::<Cursor>(&data).ok()
}

async fn save_cursor(state_dir: &Path, channel_hex: &str, cursor: &Cursor) {
    let path = state_dir.join(format!("{channel_hex}.cursor.json"));
    if let Ok(data) = serde_json::to_vec(cursor) {
        if let Err(e) = tokio::fs::write(&path, data).await {
            warn!("cursor persist: {e}");
        }
    }
}

// ── CID extraction ────────────────────────────────────────────────────────────

struct Found {
    cid: String,
    declared_size: Option<u64>,
    name: Option<String>,
    mime: Option<String>,
}

fn extract_cids(raw: &str, scan_raw: bool) -> Vec<Found> {
    let mut out = Vec::new();

    if raw.trim_start().starts_with('{') {
        if let Ok(p) = serde_json::from_str::<Payload>(raw) {
            if let Some(media) = p.media {
                for m in media {
                    if m.cid.is_empty() {
                        continue;
                    }
                    out.push(Found {
                        cid: m.cid,
                        declared_size: Some(m.size),
                        name: if m.name.is_empty() { None } else { Some(m.name) },
                        mime: if m.mime.is_empty() { None } else { Some(m.mime) },
                    });
                }
            }
        }
    }

    if out.is_empty() && scan_raw {
        for cap in CID_REGEX.find_iter(raw) {
            out.push(Found {
                cid: cap.as_str().to_string(),
                declared_size: None,
                name: None,
                mime: None,
            });
        }
    }

    out
}

// ── Storage HTTP client ───────────────────────────────────────────────────────

#[derive(Clone)]
struct Storage {
    base: String,
    prefix: String,
    client: reqwest::Client,
    max_bytes: u64,
    fetch_timeout: Duration,
    verify: bool,
}

impl Storage {
    fn new(
        storage_url: &str,
        api_prefix: &str,
        max_bytes: u64,
        fetch_timeout: Duration,
        verify: bool,
    ) -> Result<Self> {
        let base = storage_url.trim_end_matches('/').to_string();
        let mut prefix = api_prefix.trim_end_matches('/').to_string();
        if !prefix.starts_with('/') {
            prefix = format!("/{prefix}");
        }
        let client = reqwest::Client::builder()
            .pool_idle_timeout(Duration::from_secs(30))
            .build()?;
        Ok(Self {
            base,
            prefix,
            client,
            max_bytes,
            fetch_timeout,
            verify,
        })
    }

    /// GET {prefix}/data/<cid>/network/stream — streams the content
    /// through the local storage node, which pulls it from the network and
    /// (typically) caches it locally. We discard the bytes but cap at max_bytes.
    async fn pin(&self, cid: &str) -> Result<u64> {
        let url = format!("{}{}/data/{}/network/stream", self.base, self.prefix, cid);
        let resp = tokio::time::timeout(
            self.fetch_timeout,
            self.client.get(&url).send(),
        )
        .await
        .map_err(|_| anyhow!("fetch timeout after {:?}", self.fetch_timeout))??;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(anyhow!("HTTP {status}: {body}"));
        }

        if let Some(cl) = resp.content_length() {
            if self.max_bytes > 0 && cl > self.max_bytes {
                // Drop the connection to avoid pulling the full object.
                drop(resp);
                return Err(anyhow!(
                    "content-length {cl} exceeds max_bytes {}",
                    self.max_bytes
                ));
            }
        }

        let mut stream = resp.bytes_stream();
        let mut total: u64 = 0;
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.context("stream chunk")?;
            total = total.saturating_add(chunk.len() as u64);
            if self.max_bytes > 0 && total > self.max_bytes {
                return Err(anyhow!(
                    "stream exceeded max_bytes {} (saw {total})",
                    self.max_bytes
                ));
            }
        }
        Ok(total)
    }

    /// Ask the local node for the manifest. If this returns 200 with JSON, the
    /// CID is known locally and presumably persisted.
    async fn verify_manifest(&self, cid: &str) -> Result<serde_json::Value> {
        let url = format!("{}{}/data/{}/network/manifest", self.base, self.prefix, cid);
        let resp = self.client.get(&url).send().await?;
        if !resp.status().is_success() {
            return Err(anyhow!("manifest HTTP {}", resp.status()));
        }
        Ok(resp.json().await?)
    }

    /// GET {prefix}/debug/info — peer id, listen addrs, announce addrs, SPR.
    async fn debug_info(&self) -> Result<DebugInfo> {
        let url = format!("{}{}/debug/info", self.base, self.prefix);
        let resp = self.client.get(&url).send().await?;
        if !resp.status().is_success() {
            return Err(anyhow!("debug/info HTTP {}", resp.status()));
        }
        Ok(resp.json().await?)
    }
}

#[derive(Deserialize, Debug)]
struct DebugInfo {
    #[serde(default)]
    id: String,
    #[serde(default)]
    spr: String,
    #[serde(default)]
    addrs: Vec<String>,
    #[serde(default, rename = "announceAddresses")]
    announce_addresses: Vec<String>,
}

// ── Storage identity ─────────────────────────────────────────────────────────

async fn print_storage_identity(storage: &Storage) {
    let mut last_err = String::from("unknown");
    for attempt in 1..=10 {
        match storage.debug_info().await {
            Ok(info) => {
                let bar = "═".repeat(72);
                println!("\n{bar}");
                println!(" Logos Storage node identity (share this with NAT'd peers)");
                println!("{bar}");
                println!("  peer id : {}", info.id);
                println!("  spr     : {}", info.spr);
                if !info.addrs.is_empty() {
                    println!("  listen  : {}", info.addrs.join(", "));
                }
                if !info.announce_addresses.is_empty() {
                    println!("  announce: {}", info.announce_addresses.join(", "));
                }
                println!("{bar}");
                println!(" On a NAT'd YOLO Board peer, connect to this node via:");
                println!("   storage_module.connect(\"{}\", [])", info.id);
                println!(" (or pass explicit addrs if the announce list is empty)");
                println!("{bar}\n");
                return;
            }
            Err(e) => {
                last_err = e.to_string();
                warn!(
                    attempt,
                    "debug/info not ready yet ({last_err}) — retrying in 2s"
                );
                tokio::time::sleep(Duration::from_secs(2)).await;
            }
        }
    }
    error!(
        "could not fetch storage identity after 10 attempts: {last_err} — check --storage-url"
    );
}

// ── Per-channel loop ──────────────────────────────────────────────────────────

async fn run_channel(
    channel_hex: String,
    name: String,
    args: Arc<Args>,
    storage: Storage,
    dedupe: Arc<Dedupe>,
) -> Result<()> {
    let channel_id = channel_id_from_hex(&channel_hex)?;
    let node_url: Url = args.node_url.parse().context("node url")?;
    let indexer = ZoneIndexer::new(channel_id, node_url.clone(), None);
    let http = CommonHttpClient::new(None);

    // Bootstrap cursor: disk → (tip - lookback) → None.
    let mut cursor = match load_cursor(&args.state_dir, &channel_hex).await {
        Some(c) => {
            info!(channel = %name, "resuming from saved cursor");
            Some(c)
        }
        None => match http.consensus_info(node_url.clone()).await {
            Ok(info) => {
                let tip: u64 = info.slot.into();
                let start = tip.saturating_sub(args.lookback_slots);
                info!(channel = %name, tip, start, "no saved cursor — seeding at tip-lookback");
                cursor_for_slot(start)
            }
            Err(e) => {
                warn!(channel = %name, "consensus_info failed: {e} — starting from genesis");
                None
            }
        },
    };

    let poll_interval = Duration::from_secs(args.poll_interval_secs);

    loop {
        match indexer.next_messages(cursor, args.batch_limit).await {
            Ok(poll) => {
                let got = poll.messages.len();
                if got > 0 {
                    info!(channel = %name, count = got, "new messages");
                }
                for block in &poll.messages {
                    let raw = String::from_utf8_lossy(&block.data);
                    let msg_id = hex::encode(<[u8; 32]>::from(block.id));
                    let cids = extract_cids(&raw, args.scan_raw);
                    if !cids.is_empty() {
                        info!(
                            channel = %name,
                            msg = %&msg_id[..16.min(msg_id.len())],
                            cids = cids.len(),
                            "cids in message",
                        );
                    }
                    for f in cids {
                        if dedupe.contains(&f.cid).await {
                            debug!(cid = %f.cid, "already fetched — skip");
                            continue;
                        }
                        if args.max_bytes > 0 {
                            if let Some(sz) = f.declared_size {
                                if sz > args.max_bytes {
                                    warn!(
                                        cid = %f.cid, size = sz, max = args.max_bytes,
                                        "skipping oversized CID"
                                    );
                                    dedupe.insert(f.cid).await;
                                    continue;
                                }
                            }
                        }
                        let storage = storage.clone();
                        let dedupe = dedupe.clone();
                        let cid = f.cid.clone();
                        let label = format!(
                            "{} {} {}",
                            f.mime.as_deref().unwrap_or("?"),
                            f.name.as_deref().unwrap_or(""),
                            f.declared_size.map(|s| format!("{s}B")).unwrap_or_default(),
                        );
                        tokio::spawn(async move {
                            info!(cid = %cid, meta = %label, "pinning…");
                            match storage.pin(&cid).await {
                                Ok(bytes) => {
                                    info!(cid = %cid, bytes, "pinned OK");
                                    dedupe.insert(cid.clone()).await;
                                    if storage.verify {
                                        match storage.verify_manifest(&cid).await {
                                            Ok(m) => info!(cid = %cid, manifest = %m, "manifest present"),
                                            Err(e) => warn!(cid = %cid, "manifest check: {e}"),
                                        }
                                    }
                                }
                                Err(e) => {
                                    error!(cid = %cid, "pin failed: {e}");
                                    // Do not dedupe — retry next sighting.
                                }
                            }
                        });
                    }
                }
                cursor = Some(poll.cursor);
                save_cursor(&args.state_dir, &channel_hex, &poll.cursor).await;
                if got == 0 {
                    tokio::time::sleep(poll_interval).await;
                }
            }
            Err(e) => {
                warn!(channel = %name, "next_messages: {e} — backing off 5s");
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
        }
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info,zone_cid_pinner=info")),
        )
        .init();

    let args = Arc::new(Args::parse());

    tokio::fs::create_dir_all(&args.state_dir).await
        .with_context(|| format!("create state dir {:?}", args.state_dir))?;

    let storage = Storage::new(
        &args.storage_url,
        &args.api_prefix,
        args.max_bytes,
        Duration::from_secs(args.fetch_timeout_secs),
        args.verify,
    )?;

    let dedupe = Arc::new(Dedupe::load(&args.state_dir).await?);

    info!(
        node = %args.node_url,
        storage = %args.storage_url,
        channels = args.channels.len(),
        max_bytes = args.max_bytes,
        "starting pinner"
    );

    // Print storage node identity so YOLO Board peers (behind NAT) can
    // point storage_module.connect() at this public node.
    print_storage_identity(&storage).await;

    let mut handles = Vec::new();
    for input in &args.channels {
        let hex = encode_channel(input).with_context(|| format!("channel '{input}'"))?;
        let name = display_channel(&hex);
        info!(channel = %name, id = %hex, "following");
        let args_cloned = args.clone();
        let storage_cloned = storage.clone();
        let dedupe_cloned = dedupe.clone();
        let name_for_log = name.clone();
        handles.push(tokio::spawn(async move {
            if let Err(e) = run_channel(hex, name, args_cloned, storage_cloned, dedupe_cloned).await {
                error!(channel = %name_for_log, "fatal: {e:#}");
            }
        }));
    }

    tokio::select! {
        _ = tokio::signal::ctrl_c() => {
            info!("shutdown requested");
        }
        _ = futures_util::future::join_all(handles) => {
            warn!("all channel loops exited");
        }
    }
    Ok(())
}
