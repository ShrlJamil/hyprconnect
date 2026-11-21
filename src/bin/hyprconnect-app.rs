//! HyprConnect GTK 4 app, laid out after the KDE Connect desktop
//! app: a device sidebar on the left and a device page on the right
//! with actions and a feature list. All state lives in the daemon;
//! this window is a thin client of its control socket.

use adw::prelude::*;
use gtk4::prelude::*;
use gtk4::{Box as GtkBox, Button, Image, Label, ListBox, ListBoxRow, Orientation, ScrolledWindow};
use serde_json::{json, Value};
use std::cell::RefCell;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::rc::Rc;

fn state_dir() -> PathBuf {
    if let Ok(d) = std::env::var("HYPRCONNECT_STATE_DIR") {
        return PathBuf::from(d);
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home).join(".local/state/hyprconnect")
}

fn control_request(req: Value) -> Result<Value, String> {
    let path = state_dir().join("control.sock");
    let mut stream = UnixStream::connect(&path)
        .map_err(|e| format!("cannot reach daemon ({}): {}", path.display(), e))?;
    stream
        .write_all(format!("{}\n", req).as_bytes())
        .map_err(|e| e.to_string())?;
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line).map_err(|e| e.to_string())?;
    serde_json::from_str(line.trim()).map_err(|e| e.to_string())
}

fn send_request(req: Value) {
    gtk4::glib::spawn_future_local(async move {
        let _ = gtk4::gio::spawn_blocking(move || control_request(req)).await;
    });
}

fn send_command(cmd: &str, device_id: &str) {
    send_request(json!({"cmd": cmd, "deviceId": device_id}));
}

fn main() {
    let app = adw::Application::builder()
        .application_id("io.github.ShrlJamil.hyprconnect")
        .build();
    app.connect_activate(build_ui);
    app.run();
}

#[derive(Clone, Copy, PartialEq)]
enum DetailView {
    Device,
    Plugins,
    Encryption,
    Presentation,
}

struct AppState {
    window: adw::ApplicationWindow,
    sidebar: ListBox,
    detail: GtkBox,
    selected: RefCell<Option<String>>,
    devices: RefCell<Vec<Value>>,
    last_json: RefCell<String>,
    monitors: RefCell<Vec<String>>,
    presenter_monitor: RefCell<Option<String>>,
    view: RefCell<DetailView>,
    plugins: RefCell<std::collections::HashMap<String, bool>>,
    self_info: RefCell<(String, String)>,
}

fn build_ui(app: &adw::Application) {
    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("HyprConnect")
        .default_width(860)
        .default_height(560)
        .build();

    let toolbar = adw::ToolbarView::new();
    let header = adw::HeaderBar::new();
    toolbar.add_top_bar(&header);

    let split = adw::NavigationSplitView::new();
    split.set_min_sidebar_width(230.0);
    split.set_max_sidebar_width(300.0);

    // Sidebar: device list.
    let sidebar_box = GtkBox::new(Orientation::Vertical, 0);
    let sidebar_title = Label::new(Some("Devices"));
    sidebar_title.add_css_class("title-4");
    sidebar_title.set_halign(gtk4::Align::Start);
    sidebar_title.set_margin_top(12);
    sidebar_title.set_margin_bottom(8);
    sidebar_title.set_margin_start(12);
    sidebar_box.append(&sidebar_title);
    let sidebar_scroll = ScrolledWindow::new();
    sidebar_scroll.set_vexpand(true);
    let sidebar = ListBox::new();
    sidebar.add_css_class("navigation-sidebar");
    sidebar_scroll.set_child(Some(&sidebar));
    sidebar_box.append(&sidebar_scroll);
    let sidebar_page = adw::NavigationPage::builder()
        .title("Devices")
        .child(&sidebar_box)
        .build();
    split.set_sidebar(Some(&sidebar_page));

    // Content: device detail.
    let detail_scroll = ScrolledWindow::new();
    detail_scroll.set_vexpand(true);
    detail_scroll.set_hexpand(true);
    let clamp = adw::Clamp::new();
    clamp.set_maximum_size(720);
    let detail = GtkBox::new(Orientation::Vertical, 16);
    detail.set_margin_top(18);
    detail.set_margin_bottom(18);
    detail.set_margin_start(18);
    detail.set_margin_end(18);
    clamp.set_child(Some(&detail));
    detail_scroll.set_child(Some(&clamp));
    let content_page = adw::NavigationPage::builder()
        .title("HyprConnect")
        .child(&detail_scroll)
        .build();
    split.set_content(Some(&content_page));

    toolbar.set_content(Some(&split));
    window.set_content(Some(&toolbar));
    window.present();

    let state = Rc::new(AppState {
        window,
        sidebar,
        detail,
        selected: RefCell::new(None),
        devices: RefCell::new(Vec::new()),
        last_json: RefCell::new(String::new()),
        monitors: RefCell::new(Vec::new()),
        presenter_monitor: RefCell::new(None),
        view: RefCell::new(DetailView::Device),
        plugins: RefCell::new(std::collections::HashMap::new()),
        self_info: RefCell::new((String::new(), String::new())),
    });

    let st = state.clone();
    state.sidebar.connect_row_selected(move |_, row| {
        if let Some(row) = row {
            let idx = row.index() as usize;
            let id = st
                .devices
                .borrow()
                .get(idx)
                .and_then(|d| d["deviceId"].as_str().map(|s| s.to_string()));
            if id.is_some() {
                *st.selected.borrow_mut() = id;
                *st.view.borrow_mut() = DetailView::Device;
                rebuild_detail(&st);
            }
        }
    });

    refresh(state.clone());
    gtk4::glib::timeout_add_local(std::time::Duration::from_millis(2500), move || {
        refresh(state.clone());
        gtk4::glib::ControlFlow::Continue
    });
}

fn refresh(state: Rc<AppState>) {
    gtk4::glib::spawn_future_local(async move {
        let fetched = gtk4::gio::spawn_blocking(|| {
            let devices = control_request(json!({"cmd": "devices"}));
            let settings = control_request(json!({"cmd": "settings"}));
            (devices, settings)
        })
        .await;
        let Ok((devices, settings)) = fetched else {
            return;
        };
        if let Ok(s) = &settings {
            if let Some(pl) = s["plugins"].as_object() {
                let mut map = state.plugins.borrow_mut();
                for (k, v) in pl {
                    map.insert(k.clone(), v.as_bool().unwrap_or(true));
                }
            }
            if let Some(mons) = s["monitors"].as_array() {
                *state.monitors.borrow_mut() = mons
                    .iter()
                    .filter_map(|m| m.as_str().map(|x| x.to_string()))
                    .collect();
            }
            *state.presenter_monitor.borrow_mut() =
                s["presenterMonitor"].as_str().map(|x| x.to_string());
        }
        let Ok(resp) = devices else { return };
        {
            let name = resp["self"]["deviceName"].as_str().unwrap_or("").to_string();
            let id = resp["self"]["deviceId"].as_str().unwrap_or("").to_string();
            *state.self_info.borrow_mut() = (name, id);
        }
        let serialized = serde_json::to_string(&resp["devices"]).unwrap_or_default();
        if serialized == *state.last_json.borrow() {
            return;
        }
        *state.last_json.borrow_mut() = serialized;
        let arr = resp["devices"].as_array().cloned().unwrap_or_default();
        // Keep the selection valid; default to the first device.
        {
            let mut sel = state.selected.borrow_mut();
            let valid = sel
                .as_ref()
                .map(|id| arr.iter().any(|d| d["deviceId"].as_str() == Some(id.as_str())))
                .unwrap_or(false);
            if !valid {
                *sel = arr
                    .first()
                    .and_then(|d| d["deviceId"].as_str().map(|s| s.to_string()));
            }
        }
        *state.devices.borrow_mut() = arr;
        rebuild_sidebar(&state);
        rebuild_detail(&state);
    });
}

fn device_icon(dtype: &str) -> &'static str {
    match dtype {
        "phone" => "phone-symbolic",
        "tablet" => "tablet-symbolic",
        _ => "computer-symbolic",
    }
}

fn status_line(dev: &Value) -> String {
    let connected = dev["connected"].as_bool().unwrap_or(false);
    let paired = dev["paired"].as_bool().unwrap_or(false);
    let pending_in = dev["pendingIn"].as_bool().unwrap_or(false);
    let pending_out = dev["pendingOut"].as_bool().unwrap_or(false);
    let mounted = dev["mounted"].as_bool().unwrap_or(false);
    let mut s = if pending_in {
        "Wants to pair"
    } else if pending_out {
        "Pair request sent"
    } else if paired && connected {
        "Connected"
    } else if paired {
        "Paired, not connected"
    } else if connected {
        "Connected, not paired"
    } else {
        "Not connected"
    }
    .to_string();
    if mounted {
        s.push_str(" · storage mounted");
    }
    s
}

fn rebuild_sidebar(state: &Rc<AppState>) {
    while let Some(child) = state.sidebar.first_child() {
        state.sidebar.remove(&child);
    }
    let devices = state.devices.borrow();
    let selected = state.selected.borrow().clone();
    for dev in devices.iter() {
        let id = dev["deviceId"].as_str().unwrap_or("");
        let name = dev["name"].as_str().unwrap_or("(unknown)").trim().to_string();
        let dtype = dev["type"].as_str().unwrap_or("");
        let row_box = GtkBox::new(Orientation::Horizontal, 10);
        row_box.set_margin_top(6);
        row_box.set_margin_bottom(6);
        row_box.set_margin_start(6);
        row_box.set_margin_end(6);
        let icon = Image::from_icon_name(device_icon(dtype));
        icon.set_pixel_size(20);
        row_box.append(&icon);
        let texts = GtkBox::new(Orientation::Vertical, 1);
        let name_label = Label::new(Some(&name));
        name_label.set_halign(gtk4::Align::Start);
        texts.append(&name_label);
        let status = Label::new(Some(&status_line(dev)));
        status.add_css_class("dim-label");
        status.set_halign(gtk4::Align::Start);
        texts.append(&status);
        row_box.append(&texts);
        let row = ListBoxRow::new();
        row.set_child(Some(&row_box));
        state.sidebar.append(&row);
        if selected.as_deref() == Some(id) {
            state.sidebar.select_row(Some(&row));
        }
    }
    if devices.is_empty() {
        let l = Label::new(Some("No devices discovered"));
        l.add_css_class("dim-label");
        l.set_margin_top(10);
        state.sidebar.append(&l);
    }
}

fn clear_box(b: &GtkBox) {
    while let Some(child) = b.first_child() {
        b.remove(&child);
    }
}

fn tile(icon: &str, label: &str) -> Button {
    let b = Button::new();
    let inner = GtkBox::new(Orientation::Vertical, 6);
    inner.set_margin_top(12);
    inner.set_margin_bottom(12);
    let img = Image::from_icon_name(icon);
    img.set_pixel_size(26);
    inner.append(&img);
    let l = Label::new(Some(label));
    inner.append(&l);
    b.set_child(Some(&inner));
    b
}

fn battery_icon(level: i64, charging: bool) -> String {
    let step = ((level.clamp(0, 100) + 5) / 10) * 10;
    if charging {
        format!("battery-level-{}-charging-symbolic", step)
    } else {
        format!("battery-level-{}-symbolic", step)
    }
}

fn back_row(state: &Rc<AppState>, title: &str) -> GtkBox {
    let row = GtkBox::new(Orientation::Horizontal, 8);
    let back = Button::from_icon_name("go-previous-symbolic");
    back.add_css_class("flat");
    let st = state.clone();
    back.connect_clicked(move |_| {
        *st.view.borrow_mut() = DetailView::Device;
        rebuild_detail(&st);
    });
    row.append(&back);
    let l = Label::new(Some(title));
    l.add_css_class("title-3");
    l.set_halign(gtk4::Align::Start);
    row.append(&l);
    row
}

fn rebuild_detail(state: &Rc<AppState>) {
    clear_box(&state.detail);
    let devices = state.devices.borrow();
    let selected = state.selected.borrow().clone();
    let dev = selected.as_ref().and_then(|id| {
        devices
            .iter()
            .find(|d| d["deviceId"].as_str() == Some(id.as_str()))
            .cloned()
    });
    let Some(dev) = dev else {
        let page = adw::StatusPage::builder()
            .icon_name("phone-symbolic")
            .title("No device selected")
            .description("Devices on the same network appear in the sidebar.")
            .build();
        page.set_vexpand(true);
        state.detail.append(&page);
        return;
    };

    let paired = dev["paired"].as_bool().unwrap_or(false);
    if paired {
        match *state.view.borrow() {
            DetailView::Plugins => {
                build_plugins_view(state, &dev);
                return;
            }
            DetailView::Encryption => {
                build_encryption_view(state, &dev);
                return;
            }
            DetailView::Presentation => {
                build_presentation_view(state, &dev);
                return;
            }
            DetailView::Device => {}
        }
    }

    let id = dev["deviceId"].as_str().unwrap_or("").to_string();
    let name = dev["name"].as_str().unwrap_or("(unknown)").trim().to_string();
    let dtype = dev["type"].as_str().unwrap_or("");
    let connected = dev["connected"].as_bool().unwrap_or(false);
    let pending_in = dev["pendingIn"].as_bool().unwrap_or(false);
    let pending_out = dev["pendingOut"].as_bool().unwrap_or(false);
    let mounted = dev["mounted"].as_bool().unwrap_or(false);
    let key = dev["verificationKey"].as_str().unwrap_or("").to_string();
    let battery = dev["battery"].as_i64();
    let battery_charging = dev["batteryCharging"].as_bool().unwrap_or(false);

    // Header: icon, name, status, battery, overflow menu.
    let head = GtkBox::new(Orientation::Horizontal, 14);
    let icon = Image::from_icon_name(device_icon(dtype));
    icon.set_pixel_size(56);
    head.append(&icon);
    let head_texts = GtkBox::new(Orientation::Vertical, 2);
    head_texts.set_valign(gtk4::Align::Center);
    let name_label = Label::new(Some(&name));
    name_label.add_css_class("title-2");
    name_label.set_halign(gtk4::Align::Start);
    head_texts.append(&name_label);
    let status = Label::new(Some(&status_line(&dev)));
    status.add_css_class("dim-label");
    status.set_halign(gtk4::Align::Start);
    head_texts.append(&status);
    head.append(&head_texts);
    let spacer = GtkBox::new(Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    head.append(&spacer);
    if let Some(level) = battery {
        let bat = GtkBox::new(Orientation::Horizontal, 6);
        bat.set_valign(gtk4::Align::Center);
        let bicon = Image::from_icon_name(&battery_icon(level, battery_charging));
        bicon.set_pixel_size(22);
        bat.append(&bicon);
        let blabel = Label::new(Some(&format!("{}%", level)));
        bat.append(&blabel);
        if battery_charging {
            let ch = Label::new(Some("Charging"));
            ch.add_css_class("dim-label");
            bat.append(&ch);
        }
        head.append(&bat);
    }
    if paired {
        let group = gtk4::gio::SimpleActionGroup::new();
        let ping_action = gtk4::gio::SimpleAction::new("ping", None);
        {
            let id2 = id.clone();
            ping_action.connect_activate(move |_, _| {
                send_request(json!({"cmd": "ping", "deviceId": id2, "message": "Ping from HyprConnect"}));
            });
        }
        group.add_action(&ping_action);
        let plugins_action = gtk4::gio::SimpleAction::new("plugins", None);
        {
            let st = state.clone();
            plugins_action.connect_activate(move |_, _| {
                *st.view.borrow_mut() = DetailView::Plugins;
                rebuild_detail(&st);
            });
        }
        group.add_action(&plugins_action);
        let enc_action = gtk4::gio::SimpleAction::new("encryption", None);
        {
            let st = state.clone();
            enc_action.connect_activate(move |_, _| {
                *st.view.borrow_mut() = DetailView::Encryption;
                rebuild_detail(&st);
            });
        }
        group.add_action(&enc_action);
        let unpair_action = gtk4::gio::SimpleAction::new("unpair", None);
        {
            let id2 = id.clone();
            unpair_action.connect_activate(move |_, _| send_command("unpair", &id2));
        }
        group.add_action(&unpair_action);
        head.insert_action_group("device", Some(&group));
        let menu = gtk4::gio::Menu::new();
        menu.append(Some("Send ping"), Some("device.ping"));
        menu.append(Some("Plugin settings"), Some("device.plugins"));
        menu.append(Some("Encryption info"), Some("device.encryption"));
        menu.append(Some("Unpair"), Some("device.unpair"));
        let mb = gtk4::MenuButton::builder()
            .icon_name("view-more-symbolic")
            .menu_model(&menu)
            .build();
        mb.set_valign(gtk4::Align::Center);
        head.append(&mb);
    }
    state.detail.append(&head);

    // Pairing key, while a request is in flight.
    if pending_in || pending_out {
        let group = adw::PreferencesGroup::builder()
            .title("Pairing")
            .description("Compare this key with the one shown on the other device.")
            .build();
        let row = adw::ActionRow::builder()
            .title("Verification key")
            .subtitle(&key)
            .build();
        group.add(&row);
        state.detail.append(&group);
    }

    if pending_in || pending_out || !paired {
        let buttons = GtkBox::new(Orientation::Horizontal, 8);
        if pending_in {
            let accept = Button::with_label("Accept");
            accept.add_css_class("suggested-action");
            let id2 = id.clone();
            accept.connect_clicked(move |_| send_command("accept", &id2));
            buttons.append(&accept);
            let reject = Button::with_label("Reject");
            let id2 = id.clone();
            reject.connect_clicked(move |_| send_command("reject", &id2));
            buttons.append(&reject);
        } else if pending_out {
            let cancel = Button::with_label("Cancel request");
            let id2 = id.clone();
            cancel.connect_clicked(move |_| send_command("reject", &id2));
            buttons.append(&cancel);
        } else {
            let pair = Button::with_label("Pair");
            pair.add_css_class("suggested-action");
            let id2 = id.clone();
            pair.connect_clicked(move |_| send_command("pair", &id2));
            buttons.append(&pair);
        }
        state.detail.append(&buttons);
        return;
    }

    if !connected {
        let note = Label::new(Some(
            "This device is paired but not connected. Controls return when it reconnects.",
        ));
        note.add_css_class("dim-label");
        note.set_halign(gtk4::Align::Start);
        note.set_wrap(true);
        state.detail.append(&note);
        return;
    }

    // Control tiles: what this desktop can do to the phone.
    let flow = gtk4::FlowBox::new();
    flow.set_selection_mode(gtk4::SelectionMode::None);
    flow.set_homogeneous(true);
    flow.set_min_children_per_line(2);
    flow.set_max_children_per_line(4);
    flow.set_column_spacing(8);
    flow.set_row_spacing(8);

    let send = tile("document-send-symbolic", "Send file…");
    {
        let id2 = id.clone();
        let window = state.window.clone();
        send.connect_clicked(move |_| {
            let dialog = gtk4::FileDialog::builder()
                .title("Send file to phone")
                .modal(true)
                .build();
            let id3 = id2.clone();
            dialog.open(
                Some(&window),
                None::<&gtk4::gio::Cancellable>,
                move |res| {
                    if let Ok(file) = res {
                        if let Some(path) = file.path() {
                            send_request(json!({
                                "cmd": "send_file",
                                "deviceId": id3,
                                "path": path.to_string_lossy(),
                            }));
                        }
                    }
                },
            );
        });
    }
    flow.append(&send);

    let storage = tile(
        "folder-remote-symbolic",
        if mounted { "Unmount storage" } else { "Mount storage" },
    );
    {
        let id2 = id.clone();
        storage.connect_clicked(move |_| {
            send_command(if mounted { "unmount" } else { "mount" }, &id2);
        });
    }
    flow.append(&storage);

    let ring = tile("alarm-symbolic", "Ring phone");
    {
        let id2 = id.clone();
        ring.connect_clicked(move |_| send_command("ring", &id2));
    }
    flow.append(&ring);

    let present = tile("video-display-symbolic", "Presentation remote");
    {
        let st = state.clone();
        present.connect_clicked(move |_| {
            *st.view.borrow_mut() = DetailView::Presentation;
            rebuild_detail(&st);
        });
    }
    flow.append(&present);

    state.detail.append(&flow);

    // Media playing on the phone, controlled from here.
    let players = dev["phonePlayers"].as_array().cloned().unwrap_or_default();
    let players: Vec<&Value> = players
        .iter()
        .filter(|p| p["title"].as_str().map(|t| !t.is_empty()).unwrap_or(false))
        .collect();
    if !players.is_empty() {
        let group = adw::PreferencesGroup::builder()
            .title("Playing on the phone")
            .build();
        for p in players {
            let player = p["player"].as_str().unwrap_or("").to_string();
            let title = p["title"].as_str().unwrap_or("");
            let artist = p["artist"].as_str().unwrap_or("");
            let is_playing = p["isPlaying"].as_bool().unwrap_or(false);
            let volume = p["volume"].as_i64().unwrap_or(0);

            let card = GtkBox::new(Orientation::Vertical, 6);
            card.set_margin_top(8);
            card.set_margin_bottom(8);
            card.set_margin_start(10);
            card.set_margin_end(10);
            let heading = format!(
                "{}{}{}",
                title,
                if artist.is_empty() { "" } else { " — " },
                artist
            );
            let title_label = Label::new(Some(&heading));
            title_label.set_halign(gtk4::Align::Start);
            title_label.set_wrap(true);
            card.append(&title_label);
            let player_label = Label::new(Some(&player));
            player_label.add_css_class("dim-label");
            player_label.set_halign(gtk4::Align::Start);
            card.append(&player_label);

            let controls = GtkBox::new(Orientation::Horizontal, 6);
            let prev = Button::from_icon_name("media-skip-backward-symbolic");
            {
                let id2 = id.clone();
                let pl = player.clone();
                prev.connect_clicked(move |_| {
                    send_request(json!({"cmd": "phone_media", "deviceId": id2, "player": pl, "action": "Previous"}));
                });
            }
            controls.append(&prev);
            let playpause = Button::from_icon_name(if is_playing {
                "media-playback-pause-symbolic"
            } else {
                "media-playback-start-symbolic"
            });
            {
                let id2 = id.clone();
                let pl = player.clone();
                playpause.connect_clicked(move |_| {
                    send_request(json!({"cmd": "phone_media", "deviceId": id2, "player": pl, "action": "PlayPause"}));
                });
            }
            controls.append(&playpause);
            let next = Button::from_icon_name("media-skip-forward-symbolic");
            {
                let id2 = id.clone();
                let pl = player.clone();
                next.connect_clicked(move |_| {
                    send_request(json!({"cmd": "phone_media", "deviceId": id2, "player": pl, "action": "Next"}));
                });
            }
            controls.append(&next);

            let scale = gtk4::Scale::with_range(gtk4::Orientation::Horizontal, 0.0, 100.0, 1.0);
            scale.set_value(volume as f64);
            scale.set_hexpand(true);
            scale.set_draw_value(false);
            {
                let id2 = id.clone();
                let pl = player.clone();
                let last = std::rc::Rc::new(std::cell::Cell::new(volume));
                scale.connect_value_changed(move |s| {
                    let v = s.value().round() as i64;
                    if v != last.get() {
                        last.set(v);
                        send_request(json!({"cmd": "phone_volume", "deviceId": id2, "player": pl, "volume": v}));
                    }
                });
            }
            controls.append(&scale);
            card.append(&controls);
            group.add(&card);
        }
        state.detail.append(&group);
    }
}

const PLUGIN_META: &[(&str, &str, &str, &str)] = &[
    ("clipboard", "edit-copy-symbolic", "Clipboard sync", "Copy on one device, paste on the other"),
    ("share", "document-send-symbolic", "File sharing", "Send and receive files"),
    ("notification", "preferences-system-notifications-symbolic", "Notifications", "Phone notifications on this desktop, replies included"),
    ("mpris", "media-playback-start-symbolic", "Multimedia control", "Control players on both devices"),
    ("systemvolume", "audio-volume-high-symbolic", "System volume", "Desktop sound sinks in the phone's Devices tab"),
    ("sftp", "folder-remote-symbolic", "Browse device storage", "Mount the phone storage as a drive"),
    ("presenter", "video-display-symbolic", "Presentation remote", "Use the phone as a presentation pointer"),
    ("battery", "battery-level-100-symbolic", "Battery status", "Show the phone battery level in the header"),
    ("findmyphone", "alarm-symbolic", "Find my phone", "Ring the phone from this desktop"),
];

fn build_plugins_view(state: &Rc<AppState>, _dev: &Value) {
    state.detail.append(&back_row(state, "Plugin settings"));
    let group = adw::PreferencesGroup::builder()
        .description("Disabled plugins stop advertising their packets and drop incoming ones. Changes apply at once; the capability list refreshes on the next connection.")
        .build();
    for (key_name, icon, title, subtitle) in PLUGIN_META {
        let row = adw::SwitchRow::builder()
            .title(*title)
            .subtitle(*subtitle)
            .build();
        let img = Image::from_icon_name(icon);
        row.add_prefix(&img);
        let enabled = state
            .plugins
            .borrow()
            .get(*key_name)
            .copied()
            .unwrap_or(true);
        row.set_active(enabled);
        {
            let st = state.clone();
            let key_owned = key_name.to_string();
            row.connect_active_notify(move |r| {
                let want = r.is_active();
                st.plugins
                    .borrow_mut()
                    .insert(key_owned.clone(), want);
                send_request(json!({"cmd": "set_plugin", "plugin": key_owned, "enabled": want}));
            });
        }
        group.add(&row);
        if *key_name == "presenter" {
            group.add(&monitor_combo_row(state));
        }
    }
    state.detail.append(&group);
}

fn monitor_combo_row(state: &Rc<AppState>) -> adw::ComboRow {
    let monitors = state.monitors.borrow().clone();
    let current_monitor = state.presenter_monitor.borrow().clone();
    let model = gtk4::StringList::new(&[] as &[&str]);
    model.append("Automatic (external if present)");
    let mut selected_idx = 0u32;
    for (i, m) in monitors.iter().enumerate() {
        model.append(m);
        if current_monitor.as_deref() == Some(m.as_str()) {
            selected_idx = (i + 1) as u32;
        }
    }
    let row = adw::ComboRow::builder()
        .title("Pointer monitor")
        .subtitle("Where the presenter pointer appears")
        .model(&model)
        .build();
    row.set_selected(selected_idx);
    row.connect_selected_notify(move |r| {
        let idx = r.selected();
        let value = if idx == 0 {
            String::new()
        } else {
            monitors
                .get((idx - 1) as usize)
                .cloned()
                .unwrap_or_default()
        };
        send_request(json!({"cmd": "set_presenter_monitor", "monitor": value}));
    });
    row
}

fn build_encryption_view(state: &Rc<AppState>, dev: &Value) {
    state.detail.append(&back_row(state, "Encryption info"));
    let (self_name, self_id) = state.self_info.borrow().clone();
    let peer_name = dev["name"].as_str().unwrap_or("(unknown)").trim().to_string();
    let peer_id = dev["deviceId"].as_str().unwrap_or("");
    let key = dev["verificationKey"].as_str().unwrap_or("");
    let group = adw::PreferencesGroup::builder()
        .description("The connection is encrypted with TLS. If both devices show the same verification key, nobody in between can read the traffic.")
        .build();
    let r1 = adw::ActionRow::builder()
        .title(&self_name)
        .subtitle(&self_id)
        .build();
    group.add(&r1);
    let r2 = adw::ActionRow::builder()
        .title(&peer_name)
        .subtitle(peer_id)
        .build();
    group.add(&r2);
    let r3 = adw::ActionRow::builder()
        .title("Verification key")
        .subtitle(key)
        .build();
    group.add(&r3);
    state.detail.append(&group);
}

fn build_presentation_view(state: &Rc<AppState>, _dev: &Value) {
    state.detail.append(&back_row(state, "Presentation remote"));
    let group = adw::PreferencesGroup::builder()
        .description("Open Presentation remote for this device on the phone, then move the phone to move the pointer. Slide buttons on the phone step through the deck.")
        .build();
    group.add(&monitor_combo_row(state));
    state.detail.append(&group);
    let note = Label::new(Some(
        "Presenter notes and slide previews arrive with the HyprConnect mobile app.",
    ));
    note.add_css_class("dim-label");
    note.set_halign(gtk4::Align::Start);
    note.set_wrap(true);
    state.detail.append(&note);
}
