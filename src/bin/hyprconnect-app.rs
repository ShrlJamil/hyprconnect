//! HyprConnect GTK 4 app: device list with pairing (verification key
//! confirmation), ping, file sending, SFTP mount control, unpair,
//! and the presenter target-monitor setting. All state lives in the
//! daemon; this window is a thin client of its control socket.

use gtk4::prelude::*;
use gtk4::{
    Application, ApplicationWindow, Box as GtkBox, Button, DropDown, Label, ListBox, Orientation,
    Separator, StringList,
};
use serde_json::{json, Value};
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

fn main() {
    let app = Application::builder()
        .application_id("io.github.ShrlJamil.hyprconnect")
        .build();
    app.connect_activate(build_ui);
    app.run();
}

struct AppState {
    window: ApplicationWindow,
    self_label: Label,
    status_label: Label,
    list: ListBox,
    monitor_dropdown: DropDown,
    monitor_model: StringList,
}

fn build_ui(app: &Application) {
    let window = ApplicationWindow::builder()
        .application(app)
        .title("HyprConnect")
        .default_width(440)
        .default_height(520)
        .build();

    let root = GtkBox::new(Orientation::Vertical, 8);
    root.set_margin_top(12);
    root.set_margin_bottom(12);
    root.set_margin_start(12);
    root.set_margin_end(12);

    let self_label = Label::new(Some("HyprConnect"));
    self_label.add_css_class("title-3");
    self_label.set_halign(gtk4::Align::Start);
    root.append(&self_label);

    let status_label = Label::new(Some(""));
    status_label.add_css_class("dim-label");
    status_label.set_halign(gtk4::Align::Start);
    root.append(&status_label);

    let list = ListBox::new();
    list.set_selection_mode(gtk4::SelectionMode::None);
    root.append(&list);

    root.append(&Separator::new(Orientation::Horizontal));

    let pres_title = Label::new(Some("Presentation remote"));
    pres_title.add_css_class("title-4");
    pres_title.set_halign(gtk4::Align::Start);
    root.append(&pres_title);

    let pres_row = GtkBox::new(Orientation::Horizontal, 8);
    let pres_label = Label::new(Some("Pointer monitor"));
    pres_row.append(&pres_label);
    let monitor_model = StringList::new(&["Automatic (external if present)"]);
    let monitor_dropdown = DropDown::new(Some(monitor_model.clone()), None::<&gtk4::Expression>);
    pres_row.append(&monitor_dropdown);
    root.append(&pres_row);

    let pres_hint = Label::new(Some(
        "Where the presenter pointer appears. Notes and slide previews arrive with the HyprConnect mobile app.",
    ));
    pres_hint.add_css_class("dim-label");
    pres_hint.set_halign(gtk4::Align::Start);
    pres_hint.set_wrap(true);
    root.append(&pres_hint);

    window.set_child(Some(&root));
    window.present();

    let state = Rc::new(AppState {
        window,
        self_label,
        status_label,
        list,
        monitor_dropdown,
        monitor_model,
    });
    refresh(state.clone());
    load_settings(state.clone());
    gtk4::glib::timeout_add_local(std::time::Duration::from_millis(2500), move || {
        refresh(state.clone());
        gtk4::glib::ControlFlow::Continue
    });
}

fn load_settings(state: Rc<AppState>) {
    gtk4::glib::spawn_future_local(async move {
        let result = gtk4::gio::spawn_blocking(|| control_request(json!({"cmd": "settings"})))
            .await
            .map_err(|_| "worker failed".to_string())
            .and_then(|r| r);
        let Ok(resp) = result else { return };
        let current = resp["presenterMonitor"].as_str().unwrap_or("").to_string();
        let mut selected = 0u32;
        if let Some(monitors) = resp["monitors"].as_array() {
            for (i, m) in monitors.iter().enumerate() {
                if let Some(name) = m.as_str() {
                    state.monitor_model.append(name);
                    if name == current {
                        selected = (i + 1) as u32;
                    }
                }
            }
        }
        state.monitor_dropdown.set_selected(selected);
        let model = state.monitor_model.clone();
        state.monitor_dropdown.connect_selected_notify(move |dd| {
            let idx = dd.selected();
            let value = if idx == 0 {
                String::new()
            } else {
                model
                    .string(idx)
                    .map(|s| s.to_string())
                    .unwrap_or_default()
            };
            let req = json!({"cmd": "set_presenter_monitor", "monitor": value});
            gtk4::glib::spawn_future_local(async move {
                let _ = gtk4::gio::spawn_blocking(move || control_request(req)).await;
            });
        });
    });
}

fn refresh(state: Rc<AppState>) {
    gtk4::glib::spawn_future_local(async move {
        let result = gio_spawn_blocking_devices().await;
        match result {
            Ok(resp) => {
                let name = resp["self"]["deviceName"].as_str().unwrap_or("?");
                state.self_label.set_text(&format!("HyprConnect — {}", name));
                state.status_label.set_text("");
                rebuild_list(&state, &resp["devices"]);
            }
            Err(e) => {
                state.status_label.set_text(&e);
            }
        }
    });
}

async fn gio_spawn_blocking_devices() -> Result<Value, String> {
    gtk4::gio::spawn_blocking(|| control_request(json!({"cmd": "devices"})))
        .await
        .map_err(|_| "worker failed".to_string())?
}

fn send_request(req: Value) {
    gtk4::glib::spawn_future_local(async move {
        let _ = gtk4::gio::spawn_blocking(move || control_request(req)).await;
    });
}

fn send_command(cmd: &str, device_id: &str) {
    send_request(json!({"cmd": cmd, "deviceId": device_id}));
}

fn rebuild_list(state: &AppState, devices: &Value) {
    while let Some(child) = state.list.first_child() {
        state.list.remove(&child);
    }
    let arr = match devices.as_array() {
        Some(a) if !a.is_empty() => a.clone(),
        _ => {
            let row = GtkBox::new(Orientation::Vertical, 2);
            let l = Label::new(Some("No devices discovered yet"));
            l.add_css_class("dim-label");
            row.append(&l);
            state.list.append(&row);
            return;
        }
    };
    for dev in arr {
        let id = dev["deviceId"].as_str().unwrap_or("").to_string();
        let name = dev["name"].as_str().unwrap_or("(unknown)").to_string();
        let dtype = dev["type"].as_str().unwrap_or("");
        let connected = dev["connected"].as_bool().unwrap_or(false);
        let paired = dev["paired"].as_bool().unwrap_or(false);
        let pending_in = dev["pendingIn"].as_bool().unwrap_or(false);
        let pending_out = dev["pendingOut"].as_bool().unwrap_or(false);
        let mounted = dev["mounted"].as_bool().unwrap_or(false);
        let key = dev["verificationKey"].as_str().unwrap_or("").to_string();

        let row = GtkBox::new(Orientation::Vertical, 4);
        let title = Label::new(Some(&format!("{} ({})", name.trim(), dtype)));
        title.set_halign(gtk4::Align::Start);
        row.append(&title);

        let mut status_text = if pending_in {
            format!("Pair request — verification key: {}", key)
        } else if pending_out {
            format!("Pair request sent — verification key: {}", key)
        } else if paired && connected {
            "Paired, connected".to_string()
        } else if paired {
            "Paired, not connected".to_string()
        } else if connected {
            "Connected, not paired".to_string()
        } else {
            "Discovered".to_string()
        };
        if mounted {
            status_text.push_str(" · storage mounted");
        }
        let status = Label::new(Some(&status_text));
        status.add_css_class("dim-label");
        status.set_halign(gtk4::Align::Start);
        row.append(&status);

        let buttons = GtkBox::new(Orientation::Horizontal, 6);
        if pending_in {
            let accept = Button::with_label("Accept");
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
        } else if paired {
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

                if mounted {
                    let unmount = Button::with_label("Unmount storage");
                    let id2 = id.clone();
                    unmount.connect_clicked(move |_| send_command("unmount", &id2));
                    buttons.append(&unmount);
                } else {
                    let mount = Button::with_label("Mount storage");
                    let id2 = id.clone();
                    mount.connect_clicked(move |_| send_command("mount", &id2));
                    buttons.append(&mount);
                }
            }
            let unpair = Button::with_label("Unpair");
            let id2 = id.clone();
            unpair.connect_clicked(move |_| send_command("unpair", &id2));
            buttons.append(&unpair);
        } else {
            let pair = Button::with_label("Pair");
            let id2 = id.clone();
            pair.connect_clicked(move |_| send_command("pair", &id2));
            buttons.append(&pair);
        }
        row.append(&buttons);
        state.list.append(&row);
    }
}
