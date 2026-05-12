fn display_text(raw: &str) -> String {
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(raw) {
        let text = v["text"].as_str().unwrap_or("").trim().to_string();
        let media_names: Vec<String> = v["media"]
            .as_array()
            .map(|arr| {
                arr.iter()
                    .filter_map(|m| m["name"].as_str())
                    .map(|s| s.to_string())
                    .collect()
            })
            .unwrap_or_default();

        if !media_names.is_empty() {
            let attachments = media_names.join(", ");
            if text.is_empty() {
                return format!("[{attachments}]");
            }
            return format!("{text}  [{attachments}]");
        }
        if !text.is_empty() {
            return text;
        }
    }
    raw.to_string()
}

use ratatui::{
    Frame,
    layout::{Constraint, Direction, Layout},
    style::{Color, Modifier, Style},
    widgets::{Block, Borders, List, ListItem, Paragraph},
};

use crate::app::{App, Focus};

pub fn render(frame: &mut Frame, app: &App) {
    let area = frame.area();

    // Outer layout: title (1) | content (fill) | bottom bar (3)
    let outer = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1),
            Constraint::Min(0),
            Constraint::Length(3),
        ])
        .split(area);

    render_title(frame, app, outer[0]);
    render_content(frame, app, outer[1]);
    render_bottom(frame, app, outer[2]);
}

fn render_title(frame: &mut Frame, app: &App, area: ratatui::layout::Rect) {
    let channel_hex = hex::encode(app.my_channel_id.as_ref());
    let channel_name = crate::config::channel_id_label(app.my_channel_id);
    let (conn_dot, conn_color) = if app.node_connected {
        ("●", Color::Green)
    } else {
        ("●", Color::Red)
    };
    let sync_span = app.global_sync_progress().map(|pct| {
        use ratatui::text::Span;
        const BAR_WIDTH: usize = 20;
        let filled = (pct as usize * BAR_WIDTH / 100).min(BAR_WIDTH);
        let empty = BAR_WIDTH - filled;
        let bar = format!(
            "  ⟳ [{}{}] {:3}%",
            "█".repeat(filled),
            "░".repeat(empty),
            pct,
        );
        Span::styled(bar, Style::default().bg(Color::Blue).fg(Color::Yellow))
    });
    use ratatui::text::{Line, Span};
    let mut spans = vec![
        Span::styled(
            format!(" {conn_dot} "),
            Style::default().bg(Color::Blue).fg(conn_color),
        ),
        Span::styled(
            format!("Zone Board  |  Your channel: {channel_name}  ({})", &channel_hex[..16]),
            Style::default().bg(Color::Blue).fg(Color::White).add_modifier(Modifier::BOLD),
        ),
    ];
    if let Some(s) = sync_span {
        spans.push(s);
    }
    frame.render_widget(Paragraph::new(Line::from(spans)), area);
}

fn render_content(frame: &mut Frame, app: &App, area: ratatui::layout::Rect) {
    if app.thread_view.is_some() {
        let cols = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Length(22), Constraint::Percentage(45), Constraint::Min(0)])
            .split(area);
        render_channels(frame, app, cols[0]);
        render_messages(frame, app, cols[1]);
        render_thread(frame, app, cols[2]);
    } else {
        let cols = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Length(22), Constraint::Min(0)])
            .split(area);
        render_channels(frame, app, cols[0]);
        render_messages(frame, app, cols[1]);
    }
}

fn render_channels(frame: &mut Frame, app: &App, area: ratatui::layout::Rect) {
    use ratatui::text::{Line, Span};

    let focused = app.focus == Focus::Channels;
    let items: Vec<ListItem> = app
        .channels
        .iter()
        .enumerate()
        .map(|(i, ch)| {
            let selected = i == app.selected;
            let prefix = if selected { "▶ " } else { "  " };
            let sync_tag = if app.syncing.contains(&ch.id) { "⟳ " } else { "" };
            let unread = app.unread_count(ch.id);

            if unread > 0 && !selected {
                let label = format!("{prefix}{sync_tag}{} ", ch.label);
                let badge = format!("[{unread}]");
                Line::from(vec![
                    Span::styled(label, Style::default().fg(Color::White)),
                    Span::styled(badge, Style::default().fg(Color::Black).bg(Color::Yellow).add_modifier(Modifier::BOLD)),
                ]).into()
            } else {
                let label = format!("{prefix}{sync_tag}{}", ch.label);
                let style = if selected && focused {
                    Style::default().fg(Color::Yellow).add_modifier(Modifier::BOLD)
                } else if selected {
                    Style::default().fg(Color::White).add_modifier(Modifier::BOLD)
                } else {
                    Style::default().fg(Color::White)
                };
                ListItem::new(label).style(style)
            }
        })
        .collect();

    let border_color = if focused { Color::Yellow } else { Color::Cyan };
    let list = List::new(items).block(
        Block::default()
            .borders(Borders::ALL)
            .title(" Channels ")
            .style(Style::default().fg(border_color)),
    );
    frame.render_widget(list, area);
}

fn render_messages(frame: &mut Frame, app: &App, area: ratatui::layout::Rect) {
    let selected_ch = &app.channels[app.selected];
    let title = format!(" {} ", selected_ch.label);

    let msgs = app.messages.get(&selected_ch.id);
    let inner_height = area.height.saturating_sub(2) as usize;

    let all_msgs: Vec<_> = msgs.map(|m| m.iter().collect::<Vec<_>>()).unwrap_or_default();
    let total = all_msgs.len();

    // Which absolute index is selected (counting from bottom)
    let selected_abs = total.saturating_sub(1 + app.msg_selected);
    let visible_start = total.saturating_sub(inner_height);

    let all_items: Vec<ListItem> = all_msgs
        .iter()
        .enumerate()
        .map(|(abs_idx, msg)| {
            let display = display_text(&msg.text);
            let reply_badge = msg.block_id
                .map(|id| app.reply_count(id))
                .filter(|&n| n > 0)
                .map(|n| format!(" [{}↩]", n))
                .unwrap_or_default();

            let is_selected = app.focus != Focus::Channels && abs_idx == selected_abs;
            let base_style = if msg.failed {
                Style::default().fg(Color::Red)
            } else if msg.pending {
                Style::default().fg(Color::DarkGray)
            } else {
                Style::default().fg(Color::White)
            };
            let style = if is_selected {
                base_style.bg(Color::DarkGray).add_modifier(Modifier::BOLD)
            } else {
                base_style
            };

            let line = if msg.failed {
                format!("  {}  ✗ {}{} (failed)", msg.timestamp, display, reply_badge)
            } else if msg.pending {
                format!("  {}  {} (pending…){}", msg.timestamp, display, reply_badge)
            } else {
                format!("  {}  {}{}", msg.timestamp, display, reply_badge)
            };
            ListItem::new(line).style(style)
        })
        .collect();

    let visible: Vec<ListItem> = if all_items.len() > inner_height {
        all_items[visible_start..].to_vec()
    } else {
        all_items
    };

    let placeholder: Vec<ListItem> = if visible.is_empty() {
        vec![ListItem::new("  No messages yet.").style(Style::default().fg(Color::DarkGray))]
    } else {
        visible
    };

    let focused = app.focus == Focus::Messages;
    let border_color = if focused { Color::Yellow } else { Color::Cyan };
    let nav_hint = if focused { " [↑↓ select · Enter thread · Tab] " } else { "" };
    let full_title = format!("{title}{nav_hint}");

    let list = List::new(placeholder).block(
        Block::default()
            .borders(Borders::ALL)
            .title(full_title)
            .style(Style::default().fg(border_color)),
    );
    frame.render_widget(list, area);
}

fn render_thread(frame: &mut Frame, app: &App, area: ratatui::layout::Rect) {
    use ratatui::text::{Line, Span};

    let Some(parent_id) = app.thread_view else { return };

    // Find parent message text for the header
    let parent_preview = app.channels.iter()
        .flat_map(|ch| app.messages.get(&ch.id).into_iter().flatten())
        .find(|m| m.block_id == Some(parent_id))
        .map(|m| display_text(&m.text))
        .unwrap_or_else(|| "…".to_string());

    let inner_height = area.height.saturating_sub(4) as usize; // border(2) + header(1) + separator(1)

    let replies = app.thread_replies.get(&parent_id);
    let reply_items: Vec<ListItem> = replies
        .map(|bucket| {
            bucket.iter().map(|msg| {
                let display = display_text(&msg.text);
                if msg.failed {
                    ListItem::new(format!("  {}  ✗ {} (failed)", msg.timestamp, display))
                        .style(Style::default().fg(Color::Red))
                } else if msg.pending {
                    ListItem::new(format!("  {}  {} (sending…)", msg.timestamp, display))
                        .style(Style::default().fg(Color::DarkGray))
                } else {
                    ListItem::new(format!("  {}  {}", msg.timestamp, display))
                        .style(Style::default().fg(Color::White))
                }
            }).collect::<Vec<_>>()
        })
        .unwrap_or_default();

    let visible_replies: Vec<ListItem> = if reply_items.len() > inner_height {
        reply_items[reply_items.len() - inner_height..].to_vec()
    } else {
        reply_items
    };

    let placeholder: Vec<ListItem> = if visible_replies.is_empty() {
        vec![ListItem::new("  No replies yet. Type a reply below.").style(Style::default().fg(Color::DarkGray))]
    } else {
        visible_replies
    };

    // Truncate parent preview to fit
    let max_preview = area.width.saturating_sub(6) as usize;
    let preview_str = if parent_preview.chars().count() > max_preview {
        format!("{}…", &parent_preview[..parent_preview.char_indices().nth(max_preview).map(|(i,_)| i).unwrap_or(parent_preview.len())])
    } else {
        parent_preview
    };

    let focused = app.focus == Focus::Thread;
    let border_color = if focused { Color::Yellow } else { Color::Cyan };

    // Build the block with a "re: …" subtitle as the title
    let title = format!(" Thread: {} ", &preview_str);
    let block = Block::default()
        .borders(Borders::ALL)
        .title(title)
        .style(Style::default().fg(border_color));

    let inner = block.inner(area);
    frame.render_widget(block, area);

    // Header line showing parent excerpt + separator
    let header_area = ratatui::layout::Rect {
        x: inner.x,
        y: inner.y,
        width: inner.width,
        height: 2.min(inner.height),
    };
    let list_area = ratatui::layout::Rect {
        x: inner.x,
        y: inner.y + 2.min(inner.height),
        width: inner.width,
        height: inner.height.saturating_sub(2),
    };

    let header = Paragraph::new(Line::from(vec![
        Span::styled("  ↳ ", Style::default().fg(Color::DarkGray)),
        Span::styled(preview_str, Style::default().fg(Color::Yellow).add_modifier(Modifier::ITALIC)),
    ]));
    frame.render_widget(header, header_area);

    let list = List::new(placeholder);
    frame.render_widget(list, list_area);
}

fn render_bottom(frame: &mut Frame, app: &App, area: ratatui::layout::Rect) {
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(1),
            Constraint::Length(1),
            Constraint::Length(1),
        ])
        .split(area);

    // Status line
    let is_error = app.status.contains("error")
        || app.status.contains("timed out")
        || app.status.contains("invalid")
        || app.status.contains("cannot");
    let status_style = if is_error {
        Style::default().fg(Color::Red)
    } else {
        Style::default().fg(Color::Green)
    };
    let status = Paragraph::new(format!(" {}", app.status)).style(status_style);
    frame.render_widget(status, rows[0]);

    // Input line — show thread indicator when in Thread focus
    let prompt = if app.focus == Focus::Thread {
        let preview = app.thread_view
            .and_then(|id| {
                app.channels.iter()
                    .flat_map(|ch| app.messages.get(&ch.id).into_iter().flatten())
                    .find(|m| m.block_id == Some(id))
                    .map(|m| display_text(&m.text))
            })
            .unwrap_or_default();
        let short = if preview.chars().count() > 20 {
            format!("{}…", &preview[..preview.char_indices().nth(20).map(|(i,_)| i).unwrap_or(preview.len())])
        } else {
            preview
        };
        format!(" ↳ [{}] > {}▌", short, app.input)
    } else {
        format!(" > {}▌", app.input)
    };
    let input = Paragraph::new(prompt).style(Style::default().fg(Color::Yellow));
    frame.render_widget(input, rows[1]);

    // Help line — context-sensitive
    let help_text = match app.focus {
        Focus::Channels => " Tab: messages  ↑↓ channel  Enter publish  /sub /unsub /resync /upload /quit",
        Focus::Messages => " Tab: back  Esc: channels  ↑↓ select msg  Enter: open thread  type to compose",
        Focus::Thread   => " Esc: close thread  Enter: send reply  Tab: back to channels",
    };
    let help = Paragraph::new(help_text).style(Style::default().fg(Color::DarkGray));
    frame.render_widget(help, rows[2]);
}
