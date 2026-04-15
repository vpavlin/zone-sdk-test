use std::{io, path::PathBuf};

use clap::Parser;
use crossterm::{
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use lb_core::mantle::ops::channel::ChannelId;
use lb_zone_sdk::{adapter::NodeHttpClient, sequencer::ZoneSequencer, CommonHttpClient};
use ratatui::{backend::CrosstermBackend, Terminal};
use reqwest::Url;

mod app;
mod config;
mod ui;

use app::App;

#[derive(Parser, Debug)]
#[command(about = "Zone Board — multi-user bulletin board on the Logos blockchain")]
struct Args {
    /// Logos blockchain node HTTP endpoint
    #[arg(long, env = "NODE_URL")]
    node_url: String,

    /// Directory for storing the signing key, checkpoint, and subscriptions
    #[arg(long, default_value = ".", env = "DATA_DIR")]
    data_dir: String,

    /// Set your channel. Accepts either:
    ///   - a human-readable name (max 21 chars) — stored as "logos:yolo:<name>"
    ///   - a raw 64-char hex string (32 bytes)
    /// If omitted, a persistent random ID is generated on first run
    /// and saved to <data-dir>/channel.id.
    #[arg(long, env = "CHANNEL")]
    channel: Option<String>,
}

/// Parse a channel argument: 64-char hex → raw bytes; anything else → "logos:yolo:<name>".
fn parse_channel(input: &str) -> ChannelId {
    // Try hex first (exactly 64 hex chars = 32 bytes)
    if input.len() == 64 {
        if let Ok(bytes) = hex::decode(input) {
            if let Ok(arr) = <[u8; 32]>::try_from(bytes) {
                return ChannelId::from(arr);
            }
        }
    }
    // Treat as a human-readable name
    let full = format!("{}{input}", config::CHANNEL_PREFIX);
    let name_bytes = full.as_bytes();
    assert!(
        name_bytes.len() <= 32,
        "--channel name too long: max {} chars (got {})",
        32 - config::CHANNEL_PREFIX.len(),
        input.len()
    );
    let mut arr = [0u8; 32];
    arr[..name_bytes.len()].copy_from_slice(name_bytes);
    ChannelId::from(arr)
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();

    let node_url: Url = args.node_url.parse()?;
    let data_dir = PathBuf::from(&args.data_dir);

    // Load (or generate) the Ed25519 identity key
    let key = config::load_or_create_key(&data_dir.join("sequencer.key"));

    // Resolve channel ID: --channel (hex or name) → persisted file → fresh random
    let my_channel_id = if let Some(input) = &args.channel {
        let channel_id = parse_channel(input);
        config::save_channel_id(&data_dir.join("channel.id"), channel_id);
        channel_id
    } else {
        config::load_or_create_channel_id(&data_dir.join("channel.id"))
    };

    eprintln!("Channel ID: {}", hex::encode(my_channel_id.as_ref()));

    // Resume from a previous checkpoint if one exists (discarded automatically if channel changed)
    let checkpoint = config::load_checkpoint(&data_dir.join("sequencer.checkpoint"), my_channel_id);

    // Build the node HTTP adapter
    let node = NodeHttpClient::new(CommonHttpClient::new(None), node_url.clone());

    // Initialise the zone sequencer and spawn it as a background task
    let (sequencer, handle) = ZoneSequencer::init(my_channel_id, key, node.clone(), checkpoint);
    sequencer.spawn();

    // Build the application state
    let mut app = App::new(my_channel_id, handle, node, data_dir.clone());

    // Load cached messages for own channel before starting the indexer
    app.load_cache_for(my_channel_id);
    // Start an indexer on our own channel so our published messages appear on-screen
    app.spawn_indexer_for(my_channel_id);

    // Re-subscribe to channels saved from a previous session
    for hex_id in config::load_subscriptions(&data_dir.join("subscriptions.json")) {
        match hex::decode(&hex_id) {
            Ok(bytes) => match <[u8; 32]>::try_from(bytes) {
                Ok(arr) => app.subscribe(ChannelId::from(arr)),
                Err(_) => eprintln!("skipping malformed subscription (wrong length): {hex_id}"),
            },
            Err(_) => eprintln!("skipping malformed subscription (bad hex): {hex_id}"),
        }
    }

    // Enable logging to a file so it doesn't corrupt the TUI.
    // Tail with: tail -f zone-board.log
    let log_file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(data_dir.join("zone-board.log"))
        .expect("failed to open log file");
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn")),
        )
        .with_writer(std::sync::Mutex::new(log_file))
        .init();

    // Set up the terminal
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    // Run the main event loop
    let result = app.run(&mut terminal).await;

    // Restore the terminal regardless of how the loop ended
    disable_raw_mode()?;
    execute!(io::stdout(), LeaveAlternateScreen)?;
    terminal.show_cursor()?;

    result
}
