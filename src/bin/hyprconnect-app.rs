//! HyprConnect GTK 4 app, laid out after the KDE Connect desktop
//! app: a device sidebar on the left and a device page on the right
//! with actions and a feature list. All state lives in the daemon;
//! this window is a thin client of its control socket.

use adw::prelude::*;
use gtk4::prelude::*;
use hyprconnect::update::{self, ReleaseInfo};
use gtk4::{Box as GtkBox, Button, Image, Label, ListBox, ListBoxRow, Orientation, ScrolledWindow, Separator};
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
}

#[derive(Clone, Copy, PartialEq)]
enum Panel {
    Empty,
    Multimedia,
    RemoteInput,
    Commands,
    Encryption,
}

fn panel_title(panel: Panel) -> &'static str {
    match panel {
        Panel::Empty => "",
        Panel::Multimedia => "Multimedia control",
        Panel::RemoteInput => "Remote input",
        Panel::Commands => "Run commands",
        Panel::Encryption => "Encryption info",
    }
}

struct AppState {
    window: adw::ApplicationWindow,
    sidebar: ListBox,
    /// Parallel to the sidebar rows: the device id for device rows,
    /// None for section headers and placeholders.
    sidebar_ids: RefCell<Vec<Option<String>>>,
    detail: GtkBox,
    selected: RefCell<Option<String>>,
    devices: RefCell<Vec<Value>>,
    last_json: RefCell<String>,
    monitors: RefCell<Vec<String>>,
    presenter_monitor: RefCell<Option<String>>,
    view: RefCell<DetailView>,
    plugins: RefCell<std::collections::HashMap<String, bool>>,
    self_info: RefCell<(String, String)>,
    commands: RefCell<serde_json::Map<String, Value>>,
    panel: RefCell<Panel>,
    media_player: RefCell<Option<String>>,
    inner_narrow: RefCell<bool>,
    /// Remote input: the pad only controls the phone while locked.
    remote_lock: std::cell::Cell<bool>,
    /// Pointer-lock session on GTK's own Wayland connection.
    plock: RefCell<Option<plock::Session>>,
}

fn build_ui(app: &adw::Application) {
    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("HyprConnect")
        .default_width(860)
        .default_height(560)
        .build();

    let provider = gtk4::CssProvider::new();
    provider.load_from_data(
        ".hc-active-row { background-color: alpha(@accent_bg_color, 0.25); }\n\
         .hc-middle-surface { background-color: alpha(@window_fg_color, 0.05); border-radius: 16px; }\n\
         .hc-sidebar-header { background-color: @sidebar_bg_color; box-shadow: none; }\n\
         .hc-art { border-radius: 16px; }\n\
         .hc-art-fallback { border-radius: 16px; background-color: alpha(@window_fg_color, 0.08); }",
    );
    if let Some(display) = gtk4::gdk::Display::default() {
        gtk4::style_context_add_provider_for_display(
            &display,
            &provider,
            gtk4::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
    }

    let header = adw::HeaderBar::new();
    header.set_show_start_title_buttons(false);
    header.set_show_end_title_buttons(false);
    // Back button shown only when the split view is collapsed and the
    // content page is showing: it returns to the device list.
    let back_button = Button::from_icon_name("go-previous-symbolic");
    back_button.set_visible(false);
    header.pack_start(&back_button);

    let split = adw::NavigationSplitView::new();
    split.set_min_sidebar_width(230.0);
    split.set_max_sidebar_width(300.0);

    // Sidebar: device list. The sidebar runs full height to the top of
    // the window; its own header bar holds the Devices title.
    let sidebar_header = adw::HeaderBar::new();
    sidebar_header.set_show_start_title_buttons(true);
    sidebar_header.set_show_end_title_buttons(false);
    sidebar_header.add_css_class("hc-sidebar-header");
    let sidebar_title = Label::new(Some("Devices"));
    sidebar_title.add_css_class("title-4");
    sidebar_header.set_title_widget(Some(&sidebar_title));
    // App menu at the end of the sidebar header: the manual
    // update check (the automatic one runs at startup, below).
    let app_menu = gtk4::gio::Menu::new();
    app_menu.append(Some("Check for Updates"), Some("app.check-updates"));
    let menu_button = gtk4::MenuButton::builder()
        .icon_name("open-menu-symbolic")
        .menu_model(&app_menu)
        .build();
    sidebar_header.pack_end(&menu_button);
    let check_action = gtk4::gio::SimpleAction::new("check-updates", None);
    {
        let win = window.clone();
        check_action.connect_activate(move |_, _| check_updates(&win, true));
    }
    app.add_action(&check_action);
    let sidebar_scroll = ScrolledWindow::new();
    sidebar_scroll.set_vexpand(true);
    let sidebar = ListBox::new();
    sidebar.add_css_class("navigation-sidebar");
    sidebar_scroll.set_child(Some(&sidebar));
    let sidebar_toolbar = adw::ToolbarView::new();
    sidebar_toolbar.add_top_bar(&sidebar_header);
    sidebar_toolbar.set_content(Some(&sidebar_scroll));
    let sidebar_page = adw::NavigationPage::builder()
        .title("Devices")
        .child(&sidebar_toolbar)
        .build();
    split.set_sidebar(Some(&sidebar_page));

    // Content: device detail.
    let detail_scroll = ScrolledWindow::new();
    detail_scroll.set_vexpand(true);
    detail_scroll.set_hexpand(true);
    let detail = GtkBox::new(Orientation::Vertical, 16);
    detail.set_margin_top(24);
    detail.set_margin_bottom(24);
    detail.set_margin_start(24);
    detail.set_margin_end(24);
    detail_scroll.set_child(Some(&detail));
    let content_toolbar = adw::ToolbarView::new();
    content_toolbar.add_top_bar(&header);
    content_toolbar.set_content(Some(&detail_scroll));
    let content_page = adw::NavigationPage::builder()
        .title("HyprConnect")
        .child(&content_toolbar)
        .build();
    split.set_content(Some(&content_page));

    // Responsive: below 700 px the split view collapses to one page at a
    // time (device list, then the selected device), like other GNOME apps.
    let breakpoint = adw::Breakpoint::new(adw::BreakpointCondition::parse("max-width: 700px").expect("valid breakpoint condition"));
    breakpoint.add_setter(&split, "collapsed", Some(&gtk4::glib::Value::from(true)));
    window.add_breakpoint(breakpoint);
    {
        let split2 = split.clone();
        back_button.connect_clicked(move |_| {
            split2.set_show_content(false);
        });
        let update_back = {
            let split3 = split.clone();
            let back = back_button.clone();
            let header2 = header.clone();
            move || {
                back.set_visible(split3.is_collapsed() && split3.shows_content());
                // Collapsed, the sidebar (and its window buttons) is
                // hidden, so the content header takes the buttons over.
                header2.set_show_start_title_buttons(split3.is_collapsed());
            }
        };
        let update_back2 = update_back.clone();
        split.connect_notify_local(Some("collapsed"), move |_, _| update_back());
        split.connect_notify_local(Some("show-content"), move |_, _| update_back2());
    }
    window.set_content(Some(&split));
    window.present();
    check_updates(&window, false);

    let state = Rc::new(AppState {
        window,
        sidebar,
        detail,
        sidebar_ids: RefCell::new(Vec::new()),
        selected: RefCell::new(None),
        devices: RefCell::new(Vec::new()),
        last_json: RefCell::new(String::new()),
        monitors: RefCell::new(Vec::new()),
        presenter_monitor: RefCell::new(None),
        view: RefCell::new(DetailView::Device),
        plugins: RefCell::new(std::collections::HashMap::new()),
        self_info: RefCell::new((String::new(), String::new())),
        commands: RefCell::new(serde_json::Map::new()),
        panel: RefCell::new(Panel::Empty),
        media_player: RefCell::new(None),
        inner_narrow: RefCell::new(false),
        remote_lock: std::cell::Cell::new(false),
        plock: RefCell::new(None),
    });

    // Remote input lock: capture controllers on the window. While
    // the lock is on they claim pointer and keyboard before any
    // widget sees them and forward everything to the phone.
    {
        let motion = gtk4::EventControllerMotion::new();
        motion.set_propagation_phase(gtk4::PropagationPhase::Capture);
        let last_pos: Rc<RefCell<Option<(f64, f64)>>> = Rc::new(RefCell::new(None));
        let pending: Rc<RefCell<(f64, f64)>> = Rc::new(RefCell::new((0.0, 0.0)));
        let last_send = Rc::new(std::cell::Cell::new(0i64));
        {
            let st = state.clone();
            motion.connect_motion(move |_, x, y| {
                if remote_active(&st).is_none() {
                    *last_pos.borrow_mut() = None;
                    return;
                }
                if let Some((lx, ly)) = *last_pos.borrow() {
                    let mut p = pending.borrow_mut();
                    p.0 += x - lx;
                    p.1 += y - ly;
                }
                *last_pos.borrow_mut() = Some((x, y));
                let now = gtk4::glib::monotonic_time() / 1000;
                if now - last_send.get() >= 24 {
                    let (dx, dy) = *pending.borrow();
                    if dx.abs() >= 0.5 || dy.abs() >= 0.5 {
                        *pending.borrow_mut() = (0.0, 0.0);
                        last_send.set(now);
                        send_mousepad(
                            &st,
                            json!({"dx": dx.round() as i64, "dy": dy.round() as i64}),
                        );
                    }
                }
            });
        }
        state.window.add_controller(motion);

        let click = gtk4::GestureClick::new();
        click.set_button(0);
        click.set_propagation_phase(gtk4::PropagationPhase::Capture);
        let pressed_mask = Rc::new(std::cell::Cell::new(0u32));
        {
            let st = state.clone();
            let pressed_mask = pressed_mask.clone();
            click.connect_released(move |g, _, _, _| {
                let btn = g.current_button();
                pressed_mask.set(pressed_mask.get() & !(1u32 << btn));
            });
        }
        {
            let st = state.clone();
            click.connect_pressed(move |g, n_press, _, _| {
                if remote_active(&st).is_none() {
                    pressed_mask.set(0);
                    return;
                }
                g.set_state(gtk4::EventSequenceState::Claimed);
                // Left and right buttons together release the lock.
                let btn = g.current_button();
                let mask = pressed_mask.get() | (1u32 << btn);
                pressed_mask.set(mask);
                if mask & (1 << 1) != 0 && mask & (1 << 3) != 0 {
                    pressed_mask.set(0);
                    release_remote_lock(&st);
                    return;
                }
                let kind = match (g.current_button(), n_press) {
                    (1, 2) => "doubleclick",
                    (1, _) => "singleclick",
                    (2, _) => "middleclick",
                    (3, _) => "rightclick",
                    _ => return,
                };
                let mut m = serde_json::Map::new();
                m.insert(kind.to_string(), json!(true));
                send_mousepad(&st, Value::Object(m));
            });
        }
        state.window.add_controller(click);

        let scroll = gtk4::EventControllerScroll::new(
            gtk4::EventControllerScrollFlags::BOTH_AXES,
        );
        scroll.set_propagation_phase(gtk4::PropagationPhase::Capture);
        {
            let st = state.clone();
            scroll.connect_scroll(move |_, dx, dy| {
                if remote_active(&st).is_none() {
                    return gtk4::glib::Propagation::Proceed;
                }
                if dx.abs() >= 0.1 || dy.abs() >= 0.1 {
                    send_mousepad(&st, json!({"scroll": true, "dx": dx, "dy": dy}));
                }
                gtk4::glib::Propagation::Stop
            });
        }
        state.window.add_controller(scroll);

        let keys = gtk4::EventControllerKey::new();
        keys.set_propagation_phase(gtk4::PropagationPhase::Capture);
        {
            let st = state.clone();
            keys.connect_key_pressed(move |_, keyval, _, mods| {
                if keyval == gtk4::gdk::Key::x
                    && mods.contains(gtk4::gdk::ModifierType::ALT_MASK)
                    && st.remote_lock.get()
                {
                    release_remote_lock(&st);
                    return gtk4::glib::Propagation::Stop;
                }
                if remote_active(&st).is_none() {
                    return gtk4::glib::Propagation::Proceed;
                }
                if let Some(body) = key_body(keyval, mods) {
                    send_mousepad(&st, body);
                }
                gtk4::glib::Propagation::Stop
            });
        }
        state.window.add_controller(keys);

        let st = state.clone();
        state.window.connect_close_request(move |_| {
            if st.remote_lock.get() {
                st.remote_lock.set(false);
                if let Ok(mut b) = st.plock.try_borrow_mut() {
                    if let Some(sess) = b.as_mut() {
                        sess.unlock();
                    }
                }
            }
            gtk4::glib::Propagation::Proceed
        });
    }

    // Pump the pointer-lock queue: locked/unlocked confirmations
    // and relative motion arrive there.
    {
        let st = state.clone();
        gtk4::glib::timeout_add_local(
            std::time::Duration::from_millis(10),
            move || {
                if let Ok(mut b) = st.plock.try_borrow_mut() {
                    if let Some(sess) = b.as_mut() {
                        sess.pump();
                    }
                }
                gtk4::glib::ControlFlow::Continue
            },
        );
    }

    let st = state.clone();
    let split_nav = split.clone();
    state.sidebar.connect_row_selected(move |_, row| {
        if let Some(row) = row {
            let idx = row.index() as usize;
            let id = st.sidebar_ids.borrow().get(idx).cloned().flatten();
            if id.is_some() {
                *st.selected.borrow_mut() = id;
                *st.view.borrow_mut() = DetailView::Device;
                rebuild_detail(&st);
                if split_nav.is_collapsed() {
                    split_nav.set_show_content(true);
                }
            }
        }
    });

    // Inner responsiveness: when the detail area gets narrow, the device
    // page shows either its control list or the open panel, not both.
    {
        let st = state.clone();
        state.detail.connect_notify_local(Some("width"), move |w, _| {
            let narrow = w.width() < 820;
            if narrow != *st.inner_narrow.borrow() {
                *st.inner_narrow.borrow_mut() = narrow;
                if *st.view.borrow() == DetailView::Device {
                    rebuild_detail(&st);
                }
            }
        });
    }

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
                // Default to a paired device when there is one: discovery
                // also hears other desktops (e.g. kdeconnectd), and opening
                // on a stranger's pairing page helps nobody.
                *sel = arr
                    .iter()
                    .find(|d| d["paired"].as_bool().unwrap_or(false))
                    .or_else(|| arr.first())
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
    s
}

fn rebuild_sidebar(state: &Rc<AppState>) {
    while let Some(child) = state.sidebar.first_child() {
        state.sidebar.remove(&child);
    }
    let devices = state.devices.borrow();
    let selected = state.selected.borrow().clone();
    let mut ids: Vec<Option<String>> = Vec::new();

    let connected: Vec<&Value> = devices
        .iter()
        .filter(|d| d["connected"].as_bool().unwrap_or(false))
        .collect();
    let available: Vec<&Value> = devices
        .iter()
        .filter(|d| {
            !d["connected"].as_bool().unwrap_or(false)
                && d["available"].as_bool().unwrap_or(false)
        })
        .collect();

    if connected.is_empty() && available.is_empty() {
        let l = Label::new(Some("No devices found"));
        l.add_css_class("dim-label");
        l.set_margin_top(10);
        state.sidebar.append(&l);
        ids.push(None);
    } else {
        for (title, group) in [("Connected", &connected), ("Available", &available)] {
            if group.is_empty() {
                continue;
            }
            state.sidebar.append(&section_header(title));
            ids.push(None);
            for dev in group {
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
                ids.push(Some(id.to_string()));
                if selected.as_deref() == Some(id) {
                    state.sidebar.select_row(Some(&row));
                }
            }
        }
    }
    *state.sidebar_ids.borrow_mut() = ids;
}

/// A sidebar section header: the title followed by a line that fills
/// the rest of the row ("Connected ───────"). Not selectable.
fn section_header(title: &str) -> ListBoxRow {
    let hbox = GtkBox::new(Orientation::Horizontal, 8);
    hbox.set_margin_start(12);
    hbox.set_margin_end(12);
    hbox.set_margin_top(12);
    hbox.set_margin_bottom(2);
    let label = Label::new(Some(title));
    label.add_css_class("caption-heading");
    label.add_css_class("dim-label");
    hbox.append(&label);
    let line = Separator::new(Orientation::Horizontal);
    line.set_hexpand(true);
    line.set_valign(gtk4::Align::Center);
    line.add_css_class("dim-label");
    hbox.append(&line);
    let row = ListBoxRow::new();
    row.set_child(Some(&hbox));
    row.set_selectable(false);
    row.set_activatable(false);
    row
}

fn clear_box(b: &GtkBox) {
    while let Some(child) = b.first_child() {
        b.remove(&child);
    }
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


fn build_device_header(state: &Rc<AppState>, dev: &Value) -> GtkBox {
    let id = dev["deviceId"].as_str().unwrap_or("").to_string();
    let name = dev["name"].as_str().unwrap_or("(unknown)").trim().to_string();
    let dtype = dev["type"].as_str().unwrap_or("");
    let paired = dev["paired"].as_bool().unwrap_or(false);
    let battery = dev["battery"].as_i64();
    let battery_charging = dev["batteryCharging"].as_bool().unwrap_or(false);

    let outer = GtkBox::new(Orientation::Vertical, 8);
    outer.set_margin_start(16);
    outer.set_margin_end(16);
    outer.set_margin_top(12);

    let row1 = GtkBox::new(Orientation::Horizontal, 12);
    let icon = Image::from_icon_name(device_icon(dtype));
    icon.set_pixel_size(48);
    row1.append(&icon);
    let texts = GtkBox::new(Orientation::Vertical, 2);
    texts.set_valign(gtk4::Align::Center);
    let name_label = Label::new(Some(&name));
    name_label.add_css_class("title-2");
    name_label.set_halign(gtk4::Align::Start);
    name_label.set_ellipsize(gtk4::pango::EllipsizeMode::End);
    texts.append(&name_label);
    let status = Label::new(Some(&status_line(dev)));
    status.add_css_class("dim-label");
    status.set_halign(gtk4::Align::Start);
    texts.append(&status);
    row1.append(&texts);
    if paired {
        // Everything sits on the name row: battery, then either the
        // three buttons (no panel open) or the three-dot menu (a panel
        // is open and the column is narrow).
        let spacer1 = GtkBox::new(Orientation::Horizontal, 0);
        spacer1.set_hexpand(true);
        row1.append(&spacer1);
        if let Some(level) = battery {
            let bat = GtkBox::new(Orientation::Horizontal, 6);
            bat.set_valign(gtk4::Align::Center);
            let bicon = Image::from_icon_name(&battery_icon(level, battery_charging));
            bicon.set_pixel_size(20);
            bat.append(&bicon);
            bat.append(&Label::new(Some(&format!("{}%", level))));
            if battery_charging {
                let ch = Label::new(Some("Charging"));
                ch.add_css_class("dim-label");
                bat.append(&ch);
            }
            row1.append(&bat);
        }
        if *state.panel.borrow() != Panel::Empty {
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
            let unpair_action = gtk4::gio::SimpleAction::new("unpair", None);
            {
                let id2 = id.clone();
                unpair_action.connect_activate(move |_, _| send_command("unpair", &id2));
            }
            group.add_action(&unpair_action);
            outer.insert_action_group("device", Some(&group));
            let menu = gtk4::gio::Menu::new();
            menu.append(Some("Send Ping"), Some("device.ping"));
            menu.append(Some("Plugin Settings"), Some("device.plugins"));
            menu.append(Some("Unpair"), Some("device.unpair"));
            let mb = gtk4::MenuButton::builder()
                .icon_name("view-more-symbolic")
                .menu_model(&menu)
                .build();
            mb.set_valign(gtk4::Align::Center);
            row1.append(&mb);
        } else {
            let ping = Button::with_label("Send Ping");
            ping.set_valign(gtk4::Align::Center);
            {
                let id2 = id.clone();
                ping.connect_clicked(move |_| {
                    send_request(json!({"cmd": "ping", "deviceId": id2, "message": "Ping from HyprConnect"}));
                });
            }
            row1.append(&ping);
            let plugins_btn = Button::with_label("Plugin Settings");
            plugins_btn.set_valign(gtk4::Align::Center);
            {
                let st = state.clone();
                plugins_btn.connect_clicked(move |_| {
                    *st.view.borrow_mut() = DetailView::Plugins;
                    rebuild_detail(&st);
                });
            }
            row1.append(&plugins_btn);
            let unpair = Button::with_label("Unpair");
            unpair.set_valign(gtk4::Align::Center);
            {
                let id2 = id.clone();
                unpair.connect_clicked(move |_| send_command("unpair", &id2));
            }
            row1.append(&unpair);
        }
    }
    outer.append(&row1);
    outer
}

fn rebuild_detail(state: &Rc<AppState>) {
    // Leaving the remote input panel always drops the input lock.
    if state.remote_lock.get() && *state.panel.borrow() != Panel::RemoteInput {
        state.remote_lock.set(false);
        if let Ok(mut b) = state.plock.try_borrow_mut() {
            if let Some(sess) = b.as_mut() {
                sess.unlock();
            }
        }
    }
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

    // Header: built once; where it lands depends on the device state.
    // A paired + connected device gets it inside the middle column,
    // every other state shows it at the top of the detail area.
    let mut head_slot = Some(build_device_header(state, &dev));
    let in_column = paired && connected && !pending_in && !pending_out;
    if !in_column {
        state.detail.append(&head_slot.take().unwrap());
    }

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

    // Device page: the middle column (device header + grouped control
    // list) and the open control's panel beside it, or one of the two
    // when the detail area is narrow.
    let middle = GtkBox::new(Orientation::Vertical, 12);
    middle.add_css_class("hc-middle-surface");
    middle.append(&head_slot.take().unwrap());
    let list_scroll = ScrolledWindow::new();
    list_scroll.set_vexpand(true);
    list_scroll.set_child(Some(&build_device_list(state, &dev)));
    middle.append(&list_scroll);
    if *state.inner_narrow.borrow() {
        if *state.panel.borrow() == Panel::Empty {
            state.detail.append(&middle);
        } else {
            state.detail.append(&build_panel(state, &dev));
        }
    } else if *state.panel.borrow() == Panel::Empty {
        state.detail.append(&middle);
    } else {
        let inner = adw::NavigationSplitView::new();
        inner.set_min_sidebar_width(420.0);
        inner.set_max_sidebar_width(500.0);
        middle.set_size_request(460, -1);
        let middle_page = adw::NavigationPage::builder()
            .title("Device")
            .child(&middle)
            .build();
        inner.set_sidebar(Some(&middle_page));
        let panel_scroll = ScrolledWindow::new();
        panel_scroll.set_vexpand(true);
        panel_scroll.set_hexpand(true);
        panel_scroll.set_child(Some(&build_panel(state, &dev)));
        let panel_page = adw::NavigationPage::builder()
            .title("Control")
            .child(&panel_scroll)
            .build();
        inner.set_content(Some(&panel_page));
        inner.set_vexpand(true);
        state.detail.append(&inner);
    }
}

/// Poll the daemon until the device reports a mountpoint (the phone
/// needs a moment to start its SFTP server), up to about 20 seconds.
fn wait_for_mountpoint(id: &str) -> Option<String> {
    for _ in 0..40 {
        if let Ok(resp) = control_request(json!({"cmd": "devices"})) {
            if let Some(devs) = resp["devices"].as_array() {
                if let Some(dev) = devs.iter().find(|d| d["deviceId"].as_str() == Some(id)) {
                    if dev["mounted"].as_bool().unwrap_or(false) {
                        if let Some(mp) = dev["mountpoints"]
                            .as_array()
                            .and_then(|a| a.first())
                            .and_then(|v| v.as_str())
                        {
                            if !mp.is_empty() {
                                return Some(mp.to_string());
                            }
                        }
                    }
                }
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    None
}

/// Open the file manager at a path, best first: the first installed
/// of nautilus, thunar, dolphin and friends, else xdg-open. Spawned
/// detached, so this app stays open.
fn open_file_manager(path: &str) {
    use std::os::unix::fs::PermissionsExt;
    const MANAGERS: &[&str] = &[
        "nautilus",
        "thunar",
        "dolphin",
        "nemo",
        "pcmanfm-qt",
        "pcmanfm",
        "caja",
    ];
    let on_path = |name: &str| {
        std::env::var_os("PATH")
            .map(|paths| {
                std::env::split_paths(&paths).any(|dir| {
                    let candidate = dir.join(name);
                    std::fs::metadata(&candidate)
                        .map(|m| m.permissions().mode() & 0o111 != 0)
                        .unwrap_or(false)
                })
            })
            .unwrap_or(false)
    };
    let program = MANAGERS
        .iter()
        .find(|name| on_path(name))
        .map(|s| s.to_string())
        .unwrap_or_else(|| "xdg-open".to_string());
    let _ = std::process::Command::new(&program)
        .arg(path)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
}

fn titled_players(dev: &Value) -> Vec<Value> {
    let players = dev["phonePlayers"].as_array().cloned().unwrap_or_default();
    players
        .into_iter()
        .filter(|p| p["title"].as_str().map(|t| !t.is_empty()).unwrap_or(false))
        .collect()
}

fn panel_row(
    state: &Rc<AppState>,
    panel: Panel,
    icon: &str,
    title: &str,
    subtitle: Option<&str>,
) -> adw::ActionRow {
    let row = adw::ActionRow::new();
    row.set_title(title);
    if let Some(sub) = subtitle {
        row.set_subtitle(sub);
    }
    row.add_prefix(&Image::from_icon_name(icon));
    row.set_activatable(true);
    row.add_suffix(&Image::from_icon_name("go-next-symbolic"));
    if *state.panel.borrow() == panel {
        row.add_css_class("hc-active-row");
    }
    let st = state.clone();
    row.connect_activated(move |_| {
        *st.panel.borrow_mut() = panel;
        rebuild_detail(&st);
    });
    row
}

fn build_device_list(state: &Rc<AppState>, dev: &Value) -> GtkBox {
    let id = dev["deviceId"].as_str().unwrap_or("").to_string();
    let mounted = dev["mounted"].as_bool().unwrap_or(false);
    let battery = dev["battery"].as_i64();
    let battery_charging = dev["batteryCharging"].as_bool().unwrap_or(false);
    let mountpoint = dev["mountpoints"]
        .as_array()
        .and_then(|a| a.first())
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let box_ = GtkBox::new(Orientation::Vertical, 18);
    box_.set_margin_start(16);
    box_.set_margin_end(16);
    box_.set_margin_bottom(16);

    // Controls: panels that operate the phone from here.
    let controls = adw::PreferencesGroup::new();
    controls.set_title("Controls");
    controls.add(&panel_row(
        state,
        Panel::Multimedia,
        "media-playback-start-symbolic",
        "Multimedia control",
        None,
    ));
    controls.add(&panel_row(
        state,
        Panel::RemoteInput,
        "input-touchpad-symbolic",
        "Remote input",
        None,
    ));
    controls.add(&panel_row(
        state,
        Panel::Commands,
        "utilities-terminal-symbolic",
        "Run commands",
        None,
    ));
    box_.append(&controls);

    // Actions: one-shot operations.
    let actions = adw::PreferencesGroup::new();
    actions.set_title("Actions");
    let find = adw::ActionRow::new();
    find.set_title("Find device");
    find.add_prefix(&Image::from_icon_name("alarm-symbolic"));
    find.set_activatable(true);
    {
        let id2 = id.clone();
        find.connect_activated(move |_| send_command("ring", &id2));
    }
    actions.add(&find);
    let clip = adw::ActionRow::new();
    clip.set_title("Send clipboard");
    clip.add_prefix(&Image::from_icon_name("edit-copy-symbolic"));
    clip.set_activatable(true);
    {
        let id2 = id.clone();
        clip.connect_activated(move |_| {
            send_request(json!({"cmd": "send_clipboard", "deviceId": id2}));
        });
    }
    actions.add(&clip);
    let share = adw::ActionRow::new();
    share.set_title("Share file");
    share.add_prefix(&Image::from_icon_name("document-send-symbolic"));
    share.set_activatable(true);
    {
        let id2 = id.clone();
        let window = state.window.clone();
        share.connect_activated(move |_| {
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
    actions.add(&share);
    let browse = adw::ActionRow::new();
    browse.set_title("Browse this device");
    browse.add_prefix(&Image::from_icon_name("folder-remote-symbolic"));
    if mounted && !mountpoint.is_empty() {
        let path = Label::new(Some(&mountpoint));
        path.add_css_class("dim-label");
        path.set_valign(gtk4::Align::Center);
        browse.add_suffix(&path);
    }
    if mounted {
        let group = gtk4::gio::SimpleActionGroup::new();
        let unmount_action = gtk4::gio::SimpleAction::new("unmount", None);
        {
            let id2 = id.clone();
            unmount_action.connect_activate(move |_, _| send_command("unmount", &id2));
        }
        group.add_action(&unmount_action);
        browse.insert_action_group("storage", Some(&group));
        let menu = gtk4::gio::Menu::new();
        menu.append(Some("Unmount storage"), Some("storage.unmount"));
        let mb = gtk4::MenuButton::builder()
            .icon_name("view-more-symbolic")
            .menu_model(&menu)
            .build();
        mb.add_css_class("flat");
        mb.set_valign(gtk4::Align::Center);
        browse.add_suffix(&mb);
    }
    browse.set_activatable(true);
    {
        let id2 = id.clone();
        let mp = mountpoint.clone();
        let state2 = state.clone();
        browse.connect_activated(move |_| {
            if mounted {
                open_file_manager(&mp);
            } else {
                send_command("mount", &id2);
                let id3 = id2.clone();
                let state3 = state2.clone();
                gtk4::glib::spawn_future_local(async move {
                    let found =
                        gtk4::gio::spawn_blocking(move || wait_for_mountpoint(&id3)).await;
                    match found {
                        Ok(Some(path)) => open_file_manager(&path),
                        // A silent no-op here reads as a broken
                        // app; say plainly that the device gave
                        // no file access to mount.
                        _ => show_info_dialog(
                            &state3.window,
                            "Could not browse this device",
                            "The device did not provide file access, so nothing could be mounted. On the HyprConnect phone app, browsing needs the all-files access allowed in its plugin settings.",
                        ),
                    }
                });
            }
        });
    }
    actions.add(&browse);
    box_.append(&actions);

    // Information.
    let info = adw::PreferencesGroup::new();
    info.set_title("Information");
    if let Some(level) = battery {
        let row = adw::ActionRow::new();
        row.set_title(&format!(
            "Battery: {}%{}",
            level,
            if battery_charging { " (charging)" } else { "" }
        ));
        row.add_prefix(&Image::from_icon_name(&battery_icon(level, battery_charging)));
        info.add(&row);
    }
    let conn = adw::ActionRow::new();
    let host = dev["host"].as_str().unwrap_or("");
    if dev["connected"].as_bool().unwrap_or(false) && !host.is_empty() {
        conn.set_title(&format!("Connection: {} via LAN", host));
    } else {
        conn.set_title("Connection");
    }
    conn.add_prefix(&Image::from_icon_name("network-wireless-symbolic"));
    info.add(&conn);
    info.add(&panel_row(
        state,
        Panel::Encryption,
        "channel-secure-symbolic",
        "Encryption info",
        None,
    ));
    box_.append(&info);
    box_
}

fn build_panel(state: &Rc<AppState>, dev: &Value) -> GtkBox {
    let panel = *state.panel.borrow();
    let box_ = GtkBox::new(Orientation::Vertical, 12);
    box_.set_margin_start(20);
    box_.set_margin_end(20);
    if panel == Panel::Empty {
        let page = adw::StatusPage::builder()
            .icon_name("input-touchpad-symbolic")
            .title("No control open")
            .description("Choose a control from the list to open it here.")
            .build();
        page.set_vexpand(true);
        box_.append(&page);
        return box_;
    }
    let head = GtkBox::new(Orientation::Horizontal, 8);
    {
        let back = Button::from_icon_name("go-previous-symbolic");
        back.add_css_class("flat");
        let st = state.clone();
        back.connect_clicked(move |_| {
            *st.panel.borrow_mut() = Panel::Empty;
            rebuild_detail(&st);
        });
        head.append(&back);
    }
    let title = Label::new(Some(panel_title(panel)));
    title.add_css_class("title-3");
    title.set_halign(gtk4::Align::Start);
    head.append(&title);
    if panel == Panel::Commands {
        let spacer = GtkBox::new(Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        head.append(&spacer);
        let add_btn = Button::with_label("Add Command");
        add_btn.add_css_class("suggested-action");
        let st = state.clone();
        add_btn.connect_clicked(move |_| show_command_dialog(&st, None));
        head.append(&add_btn);
    }
    box_.append(&head);
    match panel {
        Panel::Multimedia => box_.append(&build_multimedia_panel(state, dev)),
        Panel::RemoteInput => box_.append(&build_remote_input_panel(state, dev)),
        Panel::Commands => {
            // Fetch the current list before showing the editor.
            let st = state.clone();
            gtk4::glib::spawn_future_local(async move {
                let resp = gtk4::gio::spawn_blocking(|| {
                    control_request(json!({"cmd": "get_commands"}))
                })
                .await;
                if let Ok(Ok(resp)) = resp {
                    if let Some(map) = resp["commands"].as_object() {
                        if *st.commands.borrow() != *map {
                            *st.commands.borrow_mut() = map.clone();
                            rebuild_detail(&st);
                        }
                    }
                }
            });
            box_.append(&build_commands_panel(state))
        }
        Panel::Encryption => box_.append(&build_encryption_panel(state, dev)),
        Panel::Empty => {}
    }
    box_
}

fn fmt_time(ms: i64) -> String {
    let secs = (ms / 1000).max(0);
    format!("{}:{:02}", secs / 60, secs % 60)
}

fn build_multimedia_panel(state: &Rc<AppState>, dev: &Value) -> GtkBox {
    let id = dev["deviceId"].as_str().unwrap_or("").to_string();
    let box_ = GtkBox::new(Orientation::Vertical, 14);
    let players = titled_players(dev);
    if players.is_empty() {
        let l = Label::new(Some("Nothing is playing on the phone right now."));
        l.add_css_class("dim-label");
        l.set_wrap(true);
        l.set_xalign(0.0);
        box_.append(&l);
        return box_;
    }
    let chosen = state.media_player.borrow().clone();
    let idx = chosen
        .as_ref()
        .and_then(|name| {
            players
                .iter()
                .position(|p| p["player"].as_str() == Some(name.as_str()))
        })
        .unwrap_or(0);
    let p = &players[idx];
    let player = p["player"].as_str().unwrap_or("").to_string();
    let title = p["title"].as_str().unwrap_or("");
    let artist = p["artist"].as_str().unwrap_or("");
    let album = p["album"].as_str().unwrap_or("");
    let is_playing = p["isPlaying"].as_bool().unwrap_or(false);
    let volume = p["volume"].as_i64().unwrap_or(0);
    let pos = p["pos"].as_i64().unwrap_or(0);
    let length = p["length"].as_i64().unwrap_or(0);

    // Artwork, large with rounded corners; a quiet placeholder box
    // until the phone sends art for this player.
    if let Some(path) = p["albumArtPath"].as_str() {
        let pic = gtk4::Picture::for_filename(path);
        pic.set_content_fit(gtk4::ContentFit::Cover);
        pic.set_size_request(288, 288);
        pic.set_halign(gtk4::Align::Center);
        pic.set_overflow(gtk4::Overflow::Hidden);
        pic.add_css_class("hc-art");
        box_.append(&pic);
    } else {
        let ph = GtkBox::new(Orientation::Vertical, 0);
        ph.set_size_request(288, 288);
        ph.set_halign(gtk4::Align::Center);
        ph.add_css_class("hc-art-fallback");
        let icon = Image::from_icon_name("audio-x-generic-symbolic");
        icon.set_pixel_size(96);
        icon.set_halign(gtk4::Align::Center);
        icon.set_valign(gtk4::Align::Center);
        icon.set_vexpand(true);
        ph.append(&icon);
        box_.append(&ph);
    }

    let title_label = Label::new(Some(title));
    title_label.add_css_class("title-2");
    title_label.set_halign(gtk4::Align::Center);
    title_label.set_wrap(true);
    box_.append(&title_label);
    if !artist.is_empty() {
        let a = Label::new(Some(artist));
        a.set_halign(gtk4::Align::Center);
        a.set_wrap(true);
        box_.append(&a);
    }
    if !album.is_empty() {
        let a = Label::new(Some(album));
        a.add_css_class("dim-label");
        a.set_halign(gtk4::Align::Center);
        a.set_wrap(true);
        box_.append(&a);
    }

    // Seek bar with the position on the left and the length on the
    // right; drags go out as SetPosition, throttled while scrubbing.
    if length > 0 {
        let row = GtkBox::new(Orientation::Horizontal, 10);
        let pos_label = Label::new(Some(&fmt_time(pos)));
        pos_label.add_css_class("dim-label");
        pos_label.set_valign(gtk4::Align::Center);
        row.append(&pos_label);
        let seek = gtk4::Scale::with_range(
            gtk4::Orientation::Horizontal,
            0.0,
            length as f64,
            1000.0,
        );
        seek.set_value(pos as f64);
        seek.set_hexpand(true);
        seek.set_draw_value(false);
        seek.set_valign(gtk4::Align::Center);
        {
            let id2 = id.clone();
            let pl = player.clone();
            let last = std::rc::Rc::new(std::cell::Cell::new(None::<std::time::Instant>));
            seek.connect_value_changed(move |sc| {
                let now = std::time::Instant::now();
                let due = last
                    .get()
                    .map(|t| now.duration_since(t) >= std::time::Duration::from_millis(400))
                    .unwrap_or(true);
                if due {
                    last.set(Some(now));
                    send_request(json!({"cmd": "phone_seek", "deviceId": id2, "player": pl, "position": sc.value().round() as i64}));
                }
            });
        }
        row.append(&seek);
        let len_label = Label::new(Some(&fmt_time(length)));
        len_label.add_css_class("dim-label");
        len_label.set_valign(gtk4::Align::Center);
        row.append(&len_label);
        box_.append(&row);
    }

    // Transport: previous and next flank a large round play button.
    let controls = GtkBox::new(Orientation::Horizontal, 14);
    controls.set_halign(gtk4::Align::Center);
    let prev = Button::from_icon_name("media-skip-backward-symbolic");
    prev.add_css_class("flat");
    prev.set_valign(gtk4::Align::Center);
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
    playpause.add_css_class("suggested-action");
    playpause.add_css_class("circular");
    playpause.set_size_request(56, 56);
    playpause.set_valign(gtk4::Align::Center);
    {
        let id2 = id.clone();
        let pl = player.clone();
        playpause.connect_clicked(move |_| {
            send_request(json!({"cmd": "phone_media", "deviceId": id2, "player": pl, "action": "PlayPause"}));
        });
    }
    controls.append(&playpause);
    let next = Button::from_icon_name("media-skip-forward-symbolic");
    next.add_css_class("flat");
    next.set_valign(gtk4::Align::Center);
    {
        let id2 = id.clone();
        let pl = player.clone();
        next.connect_clicked(move |_| {
            send_request(json!({"cmd": "phone_media", "deviceId": id2, "player": pl, "action": "Next"}));
        });
    }
    controls.append(&next);
    box_.append(&controls);

    // Volume: level icon, slider, percentage.
    let vrow = GtkBox::new(Orientation::Horizontal, 10);
    let vol_icon = Image::from_icon_name(if volume <= 0 {
        "audio-volume-muted-symbolic"
    } else if volume < 50 {
        "audio-volume-low-symbolic"
    } else {
        "audio-volume-high-symbolic"
    });
    vol_icon.set_valign(gtk4::Align::Center);
    vrow.append(&vol_icon);
    let scale = gtk4::Scale::with_range(gtk4::Orientation::Horizontal, 0.0, 100.0, 1.0);
    scale.set_value(volume as f64);
    scale.set_hexpand(true);
    scale.set_draw_value(false);
    scale.set_valign(gtk4::Align::Center);
    {
        let id2 = id.clone();
        let pl = player.clone();
        let last = std::rc::Rc::new(std::cell::Cell::new(volume));
        scale.connect_value_changed(move |sc| {
            let v = sc.value().round() as i64;
            if v != last.get() {
                last.set(v);
                send_request(json!({"cmd": "phone_volume", "deviceId": id2, "player": pl, "volume": v}));
            }
        });
    }
    vrow.append(&scale);
    let vlabel = Label::new(Some(&format!("{}%", volume)));
    vlabel.add_css_class("dim-label");
    vlabel.set_valign(gtk4::Align::Center);
    vrow.append(&vlabel);
    box_.append(&vrow);
    // Source picker: which of the phone's players this panel drives.
    {
        let names: Vec<&str> = players
            .iter()
            .map(|p| p["player"].as_str().unwrap_or(""))
            .collect();
        let dd = gtk4::DropDown::from_strings(&names);
        dd.set_selected(idx as u32);
        let st = state.clone();
        let names_owned: Vec<String> = names.iter().map(|n| n.to_string()).collect();
        dd.connect_selected_notify(move |d| {
            let i = d.selected() as usize;
            if let Some(name) = names_owned.get(i) {
                *st.media_player.borrow_mut() = Some(name.clone());
                rebuild_detail(&st);
            }
        });
        box_.append(&dd);
    }
    box_
}


/// The selected device id when remote input is locked on, else None.
fn remote_active(state: &Rc<AppState>) -> Option<String> {
    if !state.remote_lock.get() {
        return None;
    }
    if *state.panel.borrow() != Panel::RemoteInput {
        return None;
    }
    state.selected.borrow().clone()
}

fn send_mousepad(state: &Rc<AppState>, body: Value) {
    if let Some(id) = remote_active(state) {
        send_request(json!({"cmd": "mousepad", "deviceId": id, "body": body}));
    }
}

/// Engage the pointer lock. The session is built lazily on first
/// use; the compositor confirms asynchronously, and the session's
/// lock callback flips remote_lock and rebuilds when it lands.
fn engage_remote_lock(state: &Rc<AppState>) {
    if state.plock.borrow().is_none() {
        match plock::Session::connect_gtk(state) {
            Some(sess) => *state.plock.borrow_mut() = Some(sess),
            None => {
                eprintln!("remote input: pointer lock unavailable");
                return;
            }
        }
    }
    let ok = state
        .plock
        .borrow_mut()
        .as_mut()
        .map(|sess| sess.lock())
        .unwrap_or(false);
    if !ok {
        eprintln!("remote input: lock request failed");
    }
}

fn release_remote_lock(state: &Rc<AppState>) {
    if let Ok(mut b) = state.plock.try_borrow_mut() {
        if let Some(sess) = b.as_mut() {
            sess.unlock();
        }
    }
    state.remote_lock.set(false);
    rebuild_detail(state);
}

/// Map a key press to a mousepad packet body (KDE Connect encoding).
fn key_body(keyval: gtk4::gdk::Key, mods: gtk4::gdk::ModifierType) -> Option<Value> {
    use gtk4::gdk::Key as k;
    let special: Option<i64> = if keyval == k::BackSpace {
        Some(1)
    } else if keyval == k::Tab || keyval == k::ISO_Left_Tab {
        Some(2)
    } else if keyval == k::Left {
        Some(4)
    } else if keyval == k::Up {
        Some(5)
    } else if keyval == k::Right {
        Some(6)
    } else if keyval == k::Down {
        Some(7)
    } else if keyval == k::Page_Up {
        Some(8)
    } else if keyval == k::Page_Down {
        Some(9)
    } else if keyval == k::Home {
        Some(10)
    } else if keyval == k::End {
        Some(11)
    } else if keyval == k::Return || keyval == k::KP_Enter {
        Some(12)
    } else if keyval == k::Delete {
        Some(13)
    } else if keyval == k::Escape {
        Some(14)
    } else if keyval == k::Control_L || keyval == k::Control_R {
        Some(17)
    } else if keyval == k::Alt_L || keyval == k::Alt_R {
        Some(18)
    } else if keyval == k::Shift_L || keyval == k::Shift_R {
        Some(19)
    } else if keyval == k::Super_L || keyval == k::Super_R {
        Some(20)
    } else if keyval == k::F1 {
        Some(21)
    } else if keyval == k::F2 {
        Some(22)
    } else if keyval == k::F3 {
        Some(23)
    } else if keyval == k::F4 {
        Some(24)
    } else if keyval == k::F5 {
        Some(25)
    } else if keyval == k::F6 {
        Some(26)
    } else if keyval == k::F7 {
        Some(27)
    } else if keyval == k::F8 {
        Some(28)
    } else if keyval == k::F9 {
        Some(29)
    } else if keyval == k::F10 {
        Some(30)
    } else if keyval == k::F11 {
        Some(31)
    } else if keyval == k::F12 {
        Some(32)
    } else {
        None
    };
    let mut body = serde_json::Map::new();
    if mods.contains(gtk4::gdk::ModifierType::CONTROL_MASK) {
        body.insert("ctrl".into(), json!(true));
    }
    if mods.contains(gtk4::gdk::ModifierType::ALT_MASK) {
        body.insert("alt".into(), json!(true));
    }
    if mods.contains(gtk4::gdk::ModifierType::SHIFT_MASK) {
        body.insert("shift".into(), json!(true));
    }
    if mods.contains(gtk4::gdk::ModifierType::SUPER_MASK)
        || mods.contains(gtk4::gdk::ModifierType::META_MASK)
    {
        body.insert("super".into(), json!(true));
    }
    if let Some(n) = special {
        body.insert("specialKey".into(), json!(n));
        return Some(Value::Object(body));
    }
    if let Some(c) = keyval.to_unicode() {
        if !c.is_control() {
            body.insert("key".into(), json!(c.to_string()));
            return Some(Value::Object(body));
        }
    }
    None
}

fn build_remote_input_panel(state: &Rc<AppState>, dev: &Value) -> GtkBox {
    let _ = dev;
    let locked = state.remote_lock.get();
    let box_ = GtkBox::new(Orientation::Vertical, 10);

    let pad = GtkBox::new(Orientation::Vertical, 0);
    pad.add_css_class("card");
    pad.set_size_request(-1, 320);
    pad.set_vexpand(true);
    pad.set_focusable(true);
    if locked {
        let center = Label::new(Some(
            "Alt + X or both mouse buttons to unlock",
        ));
        center.add_css_class("dim-label");
        center.set_vexpand(true);
        pad.append(&center);
    } else {
        let center = Label::new(Some("Click to lock"));
        center.add_css_class("dim-label");
        center.set_vexpand(true);
        pad.append(&center);
    }

    // The pad click is the lock switch. While locked, clicks are
    // claimed earlier by the window capture gesture and forwarded
    // to the phone instead of reaching this handler.
    let gesture = gtk4::GestureClick::new();
    gesture.set_button(0);
    {
        let st = state.clone();
        gesture.connect_pressed(move |_, _, _, _| {
            if !st.remote_lock.get() {
                engage_remote_lock(&st);
            }
        });
    }
    pad.add_controller(gesture);

    box_.append(&pad);
    box_
}

const PLUGIN_META: &[(&str, &str, &str, &str)] = &[
    ("clipboard", "edit-copy-symbolic", "Clipboard sync", "Copy on one device, paste on the other"),
    ("share", "document-send-symbolic", "File sharing", "Send and receive files"),
    ("notification", "preferences-system-notifications-symbolic", "Notifications", "Phone notifications on this desktop, replies included"),
    ("mpris", "media-playback-start-symbolic", "Multimedia control", "Control players on both devices"),
    ("systemvolume", "audio-volume-high-symbolic", "System volume", "Desktop sound sinks in the phone's Devices tab"),
    ("sftp", "folder-remote-symbolic", "Browse device storage", "Mount the phone storage as a drive"),
    ("presenter", "video-display-symbolic", "Presentation remote", "Use the phone as a presentation pointer"),
    ("remoteinput", "input-touchpad-symbolic", "Remote input", "Use the phone as a touchpad and keyboard"),
    ("runcommand", "utilities-terminal-symbolic", "Run commands", "Run predefined commands from the phone"),
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
        if *key_name == "runcommand" {
            group.add(&edit_commands_row(state));
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

fn build_encryption_panel(state: &Rc<AppState>, dev: &Value) -> GtkBox {
    let wrap = GtkBox::new(Orientation::Vertical, 0);
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
    wrap.append(&group);
    wrap
}

fn edit_commands_row(state: &Rc<AppState>) -> adw::ActionRow {
    let row = adw::ActionRow::new();
    row.set_title("Edit commands");
    row.set_subtitle("Commands the phone can run on this computer");
    row.set_activatable(true);
    row.add_suffix(&gtk4::Image::from_icon_name("go-next-symbolic"));
    let st = state.clone();
    row.connect_activated(move |_| {
        let st2 = st.clone();
        gtk4::glib::spawn_future_local(async move {
            let resp = gtk4::gio::spawn_blocking(|| {
                control_request(json!({"cmd": "get_commands"}))
            })
            .await;
            if let Ok(Ok(resp)) = resp {
                if let Some(map) = resp["commands"].as_object() {
                    *st2.commands.borrow_mut() = map.clone();
                }
            }
            *st2.view.borrow_mut() = DetailView::Device;
            *st2.panel.borrow_mut() = Panel::Commands;
            rebuild_detail(&st2);
        });
    });
    row
}

fn build_commands_panel(state: &Rc<AppState>) -> GtkBox {
    let wrap = GtkBox::new(Orientation::Vertical, 12);
    let group = adw::PreferencesGroup::new();
    let cmds = state.commands.borrow().clone();
    if cmds.is_empty() {
        let row = adw::ActionRow::new();
        row.set_title("No commands yet");
        group.add(&row);
    }
    let mut sorted: Vec<(&String, &Value)> = cmds.iter().collect();
    sorted.sort_by(|a, b| {
        a.1["name"]
            .as_str()
            .unwrap_or("")
            .cmp(b.1["name"].as_str().unwrap_or(""))
    });
    for (key, val) in sorted {
        let row = adw::ActionRow::new();
        row.set_title(val["name"].as_str().unwrap_or("Command"));
        let edit = Button::from_icon_name("document-edit-symbolic");
        edit.add_css_class("flat");
        edit.set_tooltip_text(Some("Edit command"));
        edit.set_valign(gtk4::Align::Center);
        {
            let st = state.clone();
            let k = key.clone();
            edit.connect_clicked(move |_| {
                show_command_dialog(&st, Some(k.clone()));
            });
        }
        row.add_suffix(&edit);
        let del = Button::from_icon_name("user-trash-symbolic");
        del.add_css_class("flat");
        del.set_tooltip_text(Some("Delete command"));
        del.set_valign(gtk4::Align::Center);
        {
            let st = state.clone();
            let k = key.clone();
            del.connect_clicked(move |_| {
                st.commands.borrow_mut().remove(&k);
                send_request(json!({"cmd": "set_commands", "commands": Value::Object(st.commands.borrow().clone())}));
                rebuild_detail(&st);
            });
        }
        row.add_suffix(&del);
        group.add(&row);
    }
    wrap.append(&group);
    wrap
}

const SAMPLE_COMMANDS: &[(&str, &str)] = &[
    ("Lock screen", "hyprlock"),
    ("Screenshot", "grim"),
    ("Terminal", "kitty"),
    ("File manager", "nautilus"),
    ("Browser", "firefox"),
    ("Play or pause", "playerctl play-pause"),
    ("Next track", "playerctl next"),
    ("Previous track", "playerctl previous"),
    ("Mute toggle", "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),
    ("Volume up", "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"),
    ("Volume down", "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),
    ("Suspend", "systemctl suspend"),
];

fn show_command_dialog(state: &Rc<AppState>, edit_key: Option<String>) {
    let win = state.window.clone();
    let editing = edit_key.is_some();
    let dialog = adw::Dialog::new();
    dialog.set_title(if editing { "Edit Command" } else { "Add Command" });
    dialog.set_content_width(420);

    let content = GtkBox::new(Orientation::Vertical, 18);
    content.set_margin_start(24);
    content.set_margin_end(24);
    content.set_margin_top(24);
    content.set_margin_bottom(24);

    let heading = Label::new(Some(if editing {
        "Edit Command"
    } else {
        "Add Command"
    }));
    heading.add_css_class("title-2");
    heading.set_halign(gtk4::Align::Start);
    content.append(&heading);

    let group = adw::PreferencesGroup::new();
    let combo = adw::ComboRow::new();
    combo.set_title("Sample commands");
    let mut labels: Vec<&str> = vec!["Choose a sample"];
    labels.extend(SAMPLE_COMMANDS.iter().map(|(n, _)| *n));
    combo.set_model(Some(&gtk4::StringList::new(&labels)));
    let name_entry = adw::EntryRow::new();
    name_entry.set_title("Name");
    let cmd_entry = adw::EntryRow::new();
    cmd_entry.set_title("Command");
    {
        let name_entry = name_entry.clone();
        let cmd_entry = cmd_entry.clone();
        combo.connect_notify_local(Some("selected"), move |c, _| {
            let idx = c.selected();
            if idx >= 1 {
                if let Some((n, cmd)) = SAMPLE_COMMANDS.get((idx - 1) as usize) {
                    name_entry.set_text(n);
                    cmd_entry.set_text(cmd);
                }
            }
        });
    }
    if let Some(k) = &edit_key {
        if let Some(val) = state.commands.borrow().get(k) {
            name_entry.set_text(val["name"].as_str().unwrap_or(""));
            cmd_entry.set_text(val["command"].as_str().unwrap_or(""));
        }
    }
    group.add(&name_entry);
    group.add(&cmd_entry);
    group.add(&combo);
    content.append(&group);

    let buttons = GtkBox::new(Orientation::Horizontal, 12);
    buttons.set_homogeneous(true);
    let cancel = Button::with_label("Cancel");
    {
        let d = dialog.clone();
        cancel.connect_clicked(move |_| {
            d.close();
        });
    }
    let add = Button::with_label(if editing { "Save" } else { "Add" });
    add.add_css_class("suggested-action");
    {
        let st = state.clone();
        let d = dialog.clone();
        let name_entry = name_entry.clone();
        let cmd_entry = cmd_entry.clone();
        add.connect_clicked(move |_| {
            let name = name_entry.text().trim().to_string();
            let command = cmd_entry.text().trim().to_string();
            if name.is_empty() || command.is_empty() {
                return;
            }
            let key = edit_key.clone().unwrap_or_else(|| {
                format!(
                    "cmd{}",
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|t| t.as_millis())
                        .unwrap_or(0)
                )
            });
            st.commands
                .borrow_mut()
                .insert(key, json!({"name": name, "command": command}));
            send_request(json!({"cmd": "set_commands", "commands": Value::Object(st.commands.borrow().clone())}));
            d.close();
            rebuild_detail(&st);
        });
    }
    buttons.append(&cancel);
    buttons.append(&add);
    content.append(&buttons);

    dialog.set_child(Some(&content));
    dialog.present(Some(&win));
}


/// Pointer lock on GTK's own Wayland connection.
///
/// GTK 4.24 exports no seat grab, so the remote input lock speaks
/// zwp_pointer_constraints directly: a wayland-client connection
/// layered over the wl_display GTK already owns (the backend's
/// foreign-display mode), GDK's wl_surface and wl_pointer adopted
/// as request arguments, and our own lock and relative-pointer
/// objects on a private event queue pumped from the main loop.
/// While locked the cursor freezes where it sits on the pad and
/// relative motion streams to the phone instead.
mod plock {
    use super::*;
    use gtk4::glib::translate::*;
    use std::os::fd::AsRawFd;
    use wayland_client::backend::ObjectId;
    use wayland_client::protocol::{wl_pointer::WlPointer, wl_registry, wl_surface::WlSurface};
    use wayland_client::{Connection, Dispatch, Proxy, QueueHandle};
    use wayland_protocols::wp::pointer_constraints::zv1::client::{
        zwp_locked_pointer_v1::{self, ZwpLockedPointerV1},
        zwp_pointer_constraints_v1::{Lifetime, ZwpPointerConstraintsV1},
    };
    use wayland_protocols::wp::relative_pointer::zv1::client::{
        zwp_relative_pointer_manager_v1::ZwpRelativePointerManagerV1,
        zwp_relative_pointer_v1::{self, ZwpRelativePointerV1},
    };

    extern "C" {
        fn gdk_wayland_display_get_wl_display(
            display: *mut std::ffi::c_void,
        ) -> *mut std::ffi::c_void;
        fn gdk_wayland_surface_get_wl_surface(
            surface: *mut std::ffi::c_void,
        ) -> *mut std::ffi::c_void;
        fn gdk_wayland_device_get_wl_pointer(
            device: *mut std::ffi::c_void,
        ) -> *mut std::ffi::c_void;
    }

    pub struct LockState {
        constraints: Option<ZwpPointerConstraintsV1>,
        rel_mgr: Option<ZwpRelativePointerManagerV1>,
        locked_obj: Option<ZwpLockedPointerV1>,
        rel_obj: Option<ZwpRelativePointerV1>,
        pending: (f64, f64),
        last_send: i64,
        on_motion: Rc<dyn Fn(f64, f64)>,
        on_lock: Rc<dyn Fn(bool)>,
    }

    pub struct Session {
        conn: Connection,
        queue: wayland_client::EventQueue<LockState>,
        state: LockState,
        surface: WlSurface,
        pointer: WlPointer,
    }

    impl Session {
        pub fn connect_gtk(app: &Rc<AppState>) -> Option<Session> {
            let display: gtk4::gdk::Display =
                gtk4::prelude::WidgetExt::display(&app.window);
            let seat = display.default_seat()?;
            let pointer_dev = seat.pointer()?;
            let gdk_surface: gtk4::gdk::Surface =
                gtk4::prelude::NativeExt::surface(&app.window)?;
            unsafe {
                let display_ptr: *mut gtk4::gdk::ffi::GdkDisplay = display.to_glib_none().0;
                let surface_ptr: *mut gtk4::gdk::ffi::GdkSurface = gdk_surface.to_glib_none().0;
                let device_ptr: *mut gtk4::gdk::ffi::GdkDevice = pointer_dev.to_glib_none().0;
                let wl_display =
                    gdk_wayland_display_get_wl_display(display_ptr as *mut std::ffi::c_void);
                let wl_surface_ptr =
                    gdk_wayland_surface_get_wl_surface(surface_ptr as *mut std::ffi::c_void);
                let wl_pointer_ptr =
                    gdk_wayland_device_get_wl_pointer(device_ptr as *mut std::ffi::c_void);
                if wl_display.is_null() || wl_surface_ptr.is_null() || wl_pointer_ptr.is_null() {
                    return None;
                }
                let backend = wayland_backend::client::Backend::from_foreign_display(
                    wl_display as *mut _,
                );
                let conn = Connection::from_backend(backend);
                let surface_id =
                    ObjectId::from_ptr(WlSurface::interface(), wl_surface_ptr as *mut _)
                        .ok()?;
                let surface = WlSurface::from_id(&conn, surface_id).ok()?;
                let pointer_id =
                    ObjectId::from_ptr(WlPointer::interface(), wl_pointer_ptr as *mut _)
                        .ok()?;
                let pointer = WlPointer::from_id(&conn, pointer_id).ok()?;
                let mut queue = conn.new_event_queue::<LockState>();
                let qh = queue.handle();
                let _registry = conn.display().get_registry(&qh, ());
                let st_motion = app.clone();
                let st_lock = app.clone();
                let mut state = LockState {
                    constraints: None,
                    rel_mgr: None,
                    locked_obj: None,
                    rel_obj: None,
                    pending: (0.0, 0.0),
                    last_send: 0,
                    on_motion: Rc::new(move |dx: f64, dy: f64| {
                        send_mousepad(
                            &st_motion,
                            json!({"dx": dx.round() as i64, "dy": dy.round() as i64}),
                        );
                    }),
                    on_lock: Rc::new(move |locked: bool| {
                        st_lock.remote_lock.set(locked);
                        rebuild_detail(&st_lock);
                    }),
                };
                let _ = conn.flush();
                let mut sess = Session {
                    conn,
                    queue,
                    state,
                    surface,
                    pointer,
                };
                // Pump until both globals are bound (bounded).
                for _ in 0..60 {
                    if sess.state.constraints.is_some() && sess.state.rel_mgr.is_some() {
                        break;
                    }
                    sess.pump();
                    std::thread::sleep(std::time::Duration::from_millis(5));
                }
                if sess.state.constraints.is_none() || sess.state.rel_mgr.is_none() {
                    eprintln!("remote input: compositor lacks pointer constraints");
                    return None;
                }
                Some(sess)
            }
        }

        pub fn lock(&mut self) -> bool {
            if self.state.locked_obj.is_some() {
                return true;
            }
            let (Some(constraints), Some(rel_mgr)) =
                (&self.state.constraints, &self.state.rel_mgr)
            else {
                return false;
            };
            let qh = self.queue.handle();
            let locked = constraints.lock_pointer(
                &self.surface,
                &self.pointer,
                None,
                Lifetime::Oneshot,
                &qh,
                (),
            );
            let rel = rel_mgr.get_relative_pointer(&self.pointer, &qh, ());
            self.state.locked_obj = Some(locked);
            self.state.rel_obj = Some(rel);
            let _ = self.conn.flush();
            true
        }

        pub fn unlock(&mut self) {
            // The libwayland backend does NOT send destructor
            // requests when a proxy is dropped (it only frees the
            // proxy locally), so destroy both objects explicitly or
            // the compositor keeps the pointer locked forever.
            if let Some(locked) = self.state.locked_obj.take() {
                locked.destroy();
            }
            if let Some(rel) = self.state.rel_obj.take() {
                rel.destroy();
            }
            let _ = self.conn.flush();
        }

        pub fn pump(&mut self) {
            if let Some(guard) = self.queue.prepare_read() {
                let fd = self.conn.backend().poll_fd().as_raw_fd();
                let mut pfd = libc::pollfd {
                    fd,
                    events: libc::POLLIN,
                    revents: 0,
                };
                let r = unsafe { libc::poll(&mut pfd, 1, 0) };
                if r > 0 && (pfd.revents & libc::POLLIN) != 0 {
                    let _ = guard.read();
                }
            }
            let _ = self.queue.dispatch_pending(&mut self.state);
            let _ = self.conn.flush();
        }
    }

    impl Dispatch<wl_registry::WlRegistry, ()> for LockState {
        fn event(
            state: &mut Self,
            registry: &wl_registry::WlRegistry,
            event: wl_registry::Event,
            _: &(),
            _: &Connection,
            qh: &QueueHandle<Self>,
        ) {
            if let wl_registry::Event::Global {
                name,
                interface,
                version,
            } = event
            {
                match interface.as_str() {
                    "zwp_pointer_constraints_v1" => {
                        state.constraints = Some(
                            registry.bind::<ZwpPointerConstraintsV1, _, _>(
                                name,
                                1.min(version),
                                qh,
                                (),
                            ),
                        );
                    }
                    "zwp_relative_pointer_manager_v1" => {
                        state.rel_mgr = Some(
                            registry.bind::<ZwpRelativePointerManagerV1, _, _>(
                                name,
                                1.min(version),
                                qh,
                                (),
                            ),
                        );
                    }
                    _ => {}
                }
            }
        }
    }

    impl Dispatch<ZwpLockedPointerV1, ()> for LockState {
        fn event(
            state: &mut Self,
            _: &ZwpLockedPointerV1,
            event: zwp_locked_pointer_v1::Event,
            _: &(),
            _: &Connection,
            _: &QueueHandle<Self>,
        ) {
            match event {
                zwp_locked_pointer_v1::Event::Locked => (state.on_lock)(true),
                zwp_locked_pointer_v1::Event::Unlocked => {
                    if let Some(locked) = state.locked_obj.take() {
                        locked.destroy();
                    }
                    if let Some(rel) = state.rel_obj.take() {
                        rel.destroy();
                    }
                    (state.on_lock)(false);
                }
                _ => {}
            }
        }
    }

    impl Dispatch<ZwpRelativePointerV1, ()> for LockState {
        fn event(
            state: &mut Self,
            _: &ZwpRelativePointerV1,
            event: zwp_relative_pointer_v1::Event,
            _: &(),
            _: &Connection,
            _: &QueueHandle<Self>,
        ) {
            if let zwp_relative_pointer_v1::Event::RelativeMotion { dx, dy, .. } = event {
                state.pending.0 += dx;
                state.pending.1 += dy;
                let now = gtk4::glib::monotonic_time() / 1000;
                if now - state.last_send >= 24 {
                    let (x, y) = state.pending;
                    if x.abs() >= 0.5 || y.abs() >= 0.5 {
                        state.pending = (0.0, 0.0);
                        state.last_send = now;
                        (state.on_motion)(x, y);
                    }
                }
            }
        }
    }

    wayland_client::delegate_noop!(LockState: ignore ZwpPointerConstraintsV1);
    wayland_client::delegate_noop!(LockState: ignore ZwpRelativePointerManagerV1);
}

enum CheckOutcome {
    UpToDate,
    Available(ReleaseInfo),
    Failed(String),
}

/// Check GitHub Releases for a newer HyprConnect on a blocking
/// thread. A manual check always reports its outcome; the
/// automatic startup check only speaks up when an update exists.
fn check_updates(window: &adw::ApplicationWindow, manual: bool) {
    let win = window.clone();
    gtk4::glib::spawn_future_local(async move {
        let fetched = gtk4::gio::spawn_blocking(|| match update::fetch_latest() {
            Ok(latest) => {
                if update::is_newer(&latest.tag, &update::current_tag()) {
                    CheckOutcome::Available(latest)
                } else {
                    CheckOutcome::UpToDate
                }
            }
            Err(e) => CheckOutcome::Failed(format!("{e:#}")),
        })
        .await;
        let Ok(outcome) = fetched else {
            return;
        };
        match outcome {
            CheckOutcome::Available(info) => show_update_dialog(&win, &info),
            CheckOutcome::UpToDate if manual => show_info_dialog(
                &win,
                "No update available",
                &format!(
                    "HyprConnect {} is the latest version.",
                    update::current_tag()
                ),
            ),
            CheckOutcome::Failed(message) if manual => {
                show_info_dialog(&win, "Update check failed", &message)
            }
            _ => {}
        }
    });
}

fn show_info_dialog(window: &adw::ApplicationWindow, heading: &str, body: &str) {
    let dialog = adw::AlertDialog::new(Some(heading), Some(body));
    dialog.add_response("ok", "OK");
    dialog.set_default_response(Some("ok"));
    dialog.set_close_response("ok");
    dialog.present(Some(window));
}

fn show_update_dialog(window: &adw::ApplicationWindow, info: &ReleaseInfo) {
    let mut body = format!(
        "HyprConnect {} is available. You have {}.",
        info.tag,
        update::current_tag()
    );
    let notes = info.notes.trim();
    if !notes.is_empty() {
        let short: String = notes.chars().take(600).collect();
        body.push_str("\n\n");
        body.push_str(&short);
    }
    let dialog = adw::AlertDialog::new(Some("Update available"), Some(&body));
    dialog.add_response("later", "Later");
    dialog.add_response("update", "Update Now");
    dialog.set_response_appearance("update", adw::ResponseAppearance::Suggested);
    dialog.set_default_response(Some("update"));
    dialog.set_close_response("later");
    let win = window.clone();
    let info = info.clone();
    dialog.connect_response(None, move |_, response| {
        if response == "update" {
            run_update_install(&win, &info);
        }
    });
    dialog.present(Some(window));
}

/// Download and install the release (both desktop binaries),
/// restart the daemon, and offer to restart the app onto its
/// new binary.
fn run_update_install(window: &adw::ApplicationWindow, info: &ReleaseInfo) {
    let win = window.clone();
    let info = info.clone();
    gtk4::glib::spawn_future_local(async move {
        let fetched = gtk4::gio::spawn_blocking(move || -> Result<(), String> {
            if !info.has_desktop_assets() {
                return Err("The release carries no desktop binaries.".to_string());
            }
            update::install_release(&info).map_err(|e| format!("{e:#}"))?;
            update::restart_daemon().map_err(|e| format!("{e:#}"))?;
            Ok(())
        })
        .await;
        match fetched {
            Ok(Ok(())) => {
                let dialog = adw::AlertDialog::new(
                    Some("Update installed"),
                    Some(
                        "The daemon has been restarted. Restart HyprConnect \
                         to use the new version.",
                    ),
                );
                dialog.add_response("later", "Later");
                dialog.add_response("restart", "Restart Now");
                dialog.set_response_appearance(
                    "restart",
                    adw::ResponseAppearance::Suggested,
                );
                dialog.set_default_response(Some("restart"));
                dialog.set_close_response("later");
                dialog.connect_response(None, move |_, response| {
                    if response == "restart" {
                        if let Ok(exe) = std::env::current_exe() {
                            let _ = std::process::Command::new(exe).spawn();
                        }
                        std::process::exit(0);
                    }
                });
                dialog.present(Some(&win));
            }
            Ok(Err(message)) => show_info_dialog(&win, "Update failed", &message),
            Err(_) => show_info_dialog(&win, "Update failed", "The update task failed."),
        }
    });
}
