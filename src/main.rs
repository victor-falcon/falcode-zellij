use std::collections::{BTreeMap, HashMap};
use std::fmt::Write as _;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use zellij_tile::prelude::*;

const DEFAULT_STATE_FILE: &str = "opencode-sessions.json";
const DEFAULT_CACHE_FILE: &str = "popup-cache.json";
const DETECTION_SCRIPT_FILE: &str = "detect-active-opencode.sh";
const DETECTION_INPUT_FILE: &str = "detect-active-opencode.snapshot.tsv";
const DETECTION_COMMAND_KIND: &str = "detect_active_opencode";
const DEFAULT_POLL_SECONDS: f64 = 1.0;
const SESSION_GRACE_MS: u64 = 10_000;
const ENTRY_MISSING_GRACE_MS: u64 = 5_000;
/// State files older than this are considered stale for non-current sessions.
/// The companion falcode.js plugin re-writes files every 60 s (heartbeat), so
/// 3 minutes gives plenty of margin.
const MAX_PANE_STATE_AGE_MS: u64 = 3 * 60 * 1000;

#[derive(Clone, Debug, Deserialize, Serialize)]
struct SessionEntry {
    session_name: String,
    pane_id: u32,
    pane_title: String,
    tab_position: usize,
    tab_name: String,
    status: String,
    cwd: Option<String>,
    updated_at_ms: u64,
}

#[derive(Debug, Deserialize, Serialize)]
struct CachedEntries {
    generated_at_ms: u64,
    session_names: Vec<String>,
    entries: Vec<SessionEntry>,
}

#[derive(Default)]
struct State {
    current_session_name: Option<String>,
    sessions: Vec<SessionInfo>,
    entries: Vec<SessionEntry>,
    selected_index: usize,
    detection_request_serial: u64,
    pending_detection_request_id: Option<u64>,
    detection_refresh_queued: bool,
    permissions_granted: bool,
    state_dir: Option<PathBuf>,
    state_file_name: String,
    host_dir_ready: bool,
    status_message: Option<String>,
    /// Last time each session name appeared in a SessionUpdate, used to
    /// smooth over Zellij's intermittent session-list flicker.
    session_last_seen: HashMap<String, u64>,
    entry_last_seen: HashMap<(String, u32), u64>,
    pane_cache_by_session: HashMap<String, HashMap<u32, PaneDetails>>,
    stable_pane_mapping: HashMap<String, (String, u32)>,
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

#[derive(Clone, Debug, Deserialize)]
struct StoredPane {
    #[serde(default)]
    stable_id: Option<String>,
    pane_id: u32,
    session_name: String,
    status: String,
    agent: String,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    updated_at_ms: u64,
}

#[derive(Clone)]
struct DisplayRow {
    item: NestedListItem,
    entry_index: Option<usize>,
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
            EventType::SessionUpdate,
            EventType::RunCommandResult,
            EventType::Key,
            EventType::Timer,
            EventType::PermissionRequestResult,
            EventType::HostFolderChanged,
            EventType::FailedToChangeHostFolder,
        ]);
        request_permission(&[
            PermissionType::ReadApplicationState,
            PermissionType::ChangeApplicationState,
            PermissionType::RunCommands,
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
                if let Some(current_session_name) = self.current_session_name.as_deref() {
                    if let Some(session) = self
                        .sessions
                        .iter_mut()
                        .find(|session| session.name == current_session_name)
                    {
                        session.tabs = tabs;
                    }
                }
                self.refresh_entries();
                true
            }
            Event::PaneUpdate(pane_manifest) => {
                if let Some(current_session_name) = self.current_session_name.as_deref() {
                    if let Some(session) = self
                        .sessions
                        .iter_mut()
                        .find(|session| session.name == current_session_name)
                    {
                        session.panes = pane_manifest;
                    }
                }
                self.refresh_entries();
                true
            }
            Event::SessionUpdate(session_infos, _) => {
                let now = now_ms();
                for session in &session_infos {
                    self.session_last_seen.insert(session.name.clone(), now);
                }
                self.sessions = session_infos;
                self.refresh_entries();
                true
            }
            Event::RunCommandResult(exit_code, stdout, stderr, context) => {
                self.handle_run_command_result(exit_code, stdout, stderr, context)
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
                self.pending_detection_request_id = None;
                self.detection_refresh_queued = false;
                self.status_message = Some(
                    "Permission denied. Grant access to read state and focus panes.".to_string(),
                );
                true
            }
            Event::HostFolderChanged(_) => {
                self.host_dir_ready = true;
                self.pending_detection_request_id = None;
                self.detection_refresh_queued = false;
                self.refresh_entries();
                true
            }
            Event::FailedToChangeHostFolder(error) => {
                self.host_dir_ready = false;
                self.pending_detection_request_id = None;
                self.detection_refresh_queued = false;
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
        let tracked_sessions = tracked_session_count(&self.entries);
        let subtitle = format!(
            "{} tracked pane{} across {} session{}  current: {}",
            self.entries.len(),
            if self.entries.len() == 1 { "" } else { "s" },
            tracked_sessions,
            if tracked_sessions == 1 { "" } else { "s" },
            session_name,
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
                NestedListItem::new("Start an OpenCode pane in any Zellij session to populate this view")
                .color_range(0, 0..6),
                NestedListItem::new("Sessions are grouped with the current Zellij session first")
                    .indent(1)
                    .color_range(2, 27..56),
                NestedListItem::new("Live states appear automatically when the bundled OpenCode plugin is installed")
                    .indent(1)
                    .color_range(2, 43..59),
            ];
            print_nested_list_with_coordinates(empty, 0, body_y + 2, Some(cols), Some(body_height));
            return;
        }

        let rows = build_display_rows(&self.entries, session_name, self.selected_index, cols);
        let selected_row = rows
            .iter()
            .position(|row| row.entry_index == Some(self.selected_index))
            .unwrap_or(0);
        let visible_rows = body_height.max(1);
        let header_row = rows[..=selected_row]
            .iter()
            .rposition(|row| row.entry_index.is_none())
            .unwrap_or(0);
        let start = group_scroll_offset(selected_row, header_row, visible_rows, rows.len());
        let end = (start + visible_rows).min(rows.len());
        let items = rows[start..end]
            .iter()
            .map(|row| row.item.clone())
            .collect();
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
                        let is_current_session = self
                            .current_session_name
                            .as_deref()
                            .map(|session_name| session_name == entry.session_name)
                            .unwrap_or(false);
                        if is_current_session {
                            focus_terminal_pane(entry.pane_id, false);
                        } else {
                            switch_session_with_focus(
                                &entry.session_name,
                                Some(entry.tab_position),
                                Some((entry.pane_id, false)),
                            );
                        }
                        close_self();
                    }
                    return false;
                }
                BareKey::Char(c @ '1'..='9') => {
                    let entry_index = (c as usize) - ('1' as usize);
                    if let Some(entry) = self.entries.get(entry_index) {
                        let is_current_session = self
                            .current_session_name
                            .as_deref()
                            .map(|session_name| session_name == entry.session_name)
                            .unwrap_or(false);
                        if is_current_session {
                            focus_terminal_pane(entry.pane_id, false);
                        } else {
                            switch_session_with_focus(
                                &entry.session_name,
                                Some(entry.tab_position),
                                Some((entry.pane_id, false)),
                            );
                        }
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

        if self.sessions.is_empty() {
            self.entries.clear();
            self.selected_index = 0;
            self.pending_detection_request_id = None;
            self.detection_refresh_queued = false;
            self.pane_cache_by_session.clear();
            self.status_message = Some("Waiting for Zellij session metadata...".to_string());
            return;
        }

        let pane_lookup = self.refresh_pane_cache(&self.build_pane_lookup());
        let tracked_panes = self.read_state_entries_resilient();

        if self.start_detection_request(&pane_lookup, &tracked_panes) {
            return;
        }

        let entries = self.detect_entries_from_sources(&pane_lookup, tracked_panes);
        self.apply_entries(entries, None);
    }

    fn handle_run_command_result(
        &mut self,
        exit_code: Option<i32>,
        stdout: Vec<u8>,
        stderr: Vec<u8>,
        context: BTreeMap<String, String>,
    ) -> bool {
        if context.get("kind").map(String::as_str) != Some(DETECTION_COMMAND_KIND) {
            return false;
        }

        let request_id = context
            .get("request_id")
            .and_then(|value| value.parse::<u64>().ok());

        if request_id != self.pending_detection_request_id {
            return true;
        }

        self.pending_detection_request_id = None;

        let parsed_entries = if exit_code == Some(0) {
            String::from_utf8(stdout)
                .ok()
                .and_then(|stdout| serde_json::from_str::<Vec<SessionEntry>>(&stdout).ok())
        } else {
            None
        };

        if let Some(entries) = parsed_entries {
            self.apply_entries(entries, None);
        } else {
            let stderr = String::from_utf8(stderr).unwrap_or_default();
            let message = detection_error_message(exit_code, &stderr);
            let entries = self.detect_entries_locally();
            self.apply_entries(entries, Some(message));
        }

        if self.detection_refresh_queued {
            self.detection_refresh_queued = false;
            self.refresh_entries();
        }

        true
    }

    fn start_detection_request(
        &mut self,
        pane_lookup: &HashMap<(String, u32), PaneDetails>,
        tracked_panes: &[StoredPane],
    ) -> bool {
        if self.pending_detection_request_id.is_some() {
            self.detection_refresh_queued = true;
            return true;
        }

        let state_dir = match &self.state_dir {
            Some(state_dir) => state_dir.clone(),
            None => return false,
        };
        let host_script_path = Path::new("/host").join(DETECTION_SCRIPT_FILE);
        if !host_script_path.exists() {
            return false;
        }

        if self
            .write_detection_snapshot(pane_lookup, tracked_panes)
            .is_err()
        {
            return false;
        }

        let request_id = self.next_detection_request_id();
        let mut env = BTreeMap::new();
        env.insert(
            "FALCODE_CURRENT_SESSION".to_string(),
            self.current_session_name.clone().unwrap_or_default(),
        );
        env.insert("FALCODE_NOW_MS".to_string(), now_ms().to_string());
        env.insert(
            "FALCODE_MAX_PANE_STATE_AGE_MS".to_string(),
            MAX_PANE_STATE_AGE_MS.to_string(),
        );
        env.insert(
            "FALCODE_STATE_DIR".to_string(),
            state_dir.to_string_lossy().into_owned(),
        );
        env.insert(
            "FALCODE_SNAPSHOT_FILE".to_string(),
            state_dir
                .join(DETECTION_INPUT_FILE)
                .to_string_lossy()
                .into_owned(),
        );

        let mut context = BTreeMap::new();
        context.insert("kind".to_string(), DETECTION_COMMAND_KIND.to_string());
        context.insert("request_id".to_string(), request_id.to_string());

        let command = vec![
            "/bin/sh".to_string(),
            state_dir
                .join(DETECTION_SCRIPT_FILE)
                .to_string_lossy()
                .into_owned(),
        ];
        let command_refs = command.iter().map(String::as_str).collect::<Vec<_>>();

        run_command_with_env_variables_and_cwd(&command_refs, env, state_dir, context);
        self.pending_detection_request_id = Some(request_id);
        if self.entries.is_empty() {
            self.status_message = Some("Detecting OpenCode panes...".to_string());
        }
        true
    }

    fn write_detection_snapshot(
        &mut self,
        pane_lookup: &HashMap<(String, u32), PaneDetails>,
        tracked_panes: &[StoredPane],
    ) -> Result<(), ()> {
        let now = now_ms();
        let known_sessions = self.build_known_sessions(now);
        let mut contents = String::new();

        for session_name in known_sessions.keys() {
            let _ = writeln!(contents, "session\t{}", escape_snapshot_field(session_name));
        }

        for ((session_name, pane_id), details) in pane_lookup {
            let terminal_command = details.terminal_command.as_deref().unwrap_or_default();
            let _ = writeln!(
                contents,
                "pane\t{}\t{}\t{}\t{}\t{}\t{}",
                escape_snapshot_field(session_name),
                pane_id,
                details.tab_position,
                escape_snapshot_field(&details.tab_name),
                escape_snapshot_field(&details.pane_title),
                escape_snapshot_field(terminal_command),
            );
        }

        for tracked in tracked_panes {
            let _ = writeln!(
                contents,
                "tracked\t{}\t{}\t{}\t{}\t{}\t{}",
                escape_snapshot_field(&tracked.session_name),
                tracked.pane_id,
                escape_snapshot_field(&tracked.status),
                escape_snapshot_field(&tracked.agent),
                escape_snapshot_field(tracked.cwd.as_deref().unwrap_or_default()),
                tracked.updated_at_ms,
            );
        }

        fs::write(self.detection_snapshot_path(), contents).map_err(|_| ())
    }

    fn next_detection_request_id(&mut self) -> u64 {
        self.detection_request_serial = self.detection_request_serial.saturating_add(1);
        self.detection_request_serial
    }

    fn detect_entries_locally(&mut self) -> Vec<SessionEntry> {
        let pane_lookup = self.refresh_pane_cache(&self.build_pane_lookup());
        let tracked_panes = self.read_state_entries_resilient();
        self.detect_entries_from_sources(&pane_lookup, tracked_panes)
    }

    fn build_pane_lookup(&self) -> HashMap<(String, u32), PaneDetails> {
        let mut pane_lookup: HashMap<(String, u32), PaneDetails> = HashMap::new();
        for session in &self.sessions {
            let mut tab_names = HashMap::new();
            for tab in &session.tabs {
                tab_names.insert(tab.position, tab.name.clone());
            }

            for (tab_position, panes) in &session.panes.panes {
                for pane in panes {
                    if pane.is_plugin || pane.exited || pane.is_suppressed || !pane.is_selectable {
                        continue;
                    }
                    let default_tab_name = format!("Tab {}", tab_position + 1);
                    let terminal_command = pane.terminal_command.clone();
                    pane_lookup.insert(
                        (session.name.clone(), pane.id),
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
        }
        pane_lookup
    }

    fn refresh_pane_cache(
        &mut self,
        pane_lookup: &HashMap<(String, u32), PaneDetails>,
    ) -> HashMap<(String, u32), PaneDetails> {
        let mut refreshed_by_session: HashMap<String, HashMap<u32, PaneDetails>> = HashMap::new();
        for ((session_name, pane_id), details) in pane_lookup {
            refreshed_by_session
                .entry(session_name.clone())
                .or_default()
                .insert(*pane_id, details.clone());
        }

        for session in &self.sessions {
            if refreshed_by_session.contains_key(session.name.as_str()) {
                continue;
            }
            if let Some(cached) = self.pane_cache_by_session.get(session.name.as_str()) {
                refreshed_by_session.insert(session.name.clone(), cached.clone());
            }
        }

        self.pane_cache_by_session = refreshed_by_session.clone();

        let mut merged_lookup = HashMap::new();
        for (session_name, panes) in refreshed_by_session {
            for (pane_id, details) in panes {
                merged_lookup.insert((session_name.clone(), pane_id), details);
            }
        }
        merged_lookup
    }

    fn detect_entries_from_sources(
        &mut self,
        pane_lookup: &HashMap<(String, u32), PaneDetails>,
        tracked_panes: Vec<StoredPane>,
    ) -> Vec<SessionEntry> {
        let mut sessions_with_live_panes: HashMap<String, bool> = HashMap::new();
        for (session_name, _) in pane_lookup.keys() {
            sessions_with_live_panes.insert(session_name.clone(), true);
        }

        let mut latest_tracked: HashMap<(String, u32), StoredPane> = HashMap::new();
        for tracked in tracked_panes {
            if !is_supported_agent(&tracked.agent) {
                continue;
            }
            let key = if let Some(stable_id) = tracked.stable_id.as_deref() {
                if let Some(existing_key) = self.stable_pane_mapping.get(stable_id) {
                    existing_key.clone()
                } else {
                    let key = (tracked.session_name.clone(), tracked.pane_id);
                    self.stable_pane_mapping
                        .insert(stable_id.to_string(), key.clone());
                    key
                }
            } else {
                (tracked.session_name.clone(), tracked.pane_id)
            };
            latest_tracked
                .entry(key)
                .and_modify(|current| {
                    if tracked.updated_at_ms > current.updated_at_ms {
                        *current = tracked.clone();
                    }
                })
                .or_insert(tracked);
        }

        let now = now_ms();
        let known_sessions = self.build_known_sessions(now);
        let mut entries = Vec::new();
        let mut seen_panes: HashMap<(String, u32), bool> = HashMap::new();

        let is_current = |name: &str| -> bool {
            self.current_session_name
                .as_deref()
                .map(|session_name| session_name == name)
                .unwrap_or(false)
        };

        for tracked in latest_tracked.values() {
            let session_exists = known_sessions.contains_key(tracked.session_name.as_str());
            if !session_exists {
                continue;
            }

            let key = (tracked.session_name.clone(), tracked.pane_id);

            // Always check freshness — the heartbeat in the JS plugin updates
            // the state file every 60 s, so a 3-minute window is generous for
            // any live agent.  Without this, stale state files from crashed
            // processes permanently haunt panes whose IDs get reused.
            if tracked.updated_at_ms != 0
                && now.saturating_sub(tracked.updated_at_ms) > MAX_PANE_STATE_AGE_MS
            {
                continue;
            }

            // For sessions with live pane data, also require the pane to still
            // exist — if the pane was closed, the entry should disappear
            // immediately rather than lingering for the full TTL.
            if sessions_with_live_panes.contains_key(tracked.session_name.as_str())
                && !pane_lookup.contains_key(&key)
            {
                continue;
            }

            seen_panes.insert(key.clone(), true);

            if let Some(details) = pane_lookup.get(&key) {
                entries.push(SessionEntry {
                    session_name: tracked.session_name.clone(),
                    pane_id: tracked.pane_id,
                    pane_title: details.pane_title.clone(),
                    tab_position: details.tab_position,
                    tab_name: details.tab_name.clone(),
                    status: tracked.status.clone(),
                    cwd: tracked.cwd.clone(),
                    updated_at_ms: tracked.updated_at_ms,
                });
            } else {
                let agent_name = inferred_agent_name(Some(&tracked.agent))
                    .unwrap_or("Agent")
                    .to_string();
                entries.push(SessionEntry {
                    session_name: tracked.session_name.clone(),
                    pane_id: tracked.pane_id,
                    pane_title: agent_name,
                    tab_position: 0,
                    tab_name: String::new(),
                    status: tracked.status.clone(),
                    cwd: tracked.cwd.clone(),
                    updated_at_ms: tracked.updated_at_ms,
                });
            }
        }

        for ((session_name, pane_id), details) in pane_lookup {
            if !is_current(session_name) {
                continue;
            }
            if seen_panes.contains_key(&(session_name.clone(), *pane_id)) {
                continue;
            }
            if !is_agent_pane(details) {
                continue;
            }
            entries.push(SessionEntry {
                session_name: session_name.clone(),
                pane_id: *pane_id,
                pane_title: details.pane_title.clone(),
                tab_position: details.tab_position,
                tab_name: details.tab_name.clone(),
                status: "waiting_user_input".to_string(),
                cwd: None,
                updated_at_ms: 0,
            });
        }

        entries
    }

    fn build_known_sessions(&mut self, now: u64) -> HashMap<String, bool> {
        let mut known_sessions: HashMap<String, bool> = self
            .sessions
            .iter()
            .map(|session| (session.name.clone(), true))
            .collect();
        for (name, &last_seen) in &self.session_last_seen {
            if !known_sessions.contains_key(name.as_str())
                && now.saturating_sub(last_seen) <= SESSION_GRACE_MS
            {
                known_sessions.insert(name.clone(), true);
            }
        }
        self.session_last_seen
            .retain(|_, ts| now.saturating_sub(*ts) <= SESSION_GRACE_MS * 2);
        known_sessions
    }

    fn apply_entries(&mut self, mut entries: Vec<SessionEntry>, status_message: Option<String>) {
        let previous_selected = self
            .entries
            .get(self.selected_index)
            .map(|entry| (entry.session_name.clone(), entry.pane_id));
        let previous_entries = self.entries.clone();

        entries.sort_by(|left, right| {
            let current_session_name = self.current_session_name.as_deref().unwrap_or_default();
            right
                .session_name
                .as_str()
                .eq(current_session_name)
                .cmp(&left.session_name.as_str().eq(current_session_name))
                .then(left.session_name.cmp(&right.session_name))
                .then(left.tab_position.cmp(&right.tab_position))
                .then(left.tab_name.cmp(&right.tab_name))
                .then(left.pane_title.cmp(&right.pane_title))
                .then(right.updated_at_ms.cmp(&left.updated_at_ms))
        });

        let now = now_ms();
        for entry in &entries {
            self.entry_last_seen
                .insert((entry.session_name.clone(), entry.pane_id), now);
        }

        let mut stabilized_entries = entries;
        for entry in &previous_entries {
            let key = (entry.session_name.clone(), entry.pane_id);
            let was_seen_recently = self
                .entry_last_seen
                .get(&key)
                .map(|last_seen| now.saturating_sub(*last_seen) <= ENTRY_MISSING_GRACE_MS)
                .unwrap_or(false);
            let still_present = stabilized_entries.iter().any(|candidate| {
                candidate.session_name == entry.session_name && candidate.pane_id == entry.pane_id
            });
            if !still_present && was_seen_recently {
                stabilized_entries.push(entry.clone());
            }
        }

        stabilized_entries.sort_by(|left, right| {
            let current_session_name = self.current_session_name.as_deref().unwrap_or_default();
            right
                .session_name
                .as_str()
                .eq(current_session_name)
                .cmp(&left.session_name.as_str().eq(current_session_name))
                .then(left.session_name.cmp(&right.session_name))
                .then(left.tab_position.cmp(&right.tab_position))
                .then(left.tab_name.cmp(&right.tab_name))
                .then(left.pane_title.cmp(&right.pane_title))
                .then(right.updated_at_ms.cmp(&left.updated_at_ms))
        });

        self.entry_last_seen.retain(|key, last_seen| {
            now.saturating_sub(*last_seen) <= ENTRY_MISSING_GRACE_MS
                || stabilized_entries
                    .iter()
                    .any(|entry| entry.session_name == key.0 && entry.pane_id == key.1)
        });

        self.entries = stabilized_entries;

        if self.entries.is_empty() {
            self.selected_index = 0;
        } else if let Some(selected_pane) = previous_selected {
            if let Some(index) = self.entries.iter().position(|entry| {
                (entry.session_name.as_str(), entry.pane_id)
                    == (selected_pane.0.as_str(), selected_pane.1)
            }) {
                self.selected_index = index;
            } else {
                self.selected_index = self.selected_index.min(self.entries.len() - 1);
            }
        } else {
            self.selected_index = self.selected_index.min(self.entries.len() - 1);
        }

        self.status_message = status_message;
        self.persist_cached_entries();
    }

    fn detection_snapshot_path(&self) -> PathBuf {
        Path::new("/host").join(DETECTION_INPUT_FILE)
    }

    fn persist_cached_entries(&self) {
        if self.sessions.is_empty() {
            return;
        }

        let cache_path = Path::new("/host").join(DEFAULT_CACHE_FILE);
        let contents = match serde_json::to_string(&CachedEntries {
            generated_at_ms: now_ms(),
            session_names: self.current_session_names(),
            entries: self.entries.clone(),
        }) {
            Ok(contents) => contents,
            Err(_) => return,
        };
        let _ = fs::write(cache_path, contents);
    }

    fn current_session_names(&self) -> Vec<String> {
        let mut session_names = self
            .sessions
            .iter()
            .map(|session| session.name.clone())
            .collect::<Vec<_>>();
        session_names.sort();
        session_names
    }

    /// Read all valid state files, skipping any that fail to read or parse.
    /// No TTL filtering is done here -- callers decide whether to apply age
    /// checks based on session-existence context.
    fn read_state_entries_resilient(&self) -> Vec<StoredPane> {
        let mut entries = Vec::new();

        let pane_dir = Path::new("/host").join("panes");
        if pane_dir.exists() {
            if let Ok(dir_entries) = fs::read_dir(&pane_dir) {
                for entry in dir_entries.flatten() {
                    let path = entry.path();
                    if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
                        continue;
                    }
                    let contents = match fs::read_to_string(&path) {
                        Ok(c) => c,
                        Err(_) => continue, // file mid-write or deleted -- skip
                    };
                    let tracked = match serde_json::from_str::<StoredPane>(&contents) {
                        Ok(t) => t,
                        Err(_) => continue, // corrupt or partial JSON -- skip
                    };
                    entries.push(tracked);
                }
            }
        }

        // Legacy fallback: single file with all panes.
        if entries.is_empty() {
            let legacy_state = Path::new("/host").join(&self.state_file_name);
            if let Ok(contents) = fs::read_to_string(&legacy_state) {
                if let Ok(tracked) = serde_json::from_str::<StoredState>(&contents) {
                    entries.extend(tracked.panes.into_values());
                }
            }
        }

        entries
    }
}

fn status_icon(status: &str) -> &'static str {
    match status {
        "working" => "󰜎",
        "waiting_user_answers" => "",
        "asking_permissions" => "",
        "waiting_user_input" => "",
        _ => "",
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0)
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
    text.color_range(0, 1..label.chars().count().saturating_sub(1))
}

fn render_footer(y: usize, cols: usize) {
    let prefix = "Help:";
    let segments = [
        ("<Enter>", "focus pane"),
        ("<1-9>", "jump to pane"),
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

fn tracked_session_count(entries: &[SessionEntry]) -> usize {
    let mut sessions = BTreeMap::new();
    for entry in entries {
        sessions.insert(entry.session_name.as_str(), true);
    }
    sessions.len()
}

fn escape_snapshot_field(value: &str) -> String {
    value
        .replace('\t', " ")
        .replace('\n', " ")
        .replace('\r', " ")
}

fn detection_error_message(exit_code: Option<i32>, stderr: &str) -> String {
    let detail = stderr
        .lines()
        .find(|line| !line.trim().is_empty())
        .unwrap_or("script failed");
    match exit_code {
        Some(code) => format!("Detection script failed ({}): {}", code, detail),
        None => format!("Detection script interrupted: {}", detail),
    }
}

fn is_supported_agent(agent: &str) -> bool {
    matches!(agent, "opencode" | "claude")
}

fn is_agent_pane(details: &PaneDetails) -> bool {
    is_agent_command(details.terminal_command.as_deref())
}

fn is_agent_command(command: Option<&str>) -> bool {
    match command {
        Some(cmd) => {
            let lower = cmd.to_ascii_lowercase();
            lower.contains("opencode") || lower.contains("claude")
        }
        None => false,
    }
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

fn session_header_item(session_name: &str, is_current: bool, width: usize) -> NestedListItem {
    let _ = is_current;
    let line = truncate(session_name, width.saturating_sub(1));
    NestedListItem::new(line)
}

fn build_display_rows(
    entries: &[SessionEntry],
    current_session_name: &str,
    selected_index: usize,
    width: usize,
) -> Vec<DisplayRow> {
    let mut rows = Vec::new();
    let mut last_session = None::<&str>;

    for (index, entry) in entries.iter().enumerate() {
        if last_session != Some(entry.session_name.as_str()) {
            rows.push(DisplayRow {
                item: session_header_item(
                    &entry.session_name,
                    entry.session_name == current_session_name,
                    width,
                ),
                entry_index: None,
            });
            last_session = Some(entry.session_name.as_str());
        }

        let is_selected = index == selected_index;
        let shortcut_number = if index < 9 { Some(index + 1) } else { None };
        rows.push(DisplayRow {
            item: primary_item(entry, is_selected, width, shortcut_number),
            entry_index: Some(index),
        });
        rows.push(DisplayRow {
            item: secondary_item(entry, is_selected, width),
            entry_index: Some(index),
        });
    }

    rows
}

fn primary_item(
    entry: &SessionEntry,
    is_selected: bool,
    width: usize,
    shortcut_number: Option<usize>,
) -> NestedListItem {
    let tab = format!("[{}]", entry.tab_name);
    let icon = status_icon(&entry.status);
    let prefix = match shortcut_number {
        Some(n) => format!("[{}] ", n),
        None => String::from(" "),
    };
    let line = truncate(
        &format!("{}{}  {}  {}", prefix, icon, entry.pane_title, tab),
        width.saturating_sub(1),
    );
    let line_len = line.chars().count();
    let prefix_end = prefix.chars().count().min(line_len);
    let icon_end = (prefix_end + icon.chars().count()).min(line_len);
    let title_start = (icon_end + 2).min(line_len);
    let title_end = line
        .rfind("  [")
        .map(|byte_index| line[..byte_index].chars().count())
        .unwrap_or(line_len);
    let mut item = NestedListItem::new(line)
        .color_range(3, 0..prefix_end)
        .color_range(status_color_index(&entry.status), prefix_end..icon_end)
        .color_range(2, title_start..title_end)
        .color_range(0, title_end..line_len);
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

fn group_scroll_offset(
    selected_row: usize,
    header_row: usize,
    visible_rows: usize,
    total_rows: usize,
) -> usize {
    let default_start = scroll_offset(selected_row, visible_rows, total_rows);
    if selected_row.saturating_sub(header_row) + 1 <= visible_rows {
        header_row.min(default_start)
    } else {
        default_start
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
