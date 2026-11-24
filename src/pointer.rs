//! Remote input pointer: a virtual pointer device created
//! through zwlr_virtual_pointer_manager_v1 and driven by the
//! phone's touchpad packets. Living inside the daemon keeps
//! remote input free of per-event helper processes: motion,
//! buttons and scroll are requests on a Wayland connection, and
//! the thread sleeps in poll until a command or a compositor
//! event arrives. An eventfd written by the sending side wakes
//! it instantly, so motion never waits out a poll timeout.

use std::os::fd::{AsFd, AsRawFd, FromRawFd};
use std::sync::mpsc as std_mpsc;
use std::sync::Arc;
use std::time::Instant;

use anyhow::Context;
use wayland_client::protocol::{
    wl_pointer::{Axis, ButtonState},
    wl_registry::WlRegistry,
    wl_seat::WlSeat,
};
use wayland_client::{Connection, Dispatch, Proxy, QueueHandle};
use wayland_protocols_wlr::virtual_pointer::v1::client::{
    zwlr_virtual_pointer_manager_v1::ZwlrVirtualPointerManagerV1,
    zwlr_virtual_pointer_v1::ZwlrVirtualPointerV1,
};

#[derive(Debug, Clone, Copy)]
pub enum PointerCmd {
    Move { dx: f64, dy: f64 },
    Button { code: u32, pressed: bool },
    Axis { dx: f64, dy: f64 },
}

#[derive(Clone)]
pub struct PointerHandle {
    cmd_tx: std_mpsc::Sender<PointerCmd>,
    wake: Arc<std::fs::File>,
}

impl PointerHandle {
    fn send(&self, cmd: PointerCmd) {
        if self.cmd_tx.send(cmd).is_ok() {
            let buf = 1u64.to_ne_bytes();
            unsafe {
                libc::write(
                    self.wake.as_raw_fd(),
                    buf.as_ptr() as *const libc::c_void,
                    buf.len(),
                );
            }
        }
    }
    pub fn move_by(&self, dx: f64, dy: f64) {
        self.send(PointerCmd::Move { dx, dy });
    }
    pub fn button(&self, code: u32, pressed: bool) {
        self.send(PointerCmd::Button { code, pressed });
    }
    pub fn click(&self, code: u32) {
        self.button(code, true);
        self.button(code, false);
    }
    pub fn axis(&self, dx: f64, dy: f64) {
        self.send(PointerCmd::Axis { dx, dy });
    }
}

pub fn spawn(log: impl Fn(&str) + Send + 'static) -> Option<PointerHandle> {
    let fd = unsafe {
        libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK)
    };
    if fd < 0 {
        return None;
    }
    let wake = Arc::new(unsafe { std::fs::File::from_raw_fd(fd) });
    let (cmd_tx, cmd_rx) = std_mpsc::channel::<PointerCmd>();
    let wake_read = wake.clone();
    std::thread::Builder::new()
        .name("remote-pointer".into())
        .spawn(move || match run(cmd_rx, &wake_read, &log) {
            Ok(()) => {}
            Err(e) => log(&format!("remote input pointer unavailable: {:#}", e)),
        })
        .ok()?;
    Some(PointerHandle { cmd_tx, wake })
}

struct PointerState {
    seat: Option<WlSeat>,
    manager: Option<ZwlrVirtualPointerManagerV1>,
}

impl Dispatch<WlRegistry, u32> for PointerState {
    fn event(
        state: &mut Self,
        registry: &WlRegistry,
        event: wayland_client::protocol::wl_registry::Event,
        _: &u32,
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let wayland_client::protocol::wl_registry::Event::Global {
            name,
            interface,
            version,
        } = event
        {
            match interface.as_str() {
                "wl_seat" => {
                    state.seat = Some(registry.bind(name, version.min(7), qh, ()));
                }
                "zwlr_virtual_pointer_manager_v1" => {
                    state.manager =
                        Some(registry.bind(name, version.min(2), qh, ()));
                }
                _ => {}
            }
        }
    }
}

impl Dispatch<WlSeat, ()> for PointerState {
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

impl Dispatch<ZwlrVirtualPointerManagerV1, ()> for PointerState {
    fn event(
        _: &mut Self,
        _: &ZwlrVirtualPointerManagerV1,
        _: <ZwlrVirtualPointerManagerV1 as Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ZwlrVirtualPointerV1, ()> for PointerState {
    fn event(
        _: &mut Self,
        _: &ZwlrVirtualPointerV1,
        _: <ZwlrVirtualPointerV1 as Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

fn apply(
    pointer: &ZwlrVirtualPointerV1,
    start: Instant,
    cmd: PointerCmd,
) {
    let time = start.elapsed().as_millis() as u32;
    match cmd {
        PointerCmd::Move { dx, dy } => {
            pointer.motion(time, dx, dy);
        }
        PointerCmd::Button { code, pressed } => {
            pointer.button(
                time,
                code,
                if pressed {
                    ButtonState::Pressed
                } else {
                    ButtonState::Released
                },
            );
        }
        PointerCmd::Axis { dx, dy } => {
            if dy != 0.0 {
                pointer.axis(time, Axis::VerticalScroll, dy);
            }
            if dx != 0.0 {
                pointer.axis(time, Axis::HorizontalScroll, dx);
            }
        }
    }
    pointer.frame();
}

fn run(
    cmd_rx: std_mpsc::Receiver<PointerCmd>,
    wake: &std::fs::File,
    log: &dyn Fn(&str),
) -> anyhow::Result<()> {
    let conn = crate::wayland::connect("remote input pointer", log);
    let mut queue = conn.new_event_queue::<PointerState>();
    let qh = queue.handle();
    let _registry = conn.display().get_registry(&qh, 0u32);
    let mut state = PointerState {
        seat: None,
        manager: None,
    };
    queue.roundtrip(&mut state).context("registry roundtrip")?;
    let Some(manager) = state.manager.clone() else {
        anyhow::bail!(
            "compositor does not offer zwlr_virtual_pointer_manager_v1"
        );
    };
    let pointer = manager.create_virtual_pointer(state.seat.as_ref(), &qh, ());
    let start = Instant::now();
    let conn_fd = conn.as_fd();
    loop {
        while let Ok(cmd) = cmd_rx.try_recv() {
            apply(&pointer, start, cmd);
        }
        queue.dispatch_pending(&mut state)?;
        conn.flush()?;
        if let Some(guard) = queue.prepare_read() {
            let mut pfds = [
                libc::pollfd {
                    fd: conn_fd.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                },
                libc::pollfd {
                    fd: wake.as_raw_fd(),
                    events: libc::POLLIN,
                    revents: 0,
                },
            ];
            let ready = unsafe { libc::poll(pfds.as_mut_ptr(), 2, 1000) };
            if ready > 0 {
                if pfds[1].revents & libc::POLLIN != 0 {
                    let mut buf = [0u8; 8];
                    unsafe {
                        libc::read(
                            wake.as_raw_fd(),
                            buf.as_mut_ptr() as *mut libc::c_void,
                            buf.len(),
                        );
                    }
                }
                if pfds[0].revents & libc::POLLIN != 0 {
                    let _ = guard.read();
                } else {
                    drop(guard);
                }
            } else {
                drop(guard);
            }
        }
    }
}
