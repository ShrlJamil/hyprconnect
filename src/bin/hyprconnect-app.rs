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

struct AppState {
    window: adw::ApplicationWindow,
    sidebar: ListBox,
    detail: GtkBox,
    selected: RefCell<Option<String>>,
    devices: RefCell<Vec<Value>>,
    last_json: RefCell<String>,
    monitors: RefCell<Vec<String>>,
    presenter_monitor: RefCell<Option<String>>,
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

fn feature_row(icon: &str, title: &str, subtitle: &str, active: bool) -> adw::ActionRow {
    let row = adw::ActionRow::builder()
        .title(title)
        .subtitle(subtitle)
        .build();
    let img = Image::from_icon_name(icon);
    row.add_prefix(&img);
    let state_label = Label::new(Some(if active { "On" } else { "Off" }));
    state_label.add_css_class("dim-label");
    state_label.set_valign(gtk4::Align::Center);
    row.add_suffix(&state_label);
    row.set_sensitive(active);
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

    let id = dev["deviceId"].as_str().unwrap_or("").to_string();
    let name = dev["name"].as_str().unwrap_or("(unknown)").trim().to_string();
    let dtype = dev["type"].as_str().unwrap_or("");
    let connected = dev["connected"].as_bool().unwrap_or(false);
    let paired = dev["paired"].as_bool().unwrap_or(false);
    let pending_in = dev["pendingIn"].as_bool().unwrap_or(false);
    let pending_out = dev["pendingOut"].as_bool().unwrap_or(false);
    let mounted = dev["mounted"].as_bool().unwrap_or(false);
    let key = dev["verificationKey"].as_str().unwrap_or("").to_string();
    let mountpoints: Vec<String> = dev["mountpoints"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|m| m.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default();

    // Header: icon, name, status.
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

    // Action buttons.
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
    } else if !paired {
        let pair = Button::with_label("Pair");
        pair.add_css_class("suggested-action");
        let id2 = id.clone();
        pair.connect_clicked(move |_| send_command("pair", &id2));
        buttons.append(&pair);
    } else {
        if connected {
            let ping = Button::with_label("Ping");
            let id2 = id.clone();
            ping.connect_clicked(move |_| {
                send_request(json!({"cmd": "ping", "deviceId": id2, "message": "Ping from HyprConnect"}));
            });
            buttons.append(&ping);

            let send = Button::with_label("Send file…");
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
            buttons.append(&send);
        }
        let unpair = Button::with_label("Unpair");
        let id2 = id.clone();
        unpair.connect_clicked(move |_| send_command("unpair", &id2));
        buttons.append(&unpair);
    }
    state.detail.append(&buttons);

    if !paired {
        return;
    }

    // Feature list, KDE Connect style.
    let group = adw::PreferencesGroup::builder().title("Features").build();
    let live = connected;
    group.add(&feature_row(
        "edit-copy-symbolic",
        "Clipboard sync",
        "Copy on one device, paste on the other",
        live,
    ));
    group.add(&feature_row(
        "document-send-symbolic",
        "File sharing",
        "Send and receive files",
        live,
    ));
    group.add(&feature_row(
        "preferences-system-notifications-symbolic",
        "Notifications",
        "Phone notifications on this desktop, replies included",
        live,
    ));
    group.add(&feature_row(
        "media-playback-start-symbolic",
        "Multimedia control",
        "Control this desktop's players from the phone",
        live,
    ));
    group.add(&feature_row(
        "audio-volume-high-symbolic",
        "System volume",
        "Desktop sound sinks in the phone's Devices tab",
        live,
    ));

    // SFTP browsing: a real switch bound to the mount state.
    let sftp_sub = if mounted {
        mountpoints
            .first()
            .cloned()
            .unwrap_or_else(|| "Mounted".to_string())
    } else {
        "Mount the phone storage as a drive".to_string()
    };
    let sftp_row = adw::SwitchRow::builder()
        .title("Browse device storage")
        .subtitle(&sftp_sub)
        .build();
    let sftp_icon = Image::from_icon_name("folder-remote-symbolic");
    sftp_row.add_prefix(&sftp_icon);
    sftp_row.set_active(mounted);
    sftp_row.set_sensitive(connected);
    {
        let id2 = id.clone();
        sftp_row.connect_active_notify(move |row| {
            let want = row.is_active();
            if want != mounted {
                send_command(if want { "mount" } else { "unmount" }, &id2);
            }
        });
    }
    group.add(&sftp_row);

    // Presentation remote: monitor picker as a combo row.
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
    let pres_row = adw::ComboRow::builder()
        .title("Presentation remote")
        .subtitle("Monitor the pointer appears on")
        .model(&model)
        .build();
    let pres_icon = Image::from_icon_name("video-display-symbolic");
    pres_row.add_prefix(&pres_icon);
    pres_row.set_selected(selected_idx);
    pres_row.connect_selected_notify(move |row| {
        let idx = row.selected();
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
    group.add(&pres_row);

    state.detail.append(&group);
}
