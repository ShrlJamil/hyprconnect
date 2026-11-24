//! Wayland clipboard bridge (ext-data-control-v1).
//!
//! One thread owns a Wayland connection: it watches the seat's
//! selection and reports text changes, and it serves clipboard
//! content set by the daemon (from a paired device). Guards against
//! echo loops live in the daemon; this module is transport only.

use std::collections::HashMap;
use std::io::Read;
use std::os::fd::{AsFd, AsRawFd, FromRawFd, OwnedFd};
use std::sync::mpsc as std_mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use wayland_client::protocol::wl_seat::WlSeat;
use wayland_client::globals::GlobalListContents;
use wayland_client::protocol::wl_registry::WlRegistry;
use wayland_client::{Connection, Dispatch, Proxy, QueueHandle};
use wayland_protocols::ext::data_control::v1::client::ext_data_control_device_v1::{
    self, ExtDataControlDeviceV1,
};
use wayland_protocols::ext::data_control::v1::client::ext_data_control_manager_v1::ExtDataControlManagerV1;
use wayland_protocols::ext::data_control::v1::client::ext_data_control_offer_v1::{
    self, ExtDataControlOfferV1,
};
use wayland_protocols::ext::data_control::v1::client::ext_data_control_source_v1::{
    self, ExtDataControlSourceV1,
};

pub enum ClipboardCmd {
    Set(String),
}

pub struct ClipboardHandle {
    pub cmd_tx: std_mpsc::Sender<ClipboardCmd>,
    /// Latest text known to sit in the local clipboard.
    pub current: Arc<Mutex<Option<String>>>,
}

struct OfferState {
    mimes: Vec<String>,
}

struct WlState {
    offers: HashMap<wayland_client::backend::ObjectId, (ExtDataControlOfferV1, OfferState)>,
    selection_offer: Option<ExtDataControlOfferV1>,
    our_source: Option<ExtDataControlSourceV1>,
    our_content: Option<String>,
    changed_tx: tokio::sync::mpsc::Sender<String>,
    current: Arc<Mutex<Option<String>>>,
}

impl WlState {
    fn report_read(&mut self, text: String) {
        if text.is_empty() {
            return;
        }
        *self.current.lock().unwrap() = Some(text.clone());
        let _ = self.changed_tx.try_send(text);
    }
}

/// Read the current selection from the offer that owns it, if it has
/// a plain-text mime type.
fn read_selection(state: &mut WlState, conn: &Connection) {
    let Some(offer) = state.selection_offer.clone() else {
        return;
    };
    let Some((_, offer_state)) = state.offers.get(&offer.id()) else {
        return;
    };
    let mime = ["text/plain;charset=utf-8", "text/plain"]
        .iter()
        .find(|m| offer_state.mimes.iter().any(|x| x == *m))
        .map(|m| *m)
        .or_else(|| {
            offer_state
                .mimes
                .iter()
                .find(|m| m.starts_with("text/plain"))
                .map(|m| m.as_str())
        });
    let Some(mime) = mime else { return };
    let mut fds: [std::os::fd::RawFd; 2] = [-1, -1];
    let rc = unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) };
    if rc != 0 {
        return;
    }
    let (read_fd, write_fd) = unsafe {
        (
            OwnedFd::from_raw_fd(fds[0]),
            OwnedFd::from_raw_fd(fds[1]),
        )
    };
    offer.receive(mime.to_string(), write_fd.as_fd());
    drop(write_fd);
    // The receive request must reach the compositor before we start
    // reading, or the source never sees it and the pipe stays silent.
    let _ = conn.flush();
    // The source writes promptly; poll briefly and read to EOF.
    let mut file = std::fs::File::from(read_fd);
    let mut data = Vec::new();
    let mut buf = [0u8; 8192];
    let deadline = std::time::Instant::now() + Duration::from_millis(600);
    loop {
        let mut pfd = libc::pollfd {
            fd: file.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        let ready = unsafe { libc::poll(&mut pfd, 1, 60) };
        if ready > 0 {
            match file.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    data.extend_from_slice(&buf[..n]);
                    if data.len() > 1_000_000 {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        if std::time::Instant::now() > deadline {
            break;
        }
    }
    if let Ok(text) = String::from_utf8(data) {
        state.report_read(text);
    }
}

impl Dispatch<WlRegistry, GlobalListContents> for WlState {
    fn event(
        _: &mut Self,
        _: &WlRegistry,
        _: <WlRegistry as Proxy>::Event,
        _: &GlobalListContents,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<WlSeat, ()> for WlState {
    fn event(
        _: &mut Self,
        _: &WlSeat,
        _: <WlSeat as Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ExtDataControlManagerV1, ()> for WlState {
    fn event(
        _: &mut Self,
        _: &ExtDataControlManagerV1,
        _: <ExtDataControlManagerV1 as Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ExtDataControlDeviceV1, ()> for WlState {
    // The data_offer event creates the offer object (opcode 0).
    wayland_client::event_created_child!(
        WlState,
        ExtDataControlDeviceV1,
        [0 => (ExtDataControlOfferV1, ())]
    );

    fn event(
        state: &mut Self,
        device: &ExtDataControlDeviceV1,
        event: <ExtDataControlDeviceV1 as Proxy>::Event,
        _: &(),
        conn: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        match event {
            ext_data_control_device_v1::Event::DataOffer { id } => {
                state.offers.insert(
                    id.id(),
                    (id, OfferState { mimes: Vec::new() }),
                );
            }
            ext_data_control_device_v1::Event::Selection { id } => {
                state.selection_offer = id;
                let _ = device;
                let _ = qh;
                read_selection(state, conn);
            }
            ext_data_control_device_v1::Event::Finished => {}
            ext_data_control_device_v1::Event::PrimarySelection { .. } => {}
            _ => {}
        }
    }
}

impl Dispatch<ExtDataControlOfferV1, ()> for WlState {
    fn event(
        state: &mut Self,
        offer: &ExtDataControlOfferV1,
        event: <ExtDataControlOfferV1 as Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let ext_data_control_offer_v1::Event::Offer { mime_type } = event {
            if let Some(entry) = state.offers.get_mut(&offer.id()) {
                entry.1.mimes.push(mime_type);
            }
        }
    }
}

impl Dispatch<ExtDataControlSourceV1, ()> for WlState {
    fn event(
        state: &mut Self,
        source: &ExtDataControlSourceV1,
        event: <ExtDataControlSourceV1 as Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            ext_data_control_source_v1::Event::Send { mime_type: _, fd } => {
                if let Some(content) = &state.our_content {
                    let mut file = std::fs::File::from(fd);
                    use std::io::Write;
                    let _ = file.write_all(content.as_bytes());
                }
            }
            ext_data_control_source_v1::Event::Cancelled => {
                if state.our_source.as_ref().map(|s| s.id()) == Some(source.id()) {
                    state.our_source = None;
                    state.our_content = None;
                }
            }
            _ => {}
        }
    }
}

/// Spawn the clipboard thread. The thread waits for a Wayland
/// compositor when the daemon starts before the graphical session;
/// the daemon's network side runs fine in the meantime.
pub fn spawn(
    changed_tx: tokio::sync::mpsc::Sender<String>,
    log: impl Fn(&str) + Send + 'static,
) -> Option<ClipboardHandle> {
    let (cmd_tx, cmd_rx) = std_mpsc::channel::<ClipboardCmd>();
    let current: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let current_thread = current.clone();
    std::thread::Builder::new()
        .name("clipboard".into())
        .spawn(move || {
            if let Err(e) = run(cmd_rx, changed_tx, current_thread, &log) {
                log(&format!("clipboard unavailable: {:#}", e));
            }
        })
        .ok()?;
    Some(ClipboardHandle { cmd_tx, current })
}

fn run(
    cmd_rx: std_mpsc::Receiver<ClipboardCmd>,
    changed_tx: tokio::sync::mpsc::Sender<String>,
    current: Arc<Mutex<Option<String>>>,
    log: &dyn Fn(&str),
) -> anyhow::Result<()> {
    use anyhow::Context;
    let conn = crate::wayland::connect("clipboard", log);
    let (globals, mut queue) =
        wayland_client::globals::registry_queue_init::<WlState>(&conn)
            .context("registry init")?;
    let qh = queue.handle();
    let seat: WlSeat = globals.bind(&qh, 1..=5, ()).context("bind wl_seat")?;
    let manager: ExtDataControlManagerV1 = globals
        .bind(&qh, 1..=1, ())
        .context("bind ext_data_control_manager_v1")?;
    let device = manager.get_data_device(&seat, &qh, ());
    let mut state = WlState {
        offers: HashMap::new(),
        selection_offer: None,
        our_source: None,
        our_content: None,
        changed_tx,
        current,
    };
    queue.roundtrip(&mut state).context("initial roundtrip")?;
    log("clipboard watcher active (ext-data-control-v1)");
    let conn_fd = conn.as_fd();
    loop {
        // Apply pending commands from the daemon.
        while let Ok(cmd) = cmd_rx.try_recv() {
            match cmd {
                ClipboardCmd::Set(text) => {
                    let source = manager.create_data_source(&qh, ());
                    source.offer("text/plain;charset=utf-8".to_string());
                    source.offer("text/plain".to_string());
                    device.set_selection(Some(&source));
                    state.our_source = Some(source);
                    state.our_content = Some(text);
                }
            }
        }
        queue.dispatch_pending(&mut state)?;
        conn.flush()?;
        // Wait briefly for compositor events.
        if let Some(guard) = queue.prepare_read() {
            let mut pfd = libc::pollfd {
                fd: conn_fd.as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            let ready = unsafe { libc::poll(&mut pfd, 1, 100) };
            if ready > 0 {
                let _ = guard.read();
            } else {
                drop(guard);
            }
        }
    }
}
