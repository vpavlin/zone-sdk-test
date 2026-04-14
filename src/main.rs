use std::{io, path::PathBuf};

use clap::Parser;
use crossterm::{
    execute,
    terminal::{EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode},
};
use lb_core::mantle::ops::channel::ChannelId;
use lb_zone_sdk::{
    CommonHttpClient,
    adapter::NodeHttpClient,
    sequencer::ZoneSequencer,
};
use ratatui::{Terminal, backend::CrosstermBackend};
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

    /// Set channel ID as a hex string (64 hex chars = 32 bytes).
    /// Takes precedence over --channel-name.
    #[arg(long, env = "CHANNEL_ID")]
    channel_id: Option<String>,

    /// Set channel ID as a human-readable name (max 21 chars).
    /// Stored as "logos:yolo:<name>" zero-padded to 32 bytes.
    /// Saved to <data-dir>/channel.id on first use.
    /// Example: --channel-name alice  →  channel ID = "logos:yolo:alice\0…"
    #[arg(long, env = "CHANNEL_NAME")]
    channel_name: Option<String>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();

    let node_url: Url = args.node_url.parse()?;
    let data_dir = PathBuf::from(&args.data_dir);

    // Load (or generate) the Ed25519 identity key
    let key = config::load_or_create_key(&data_dir.join("sequencer.key"));

    // Resolve channel ID: --channel-id hex → --channel-name text → persisted file → fresh random
    let my_channel_id = if let Some(hex_id) = &args.channel_id {
        let bytes = hex::decode(hex_id).expect("--channel-id must be valid hex");
        let arr: [u8; 32] = bytes.try_into().expect("--channel-id must be 64 hex chars (32 bytes)");
        ChannelId::from(arr)
    } else if let Some(name) = &args.channel_name {
        const PREFIX: &str = "logos:yolo:";
        let full = format!("{PREFIX}{name}");
        let name_bytes = full.as_bytes();
        assert!(name_bytes.len() <= 32, "--channel-name must be at most {} bytes", 32 - PREFIX.len());
        let mut arr = [0u8; 32];
        arr[..name_bytes.len()].copy_from_slice(name_bytes);
        let channel_id = ChannelId::from(arr);
        // Persist so future runs without --channel-name use the same ID
        config::save_channel_id(&data_dir.join("channel.id"), channel_id);
        channel_id
    } else {
        config::load_or_create_channel_id(&data_dir.join("channel.id"))
    };

    eprintln!("Channel ID: {}", hex::encode(my_channel_id.as_ref()));

    // Resume from a previous checkpoint if one exists
    let checkpoint = config::load_checkpoint(&data_dir.join("sequencer.checkpoint"));

    // Build the node HTTP adapter
    let node = NodeHttpClient::new(CommonHttpClient::new(None), node_url.clone());

    // Initialise the zone sequencer and spawn it as a background task
    let (sequencer, handle) = ZoneSequencer::init(my_channel_id, key, node.clone(), checkpoint);
    sequencer.spawn();

    // Build the application state
    let mut app = App::new(my_channel_id, handle, node, data_dir.clone());

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
