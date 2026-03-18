use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use zellij_tile::prelude::*;

const DEFAULT_STATE_FILE: &str = "opencode-sessions.json";
const DEFAULT_CACHE_FILE: &str = "popup-cache.json";
const DEFAULT_POLL_SECONDS: f64 = 1.0;
#[derive(Clone, Debug, Deserialize, Serialize)]
struct SessionEntry {
    pane_id: u32,
    pane_title: String,
    tab_position: usize,
    tab_name: String,
    status: String,
    cwd: Option<String>,
    updated_at_ms: u64,
}

#[derive(Default)]
struct State {
    current_session_name: Option<String>,
    pane_manifest: Option<PaneManifest>,
    tabs: Vec<TabInfo>,
    entries: Vec<SessionEntry>,
    selected_index: usize,
    permissions_granted: bool,
    state_dir: Option<PathBuf>,
    state_file_name: String,
    host_dir_ready: bool,
    status_message: Option<String>,
}

#[derive(Debug, Deserialize)]
struct StoredState {
    #[serde(default)]
    panes: BTreeMap<String, StoredPane>,
}

#[derive(Clone)]
struct PaneDetails {
    pane_title: String,
    tab_position: usize,
    tab_name: String,
    terminal_command: Option<String>,
}

#[derive(Debug, Deserialize)]
struct StoredPane {
    pane_id: u32,
    session_name: String,
    status: String,
    agent: String,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    updated_at_ms: u64,
}

register_plugin!(State);

impl ZellijPlugin for State {
    fn load(&mut self, configuration: BTreeMap<String, String>) {
        self.state_dir = configuration.get("state_dir").map(PathBuf::from);
        self.state_file_name = configuration
            .get("state_file")
            .cloned()
            .unwrap_or_else(|| DEFAULT_STATE_FILE.to_string());

        subscribe(&[
            EventType::ModeUpdate,
            EventType::TabUpdate,
            EventType::PaneUpdate,
            EventType::Key,
            EventType::Timer,
            EventType::PermissionRequestResult,
            EventType::HostFolderChanged,
            EventType::FailedToChangeHostFolder,
        ]);
        request_permission(&[
            PermissionType::ReadApplicationState,
            PermissionType::ChangeApplicationState,
            PermissionType::FullHdAccess,
        ]);
        set_selectable(true);
        set_timeout(DEFAULT_POLL_SECONDS);
        self.status_message = Some("Waiting for plugin permissions...".to_string());
    }

    fn update(&mut self, event: Event) -> bool {
        match event {
            Event::ModeUpdate(mode_info) => {
                self.current_session_name = mode_info.session_name;
                self.refresh_entries();
                true
            }
            Event::TabUpdate(tabs) => {
                self.tabs = tabs;
                self.refresh_entries();
                true
            }
            Event::PaneUpdate(pane_manifest) => {
                self.pane_manifest = Some(pane_manifest);
                self.refresh_entries();
                true
            }
            Event::Timer(_) => {
                set_timeout(DEFAULT_POLL_SECONDS);
                self.refresh_entries();
                true
            }
            Event::PermissionRequestResult(PermissionStatus::Granted) => {
                self.permissions_granted = true;
                self.host_dir_ready = false;
                if let Some(state_dir) = &self.state_dir {
                    change_host_folder(state_dir.clone());
                    self.status_message = Some("Connecting to session state store...".to_string());
                } else {
                    self.status_message =
                        Some("Missing state_dir plugin configuration".to_string());
                }
                self.refresh_entries();
                true
            }
            Event::PermissionRequestResult(PermissionStatus::Denied) => {
                self.permissions_granted = false;
                self.host_dir_ready = false;
                self.status_message = Some(
                    "Permission denied. Grant access to read state and focus panes.".to_string(),
                );
                true
            }
            Event::HostFolderChanged(_) => {
                self.host_dir_ready = true;
                self.restore_cached_entries();
                self.refresh_entries();
                true
            }
            Event::FailedToChangeHostFolder(error) => {
                self.host_dir_ready = false;
                self.status_message = Some(match error {
                    Some(error) => format!("Failed to access state directory: {}", error),
                    None => "Failed to access state directory".to_string(),
                });
                true
            }
            Event::Key(key) => self.handle_key(key),
            _ => false,
        }
    }

    fn render(&mut self, rows: usize, cols: usize) {
        let rows = rows.max(8);
        let cols = cols.max(40);

        let session_name = self
            .current_session_name
            .as_deref()
            .unwrap_or("unknown session");
        let subtitle = format!(
            "Session {}  {} tracked pane{}",
            session_name,
            self.entries.len(),
            if self.entries.len() == 1 { "" } else { "s" }
        );
        print_text_with_coordinates(
            Text::new(truncate(&subtitle, cols.saturating_sub(2))).color_range(0, 8..),
            0,
            0,
            Some(cols),
            Some(1),
        );

        let mut header_chips = vec![
            chip(
                &format!(" {} ", status_summary("working", &self.entries)),
                false,
            ),
            chip(
                &format!(" {} ", status_summary("asking_permissions", &self.entries)),
                false,
            ),
            chip(
                &format!(
                    " {} ",
                    status_summary("waiting_user_answers", &self.entries)
                ),
                false,
            ),
            chip(
                &format!(" {} ", status_summary("waiting_user_input", &self.entries)),
                false,
            ),
        ];
        if self.entries.is_empty() {
            header_chips.push(chip(" no sessions ", true));
        }
        print!(
            "{}",
            serialize_ribbon_line_with_coordinates(header_chips, 0, 1, None, Some(1))
        );

        let footer_y = rows.saturating_sub(1);
        render_footer(footer_y, cols);

        let body_y = 3;
        let body_height = rows.saturating_sub(body_y + 1);

        if let Some(message) = &self.status_message {
            print_text_with_coordinates(
                Text::new(truncate(message, cols.saturating_sub(2)))
                    .color_range(1, ..)
                    .opaque(),
                0,
                body_y,
                Some(cols),
                Some(1),
            );
        }

        if self.entries.is_empty() {
            let empty = vec![
                NestedListItem::new("Start an OpenCode pane in this Zellij session to populate this view")
                .color_range(0, 0..6),
                NestedListItem::new("Live states appear automatically when the bundled OpenCode plugin is installed")
                    .indent(1)
                    .color_range(2, 43..59),
            ];
            print_nested_list_with_coordinates(empty, 0, body_y + 2, Some(cols), Some(body_height));
            return;
        }

        let visible_rows = body_height.max(3) / 2;
        let start = scroll_offset(self.selected_index, visible_rows, self.entries.len());
        let end = (start + visible_rows.max(1)).min(self.entries.len());
        let mut items = Vec::new();
        for (visible_index, entry) in self.entries[start..end].iter().enumerate() {
            let actual_index = start + visible_index;
            let is_selected = actual_index == self.selected_index;
            items.push(primary_item(entry, is_selected, cols));
            items.push(secondary_item(entry, is_selected, cols));
        }
        print_nested_list_with_coordinates(items, 0, body_y, Some(cols), Some(body_height));
    }
}

impl State {
    fn handle_key(&mut self, key: KeyWithModifier) -> bool {
        if key.has_no_modifiers() {
            match key.bare_key {
                BareKey::Down | BareKey::Char('j') => {
                    self.move_selection(1);
                    return true;
                }
                BareKey::Up | BareKey::Char('k') => {
                    self.move_selection(-1);
                    return true;
                }
                BareKey::Enter => {
                    if let Some(entry) = self.entries.get(self.selected_index) {
                        focus_terminal_pane(entry.pane_id, false);
                        close_self();
                    }
                    return false;
                }
                BareKey::Esc | BareKey::Char('q') => {
                    close_self();
                    return false;
                }
                _ => {}
            }
        }
        false
    }

    fn move_selection(&mut self, delta: isize) {
        if self.entries.is_empty() {
            self.selected_index = 0;
            return;
        }
        let len = self.entries.len() as isize;
        let current = self.selected_index as isize;
        let next = (current + delta).clamp(0, len - 1);
        self.selected_index = next as usize;
    }

    fn refresh_entries(&mut self) {
        if !self.permissions_granted || !self.host_dir_ready {
            return;
        }

        let Some(session_name) = self.current_session_name.clone() else {
            if self.entries.is_empty() {
                self.restore_cached_entries();
            }
            if self.entries.is_empty() {
                self.status_message = Some("Waiting for Zellij session metadata...".to_string());
            } else {
                self.status_message = None;
            }
            return;
        };

        let Some(pane_manifest) = &self.pane_manifest else {
            self.status_message = Some("Waiting for pane metadata...".to_string());
            return;
        };

        let tracked_panes = match self.read_state_entries() {
            Ok(state) => state,
            Err(error) => {
                self.entries.clear();
                self.selected_index = 0;
                self.status_message = Some(error);
                return;
            }
        };

        let mut tab_names = HashMap::new();
        for tab in &self.tabs {
            tab_names.insert(tab.position, tab.name.clone());
        }

        let mut pane_lookup: HashMap<u32, PaneDetails> = HashMap::new();
        for (tab_position, panes) in &pane_manifest.panes {
            for pane in panes {
                if pane.is_plugin || pane.exited {
                    continue;
                }
                let default_tab_name = format!("Tab {}", tab_position + 1);
                let terminal_command = pane.terminal_command.clone();
                pane_lookup.insert(
                    pane.id,
                    PaneDetails {
                        pane_title: clean_pane_title(&pane.title, terminal_command.as_deref()),
                        tab_position: *tab_position,
                        tab_name: tab_names
                            .get(tab_position)
                            .cloned()
                            .unwrap_or(default_tab_name),
                        terminal_command,
                    },
                );
            }
        }

        let previous_selected = self
            .entries
            .get(self.selected_index)
            .map(|entry| entry.pane_id);
        let mut entries = Vec::new();
        let mut latest_tracked = HashMap::new();
        for tracked in &tracked_panes {
            if tracked.session_name != session_name || !is_supported_agent(&tracked.agent) {
                continue;
            }
            let Some(details) = pane_lookup.get(&tracked.pane_id) else {
                continue;
            };
            if !is_agent_pane(details) {
                continue;
            }
            latest_tracked
                .entry(tracked.pane_id)
                .and_modify(|current: &mut &StoredPane| {
                    if tracked.updated_at_ms > current.updated_at_ms {
                        *current = tracked;
                    }
                })
                .or_insert(tracked);
        }

        let mut seen_panes = HashMap::new();
        for tracked in latest_tracked.into_values() {
            let Some(details) = pane_lookup.get(&tracked.pane_id) else {
                continue;
            };
            seen_panes.insert(tracked.pane_id, true);
            entries.push(SessionEntry {
                pane_id: tracked.pane_id,
                pane_title: details.pane_title.clone(),
                tab_position: details.tab_position,
                tab_name: details.tab_name.clone(),
                status: tracked.status.clone(),
                cwd: tracked.cwd.clone(),
                updated_at_ms: tracked.updated_at_ms,
            });
        }

        for (pane_id, details) in &pane_lookup {
            if seen_panes.contains_key(pane_id) {
                continue;
            }
            if !is_agent_pane(details) {
                continue;
            }
            entries.push(SessionEntry {
                pane_id: *pane_id,
                pane_title: details.pane_title.clone(),
                tab_position: details.tab_position,
                tab_name: details.tab_name.clone(),
                status: "waiting_user_input".to_string(),
                cwd: None,
                updated_at_ms: 0,
            });
        }

        entries.sort_by(|left, right| {
            left.tab_position
                .cmp(&right.tab_position)
                .then(left.pane_title.cmp(&right.pane_title))
                .then(right.updated_at_ms.cmp(&left.updated_at_ms))
        });

        self.entries = entries;
        if self.entries.is_empty() {
            self.selected_index = 0;
        } else if let Some(selected_pane_id) = previous_selected {
            if let Some(index) = self
                .entries
                .iter()
                .position(|entry| entry.pane_id == selected_pane_id)
            {
                self.selected_index = index;
            } else {
                self.selected_index = self.selected_index.min(self.entries.len() - 1);
            }
        } else {
            self.selected_index = self.selected_index.min(self.entries.len() - 1);
        }

        self.status_message = None;
        self.persist_cached_entries();
    }

    fn restore_cached_entries(&mut self) {
        let cache_path = Self::cache_path();
        let contents = match fs::read_to_string(&cache_path) {
            Ok(contents) => contents,
            Err(_) => return,
        };
        let cached_entries = match serde_json::from_str::<Vec<SessionEntry>>(&contents) {
            Ok(entries) => entries,
            Err(_) => return,
        };

        self.entries = cached_entries;
        if self.entries.is_empty() {
            self.selected_index = 0;
        } else {
            self.selected_index = self.selected_index.min(self.entries.len() - 1);
        }
        self.status_message = None;
    }

    fn persist_cached_entries(&self) {
        let cache_path = Self::cache_path();
        let contents = match serde_json::to_string(&self.entries) {
            Ok(contents) => contents,
            Err(_) => return,
        };
        let _ = fs::write(cache_path, contents);
    }

    fn cache_path() -> PathBuf {
        Path::new("/host").join(DEFAULT_CACHE_FILE)
    }

    fn read_state_entries(&self) -> Result<Vec<StoredPane>, String> {
        let mut entries = Vec::new();

        let pane_dir = Path::new("/host").join("panes");
        if pane_dir.exists() {
            let dir_entries = fs::read_dir(&pane_dir)
                .map_err(|error| format!("Failed to read {}: {}", pane_dir.display(), error))?;
            for entry in dir_entries {
                let entry = entry.map_err(|error| {
                    format!("Failed to iterate {}: {}", pane_dir.display(), error)
                })?;
                let path = entry.path();
                if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
                    continue;
                }
                let contents = fs::read_to_string(&path)
                    .map_err(|error| format!("Failed to read {}: {}", path.display(), error))?;
                let tracked = serde_json::from_str::<StoredPane>(&contents)
                    .map_err(|error| format!("Failed to parse {}: {}", path.display(), error))?;
                entries.push(tracked);
            }
        }

        let legacy_state = Path::new("/host").join(&self.state_file_name);
        if entries.is_empty() && legacy_state.exists() {
            let contents = fs::read_to_string(&legacy_state)
                .map_err(|error| format!("Failed to read {}: {}", legacy_state.display(), error))?;
            let tracked = serde_json::from_str::<StoredState>(&contents).map_err(|error| {
                format!("Failed to parse {}: {}", legacy_state.display(), error)
            })?;
            entries.extend(tracked.panes.into_values());
        }

        Ok(entries)
    }
}

fn status_icon(status: &str) -> &'static str {
    match status {
        "working" => "RUN",
        "waiting_user_answers" => "ASK",
        "asking_permissions" => "PERM",
        "waiting_user_input" => "DONE",
        _ => "IDLE",
    }
}

fn status_color_index(status: &str) -> usize {
    match status {
        "working" => 2,
        "waiting_user_answers" => 0,
        "asking_permissions" => 1,
        "waiting_user_input" => 3,
        _ => 0,
    }
}

fn chip(label: &str, selected: bool) -> Text {
    let mut text = Text::new(label).opaque();
    if selected {
        text = text.selected();
    }
    text.color_range(0, 1..label.len().saturating_sub(1))
}

fn render_footer(y: usize, cols: usize) {
    let prefix = "Help:";
    let segments = [
        ("<Enter>", "focus pane"),
        ("<j/k>", "move"),
        ("<q>", "close"),
    ];

    let mut line = String::from(prefix);
    let mut highlight_ranges = Vec::new();
    let prefix_len = prefix.chars().count();
    for (index, (key, action)) in segments.iter().enumerate() {
        line.push(' ');
        let start = line.chars().count();
        line.push_str(key);
        let end = line.chars().count();
        highlight_ranges.push((start, end));
        line.push_str(" - ");
        line.push_str(action);
        if index + 1 < segments.len() {
            line.push_str(", ");
        }
    }

    let rendered = truncate(&line, cols.saturating_sub(1));
    let rendered_len = rendered.chars().count();
    let mut text = Text::new(rendered).color_range(0, 0..prefix_len.min(rendered_len));
    for (start, end) in highlight_ranges {
        if start >= rendered_len {
            continue;
        }
        text = text.color_range(1, start..end.min(rendered_len));
    }
    print_text_with_coordinates(text, 0, y, Some(cols), Some(1));
}

fn status_summary(status: &str, entries: &[SessionEntry]) -> String {
    let count = entries
        .iter()
        .filter(|entry| entry.status == status)
        .count();
    format!("{} {}", status_icon(status), count)
}

fn is_supported_agent(agent: &str) -> bool {
    matches!(agent, "opencode" | "claude")
}

fn is_agent_pane(details: &PaneDetails) -> bool {
    let title = details.pane_title.to_ascii_lowercase();
    if title.contains("opencode") || title.contains("claude") {
        return true;
    }
    details
        .terminal_command
        .as_deref()
        .map(is_agent_command)
        .unwrap_or(false)
}

fn is_agent_command(command: &str) -> bool {
    let command = command.to_ascii_lowercase();
    command.contains("opencode") || command.contains("claude")
}

fn clean_pane_title(title: &str, terminal_command: Option<&str>) -> String {
    let cleaned = title.strip_prefix("OC | ").unwrap_or(title).trim();
    if !cleaned.is_empty() {
        return cleaned.to_string();
    }

    inferred_agent_name(terminal_command)
        .unwrap_or_else(|| title.trim())
        .to_string()
}

fn inferred_agent_name(command: Option<&str>) -> Option<&'static str> {
    let command = command?.to_ascii_lowercase();
    if command.contains("opencode") {
        Some("OpenCode")
    } else if command.contains("claude") {
        Some("Claude")
    } else {
        None
    }
}

fn primary_item(entry: &SessionEntry, is_selected: bool, width: usize) -> NestedListItem {
    let tab = format!("[{}]", entry.tab_name);
    let icon = status_icon(&entry.status);
    let line = truncate(
        &format!("{}  {}  {}", icon, entry.pane_title, tab),
        width.saturating_sub(1),
    );
    let icon_end = icon.len().min(line.len());
    let title_start = (icon_end + 2).min(line.len());
    let title_end = line.find("  [").unwrap_or(line.len());
    let mut item = NestedListItem::new(line)
        .color_range(status_color_index(&entry.status), 0..icon_end)
        .color_range(2, title_start..title_end)
        .color_range(0, title_end..);
    if is_selected {
        item = item.selected().opaque();
    }
    item
}

fn secondary_item(entry: &SessionEntry, is_selected: bool, width: usize) -> NestedListItem {
    let cwd = entry.cwd.as_deref().unwrap_or("No working directory");
    let line = truncate(
        &format!("{}  pane {}", cwd, entry.pane_id),
        width.saturating_sub(3),
    );
    let split = line.rfind("  pane ").unwrap_or(line.len());
    let mut item = NestedListItem::new(line)
        .indent(1)
        .color_range(0, 0..split)
        .color_range(3, split..);
    if is_selected {
        item = item.selected().opaque();
    }
    item
}

fn scroll_offset(selected_index: usize, visible_rows: usize, total_items: usize) -> usize {
    if visible_rows == 0 || total_items <= visible_rows {
        return 0;
    }
    if selected_index >= visible_rows {
        selected_index + 1 - visible_rows
    } else {
        0
    }
}

fn truncate(input: &str, width: usize) -> String {
    if input.chars().count() <= width {
        return input.to_string();
    }
    let mut result = String::new();
    for ch in input.chars().take(width.saturating_sub(3)) {
        result.push(ch);
    }
    result.push_str("...");
    result
}
