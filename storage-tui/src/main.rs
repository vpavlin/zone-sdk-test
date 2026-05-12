// Minimal TUI for a Logos Storage node (Codex-compatible REST).
// Displays peer count, local manifests, and lets you fetch a CID by pasting it
// into the input box.

use std::io;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use clap::Parser;
use crossterm::{
    event::{self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEventKind, KeyModifiers},
    execute,
    terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen},
};
use std::path::Path;
use ratatui::{
    backend::CrosstermBackend,
    layout::{Constraint, Direction, Layout, Margin},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Block, Borders, List, ListItem, ListState, Paragraph, Wrap},
    Terminal,
};
use serde::Deserialize;
use tokio::sync::RwLock;

#[derive(Parser, Debug, Clone)]
#[command(about = "TUI for Logos Storage / Codex-compatible REST API")]
struct Args {
    #[arg(long, env = "STORAGE_URL", default_value = "http://localhost:8080")]
    url: String,

    #[arg(long, env = "STORAGE_API_PREFIX", default_value = "/api/codex/v1")]
    prefix: String,

    #[arg(long, env = "POLL_INTERVAL_SECS", default_value_t = 3)]
    poll_secs: u64,
}

// ── Responses ────────────────────────────────────────────────────────────────

#[derive(Deserialize, Debug, Default, Clone)]
struct DebugInfo {
    #[serde(default)]
    id: String,
    #[serde(default)]
    spr: String,
    #[serde(default)]
    addrs: Vec<String>,
    #[serde(default, rename = "announceAddresses")]
    announce: Vec<String>,
    #[serde(default)]
    table: TableInfo,
}

#[derive(Deserialize, Debug, Default, Clone)]
struct TableInfo {
    #[serde(default)]
    nodes: Vec<serde_json::Value>,
}

#[derive(Deserialize, Debug, Default, Clone)]
struct SpaceInfo {
    #[serde(default, rename = "totalBlocks")]
    total_blocks: u64,
    #[serde(default, rename = "quotaMaxBytes")]
    quota_max: u64,
    #[serde(default, rename = "quotaUsedBytes")]
    quota_used: u64,
    #[serde(default, rename = "quotaReservedBytes")]
    quota_reserved: u64,
}

#[derive(Deserialize, Debug, Default, Clone)]
struct Manifest {
    #[serde(default)]
    cid: String,
    #[serde(default, rename = "datasetSize")]
    dataset_size: u64,
    #[serde(default)]
    filename: String,
    #[serde(default)]
    mimetype: String,
}

#[derive(Deserialize, Debug, Clone, Default)]
#[serde(default)]
struct ManifestsResponse {
    /// codex-js calls this `content`; older builds used `manifests`. Accept either.
    #[serde(alias = "manifests")]
    content: Vec<ManifestOuter>,
}

#[derive(Deserialize, Debug, Clone, Default)]
struct ManifestOuter {
    #[serde(default)]
    cid: String,
    #[serde(default)]
    manifest: Manifest,
}

// ── Client ───────────────────────────────────────────────────────────────────

#[derive(Clone)]
struct Client {
    base: String,
    prefix: String,
    client: reqwest::Client,
}

impl Client {
    fn new(args: &Args) -> Result<Self> {
        let base = args.url.trim_end_matches('/').to_string();
        let mut prefix = args.prefix.trim_end_matches('/').to_string();
        if !prefix.starts_with('/') {
            prefix = format!("/{prefix}");
        }
        Ok(Self {
            base,
            prefix,
            client: reqwest::Client::builder()
                .timeout(Duration::from_secs(10))
                .build()?,
        })
    }

    fn url(&self, path: &str) -> String {
        format!("{}{}{}", self.base, self.prefix, path)
    }

    async fn debug_info(&self) -> Result<DebugInfo> {
        Ok(self.client.get(self.url("/debug/info")).send().await?.error_for_status()?.json().await?)
    }

    async fn space(&self) -> Result<SpaceInfo> {
        Ok(self.client.get(self.url("/space")).send().await?.error_for_status()?.json().await?)
    }

    async fn manifests(&self) -> Result<Vec<Manifest>> {
        let resp = self.client.get(self.url("/data")).send().await?.error_for_status()?;
        let txt = resp.text().await?;
        // The API has returned both `[{manifest...}]` and `{"manifests":[{cid,manifest:{...}}]}` over time.
        // Try both.
        if let Ok(list) = serde_json::from_str::<Vec<Manifest>>(&txt) {
            return Ok(list);
        }
        if let Ok(wrapped) = serde_json::from_str::<ManifestsResponse>(&txt) {
            return Ok(wrapped
                .content
                .into_iter()
                .map(|m| Manifest {
                    cid: if m.manifest.cid.is_empty() { m.cid } else { m.manifest.cid },
                    dataset_size: m.manifest.dataset_size,
                    filename: m.manifest.filename,
                    mimetype: m.manifest.mimetype,
                })
                .collect());
        }
        Err(anyhow::anyhow!("unknown manifests shape: {}", txt.chars().take(200).collect::<String>()))
    }

    async fn fetch_cid(&self, cid: &str) -> Result<u64> {
        let url = self.url(&format!("/data/{cid}/network/stream"));
        let resp = self.client.get(&url).send().await?.error_for_status()?;
        let bytes = resp.bytes().await?;
        Ok(bytes.len() as u64)
    }

    /// Fetch and return the body as a UTF-8 string. Capped at `limit` bytes to
    /// avoid pulling a huge file into memory.
    async fn fetch_text(&self, cid: &str, limit: usize) -> Result<String> {
        let url = self.url(&format!("/data/{cid}/network/stream"));
        let resp = self.client.get(&url).send().await?.error_for_status()?;
        let bytes = resp.bytes().await?;
        let slice = if bytes.len() > limit { &bytes[..limit] } else { &bytes[..] };
        Ok(String::from_utf8_lossy(slice).into_owned())
    }

    async fn upload_file(&self, path: &str) -> Result<String> {
        let path = Path::new(path);
        let bytes = tokio::fs::read(path).await.context("read file")?;
        let mime = mime_from_path(path);
        let filename = path.file_name().unwrap_or_default().to_string_lossy().to_string();
        let url = self.url("/data");
        let resp = self.client
            .post(&url)
            .header("Content-Type", mime)
            .header("Codex-Filename", &filename)
            .body(bytes)
            .send()
            .await?
            .error_for_status()?;
        #[derive(serde::Deserialize)]
        struct UploadResp { cid: String }
        let r: UploadResp = resp.json().await.context("parse upload response")?;
        Ok(r.cid)
    }
}

fn mime_from_path(path: &Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).map(|e| e.to_lowercase()).as_deref() {
        Some("png")          => "image/png",
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("gif")          => "image/gif",
        Some("webp")         => "image/webp",
        Some("mp4")          => "video/mp4",
        Some("webm")         => "video/webm",
        Some("txt")          => "text/plain",
        Some("json")         => "application/json",
        _                    => "application/octet-stream",
    }
}

// ── App state ────────────────────────────────────────────────────────────────

#[derive(Default, PartialEq)]
enum InputMode { #[default] None, Fetch, Upload }

#[derive(Default)]
struct AppState {
    info: Option<DebugInfo>,
    info_err: Option<String>,
    space: Option<SpaceInfo>,
    manifests: Vec<Manifest>,
    manifests_err: Option<String>,
    last_refresh: Option<std::time::Instant>,
    status: String,
    input: String,
    input_mode: InputMode,
    list_state: ListState,
    viewer: Option<Viewer>,
}

struct Viewer {
    cid: String,
    name: String,
    body: String,
    scroll: u16,
}

impl AppState {
    fn selected(&self) -> Option<&Manifest> {
        let i = self.list_state.selected()?;
        self.manifests.get(i)
    }
    fn input_active(&self) -> bool { self.input_mode != InputMode::None }
}

fn human_bytes(n: u64) -> String {
    const UNITS: &[&str] = &["B", "KB", "MB", "GB", "TB"];
    let mut v = n as f64;
    let mut u = 0;
    while v >= 1024.0 && u < UNITS.len() - 1 {
        v /= 1024.0;
        u += 1;
    }
    if u == 0 {
        format!("{n} {}", UNITS[u])
    } else {
        format!("{v:.1} {}", UNITS[u])
    }
}

fn short_cid(cid: &str) -> String {
    if cid.len() <= 16 {
        cid.to_string()
    } else {
        format!("{}…{}", &cid[..8], &cid[cid.len() - 8..])
    }
}

// ── Async poller ─────────────────────────────────────────────────────────────

async fn poll_loop(client: Client, state: Arc<RwLock<AppState>>, interval: Duration) {
    loop {
        let info_res = client.debug_info().await;
        let space_res = client.space().await;
        let manifests_res = client.manifests().await;
        {
            let mut s = state.write().await;
            match info_res {
                Ok(i) => { s.info = Some(i); s.info_err = None; }
                Err(e) => s.info_err = Some(e.to_string()),
            }
            if let Ok(sp) = space_res { s.space = Some(sp); }
            match manifests_res {
                Ok(m) => {
                    if s.list_state.selected().is_none() && !m.is_empty() {
                        s.list_state.select(Some(0));
                    }
                    if let Some(sel) = s.list_state.selected() {
                        if sel >= m.len() && !m.is_empty() {
                            s.list_state.select(Some(m.len() - 1));
                        }
                    }
                    s.manifests = m;
                    s.manifests_err = None;
                }
                Err(e) => s.manifests_err = Some(e.to_string()),
            }
            s.last_refresh = Some(std::time::Instant::now());
        }
        tokio::time::sleep(interval).await;
    }
}

// ── Rendering ────────────────────────────────────────────────────────────────

fn draw(f: &mut ratatui::Frame, state: &mut AppState, args: &Args) {
    let size = f.area();

    // ── Viewer overlay (full screen) ──
    if let Some(v) = &state.viewer {
        let title = format!(" {} — {}   [Esc close · ↑/↓ scroll · PgUp/PgDn] ", short_cid(&v.cid), v.name);
        let para = Paragraph::new(v.body.clone())
            .wrap(Wrap { trim: false })
            .scroll((v.scroll, 0))
            .block(Block::default().borders(Borders::ALL).title(title));
        f.render_widget(para, size);
        return;
    }

    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(5),  // header
            Constraint::Min(6),     // manifests
            Constraint::Length(5),  // details / fetch status
            Constraint::Length(3),  // input
            Constraint::Length(1),  // keybinds
        ])
        .split(size);

    // ── Header ──
    let id = state.info.as_ref().map(|i| i.id.as_str()).unwrap_or("…");
    let peers = state.info.as_ref().map(|i| i.table.nodes.len()).unwrap_or(0);
    let space_line = state.space.as_ref().map(|s| {
        format!(
            "space: {} used / {} quota   blocks: {}",
            human_bytes(s.quota_used), human_bytes(s.quota_max), s.total_blocks,
        )
    }).unwrap_or_else(|| "space: ?".into());
    let announce = state.info.as_ref().map(|i| i.announce.join(", ")).unwrap_or_default();
    let err_line = state.info_err.clone().map(|e| format!(" [err: {e}]")).unwrap_or_default();
    let header = Paragraph::new(vec![
        Line::from(vec![
            Span::styled("node: ", Style::default().fg(Color::DarkGray)),
            Span::raw(&args.url),
            Span::styled(args.prefix.as_str(), Style::default().fg(Color::DarkGray)),
        ]),
        Line::from(vec![
            Span::styled("peer: ", Style::default().fg(Color::DarkGray)),
            Span::raw(short_cid(id)),
            Span::raw("   "),
            Span::styled("peers: ", Style::default().fg(Color::DarkGray)),
            Span::styled(format!("{peers}"), Style::default().fg(Color::Cyan).add_modifier(Modifier::BOLD)),
        ]),
        Line::from(vec![Span::raw(space_line)]),
        Line::from(vec![
            Span::styled("announce: ", Style::default().fg(Color::DarkGray)),
            Span::raw(announce),
            Span::styled(err_line, Style::default().fg(Color::Red)),
        ]),
    ])
    .block(Block::default().borders(Borders::ALL).title(" Logos Storage "));
    f.render_widget(header, chunks[0]);

    // ── Manifests list ──
    let items: Vec<ListItem> = if let Some(e) = &state.manifests_err {
        vec![ListItem::new(Line::from(Span::styled(format!("error: {e}"), Style::default().fg(Color::Red))))]
    } else if state.manifests.is_empty() {
        vec![ListItem::new(Line::from(Span::styled("(no local manifests yet)", Style::default().fg(Color::DarkGray))))]
    } else {
        state.manifests.iter().map(|m| {
            let name = if m.filename.is_empty() { "-" } else { m.filename.as_str() };
            let mime = if m.mimetype.is_empty() { "-" } else { m.mimetype.as_str() };
            ListItem::new(Line::from(vec![
                Span::styled(short_cid(&m.cid), Style::default().fg(Color::Yellow)),
                Span::raw("  "),
                Span::styled(format!("{:>10}", human_bytes(m.dataset_size)), Style::default().fg(Color::Cyan)),
                Span::raw("  "),
                Span::styled(format!("{:<24}", mime.chars().take(24).collect::<String>()), Style::default().fg(Color::Magenta)),
                Span::raw("  "),
                Span::raw(name.to_string()),
            ]))
        }).collect()
    };
    let list = List::new(items)
        .block(Block::default().borders(Borders::ALL).title(format!(" Manifests ({}) ", state.manifests.len())))
        .highlight_style(Style::default().bg(Color::DarkGray).add_modifier(Modifier::BOLD))
        .highlight_symbol("▶ ");
    f.render_stateful_widget(list, chunks[1], &mut state.list_state);

    // ── Details pane ──
    let details = if let Some(m) = state.selected() {
        vec![
            Line::from(vec![Span::styled("cid: ", Style::default().fg(Color::DarkGray)), Span::raw(m.cid.clone())]),
            Line::from(vec![
                Span::styled("size: ", Style::default().fg(Color::DarkGray)),
                Span::raw(human_bytes(m.dataset_size)),
                Span::raw("   "),
                Span::styled("mime: ", Style::default().fg(Color::DarkGray)),
                Span::raw(m.mimetype.clone()),
            ]),
            Line::from(vec![Span::styled("name: ", Style::default().fg(Color::DarkGray)), Span::raw(m.filename.clone())]),
        ]
    } else {
        vec![Line::from(Span::styled("(select a manifest)", Style::default().fg(Color::DarkGray)))]
    };
    f.render_widget(
        Paragraph::new(details)
            .wrap(Wrap { trim: false })
            .block(Block::default().borders(Borders::ALL).title(" Details ")),
        chunks[2],
    );

    // ── Input ──
    let active = state.input_active();
    let input_style = if active {
        Style::default().fg(Color::White).bg(Color::Rgb(40, 40, 40))
    } else {
        Style::default().fg(Color::DarkGray)
    };
    let (prompt_label, box_title) = match state.input_mode {
        InputMode::Upload => ("upload> ", " Upload file "),
        _ => ("fetch> ", " Fetch CID "),
    };
    let box_title = if state.status.is_empty() {
        format!(" {} ", box_title.trim())
    } else {
        format!(" {} — {} ", box_title.trim(), state.status)
    };
    let input = Paragraph::new(Line::from(vec![
        Span::styled(prompt_label, Style::default().fg(Color::DarkGray)),
        Span::styled(state.input.clone(), input_style),
        Span::styled(if active { "_" } else { "" }, Style::default().fg(Color::White)),
    ]))
    .block(Block::default().borders(Borders::ALL).title(box_title));
    f.render_widget(input, chunks[3]);

    // ── Keybinds ──
    let keys = Paragraph::new(Line::from(vec![
        Span::styled(" q ", Style::default().fg(Color::Black).bg(Color::White)),
        Span::raw(" quit  "),
        Span::styled(" r ", Style::default().fg(Color::Black).bg(Color::White)),
        Span::raw(" refresh  "),
        Span::styled(" ↑/↓ ", Style::default().fg(Color::Black).bg(Color::White)),
        Span::raw(" select  "),
        Span::styled(" / ", Style::default().fg(Color::Black).bg(Color::White)),
        Span::raw(" fetch CID  "),
        Span::styled(" u ", Style::default().fg(Color::Black).bg(Color::White)),
        Span::raw(" upload file  "),
        Span::styled(" v ", Style::default().fg(Color::Black).bg(Color::White)),
        Span::raw(" view text  "),
        Span::styled(" enter ", Style::default().fg(Color::Black).bg(Color::White)),
        Span::raw(" submit/use selected "),
    ]));
    f.render_widget(keys, chunks[4].inner(Margin { horizontal: 1, vertical: 0 }));
}

// ── Main event loop ──────────────────────────────────────────────────────────

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let client = Client::new(&args).context("build client")?;
    let state = Arc::new(RwLock::new(AppState::default()));

    // Poller
    {
        let client = client.clone();
        let state = state.clone();
        let interval = Duration::from_secs(args.poll_secs);
        tokio::spawn(async move { poll_loop(client, state, interval).await });
    }

    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen, EnableMouseCapture)?;
    let mut terminal = Terminal::new(CrosstermBackend::new(stdout))?;

    let res = run_app(&mut terminal, state, client, args).await;

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen, DisableMouseCapture)?;
    terminal.show_cursor()?;

    res
}

async fn run_app<B: ratatui::backend::Backend>(
    terminal: &mut Terminal<B>,
    state: Arc<RwLock<AppState>>,
    client: Client,
    args: Args,
) -> Result<()> {
    loop {
        {
            let mut s = state.write().await;
            terminal.draw(|f| draw(f, &mut s, &args))?;
        }

        if !event::poll(Duration::from_millis(150))? {
            continue;
        }
        let Event::Key(k) = event::read()? else { continue };
        if k.kind != KeyEventKind::Press {
            continue;
        }

        let mut s = state.write().await;

        // Viewer captures all keys while open.
        if s.viewer.is_some() {
            match k.code {
                KeyCode::Esc | KeyCode::Char('q') => { s.viewer = None; }
                KeyCode::Down | KeyCode::Char('j') => {
                    if let Some(v) = s.viewer.as_mut() { v.scroll = v.scroll.saturating_add(1); }
                }
                KeyCode::Up | KeyCode::Char('k') => {
                    if let Some(v) = s.viewer.as_mut() { v.scroll = v.scroll.saturating_sub(1); }
                }
                KeyCode::PageDown | KeyCode::Char(' ') => {
                    if let Some(v) = s.viewer.as_mut() { v.scroll = v.scroll.saturating_add(20); }
                }
                KeyCode::PageUp => {
                    if let Some(v) = s.viewer.as_mut() { v.scroll = v.scroll.saturating_sub(20); }
                }
                KeyCode::Home | KeyCode::Char('g') => {
                    if let Some(v) = s.viewer.as_mut() { v.scroll = 0; }
                }
                _ => {}
            }
            continue;
        }

        if s.input_active() {
            match k.code {
                KeyCode::Esc => { s.input_mode = InputMode::None; s.input.clear(); }
                KeyCode::Enter => {
                    let value = s.input.trim().to_string();
                    let mode = std::mem::replace(&mut s.input_mode, InputMode::None);
                    s.input.clear();
                    if value.is_empty() {
                        s.status = "empty input".into();
                    } else if mode == InputMode::Fetch {
                        s.status = format!("fetching {}…", short_cid(&value));
                        let client = client.clone();
                        let state = state.clone();
                        tokio::spawn(async move {
                            let result = client.fetch_cid(&value).await;
                            let mut s = state.write().await;
                            s.status = match result {
                                Ok(n) => format!("OK {} ← {}", human_bytes(n), short_cid(&value)),
                                Err(e) => format!("ERR {} ({})", short_cid(&value), e),
                            };
                        });
                    } else {
                        s.status = format!("uploading {}…", value);
                        let client = client.clone();
                        let state = state.clone();
                        tokio::spawn(async move {
                            let result = client.upload_file(&value).await;
                            let mut s = state.write().await;
                            s.status = match result {
                                Ok(cid) => format!("uploaded → {}", short_cid(&cid)),
                                Err(e) => format!("upload ERR: {e}"),
                            };
                        });
                    }
                }
                KeyCode::Backspace => { s.input.pop(); }
                KeyCode::Char(c) => {
                    if k.modifiers.contains(KeyModifiers::CONTROL) && (c == 'c' || c == 'u') {
                        s.input.clear();
                        if c == 'c' { s.input_mode = InputMode::None; }
                    } else {
                        s.input.push(c);
                    }
                }
                _ => {}
            }
            continue;
        }

        match k.code {
            KeyCode::Char('q') | KeyCode::Esc => break,
            KeyCode::Char('c') if k.modifiers.contains(KeyModifiers::CONTROL) => break,
            KeyCode::Char('r') => { s.last_refresh = None; }
            KeyCode::Char('/') => {
                s.input_mode = InputMode::Fetch;
                s.input.clear();
                s.status.clear();
            }
            KeyCode::Char('u') => {
                s.input_mode = InputMode::Upload;
                s.input.clear();
                s.status.clear();
            }
            KeyCode::Char('v') => {
                if let Some(m) = s.selected() {
                    let cid = m.cid.clone();
                    let name = if m.filename.is_empty() { "(unnamed)".to_string() } else { m.filename.clone() };
                    let size = m.dataset_size;
                    s.status = format!("loading {}…", short_cid(&cid));
                    let client = client.clone();
                    let state = state.clone();
                    tokio::spawn(async move {
                        let limit = 256 * 1024;  // 256 KiB preview cap
                        let body = client.fetch_text(&cid, limit).await;
                        let mut s = state.write().await;
                        match body {
                            Ok(mut txt) => {
                                if size as usize > limit {
                                    txt.push_str(&format!(
                                        "\n\n[truncated at {} / {}]",
                                        human_bytes(limit as u64), human_bytes(size),
                                    ));
                                }
                                s.viewer = Some(Viewer { cid: cid.clone(), name, body: txt, scroll: 0 });
                                s.status = format!("viewing {}", short_cid(&cid));
                            }
                            Err(e) => s.status = format!("view failed: {e}"),
                        }
                    });
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                let len = s.manifests.len();
                if len > 0 {
                    let i = s.list_state.selected().unwrap_or(0);
                    s.list_state.select(Some((i + 1).min(len - 1)));
                }
            }
            KeyCode::Up | KeyCode::Char('k') => {
                let i = s.list_state.selected().unwrap_or(0);
                s.list_state.select(Some(i.saturating_sub(1)));
            }
            KeyCode::Enter => {
                if let Some(m) = s.selected() {
                    let cid = m.cid.clone();
                    s.status = format!("re-fetching {}…", short_cid(&cid));
                    let client = client.clone();
                    let state = state.clone();
                    tokio::spawn(async move {
                        let result = client.fetch_cid(&cid).await;
                        let mut s = state.write().await;
                        s.status = match result {
                            Ok(n) => format!("OK {} ← {}", human_bytes(n), short_cid(&cid)),
                            Err(e) => format!("ERR {} ({})", short_cid(&cid), e),
                        };
                    });
                }
            }
            _ => {}
        }
    }
    Ok(())
}
