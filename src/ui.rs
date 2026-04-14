use ratatui::{
    Frame,
    layout::{Constraint, Direction, Layout},
    style::{Color, Modifier, Style},
    widgets::{Block, Borders, List, ListItem, Paragraph},
};

use crate::app::App;

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
    use ratatui::text::{Line, Span};
    let line = Line::from(vec![
        Span::styled(
            format!(" {conn_dot} "),
            Style::default().bg(Color::Blue).fg(conn_color),
        ),
        Span::styled(
            format!("Zone Board  |  Your channel: {channel_name}  ({})", &channel_hex[..16]),
            Style::default().bg(Color::Blue).fg(Color::White).add_modifier(Modifier::BOLD),
        ),
    ]);
    frame.render_widget(Paragraph::new(line), area);
}

fn render_content(frame: &mut Frame, app: &App, area: ratatui::layout::Rect) {
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Length(22), Constraint::Min(0)])
        .split(area);

    render_channels(frame, app, cols[0]);
    render_messages(frame, app, cols[1]);
}

fn render_channels(frame: &mut Frame, app: &App, area: ratatui::layout::Rect) {
    let items: Vec<ListItem> = app
        .channels
        .iter()
        .enumerate()
        .map(|(i, ch)| {
            let prefix = if i == app.selected { "▶ " } else { "  " };
            let sync_tag = if app.syncing.contains(&ch.id) { " ⟳" } else { "" };
            let label = format!("{prefix}{}{sync_tag}", ch.label);
            let style = if i == app.selected {
                Style::default()
                    .fg(Color::Yellow)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(Color::White)
            };
            ListItem::new(label).style(style)
        })
        .collect();

    let list = List::new(items).block(
        Block::default()
            .borders(Borders::ALL)
            .title(" Channels ")
            .style(Style::default().fg(Color::Cyan)),
    );
    frame.render_widget(list, area);
}

fn render_messages(frame: &mut Frame, app: &App, area: ratatui::layout::Rect) {
    let selected = &app.channels[app.selected];
    let title = format!(" {} ", selected.label);

    let msgs = app.messages.get(&selected.id);

    // Show most recent messages that fit in the available height.
    // Border takes 2 rows; each message is 1 row.
    let inner_height = area.height.saturating_sub(2) as usize;

    let all_items: Vec<ListItem> = msgs
        .map(|m| {
            m.iter()
                .map(|msg| {
                    if msg.pending {
                        ListItem::new(format!("  {}  {} (pending…)", msg.timestamp, msg.text))
                            .style(Style::default().fg(Color::DarkGray))
                    } else {
                        ListItem::new(format!("  {}  {}", msg.timestamp, msg.text))
                            .style(Style::default().fg(Color::White))
                    }
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    // Show the last `inner_height` messages so new ones scroll into view
    let visible: Vec<ListItem> = if all_items.len() > inner_height {
        all_items[all_items.len() - inner_height..].to_vec()
    } else {
        all_items
    };

    let placeholder: Vec<ListItem> = if visible.is_empty() {
        vec![ListItem::new("  No messages yet.").style(Style::default().fg(Color::DarkGray))]
    } else {
        visible
    };

    let list = List::new(placeholder).block(
        Block::default()
            .borders(Borders::ALL)
            .title(title)
            .style(Style::default().fg(Color::Cyan)),
    );
    frame.render_widget(list, area);
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

    // Input line
    let input = Paragraph::new(format!(" > {}▌", app.input))
        .style(Style::default().fg(Color::Yellow));
    frame.render_widget(input, rows[1]);

    // Help line
    let help = Paragraph::new(
        " ↑↓ select channel  Enter publish  /sub <channel-id>  /unsub  /quit  Ctrl+C",
    )
    .style(Style::default().fg(Color::DarkGray));
    frame.render_widget(help, rows[2]);
}
