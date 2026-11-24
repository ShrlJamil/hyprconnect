//! Presenter laser dot: a click-through layer-shell overlay that
//! draws the red pointer dot, the same way the reference desktop
//! presenter renders it (a fullscreen transparent overlay with the
//! dot at a fractional position), instead of moving the system
//! cursor. The dot follows upstream's look: red fill, thin white
//! border, about 80% opacity, diameter near width/150.

use std::os::fd::{AsFd, AsRawFd, FromRawFd};
use std::sync::Arc;
use std::sync::mpsc as std_mpsc;

use anyhow::Context;
use wayland_client::protocol::{
    wl_buffer::WlBuffer,
    wl_compositor::WlCompositor,
    wl_output::WlOutput,
    wl_region::WlRegion,
    wl_registry::WlRegistry,
    wl_shm::{self, WlShm},
    wl_shm_pool::WlShmPool,
    wl_surface::WlSurface,
};
use wayland_client::{Connection, Dispatch, Proxy, QueueHandle};
use wayland_protocols_wlr::layer_shell::v1::client::{
    zwlr_layer_shell_v1::{Layer, ZwlrLayerShellV1},
    zwlr_layer_surface_v1::{Anchor, KeyboardInteractivity, ZwlrLayerSurfaceV1},
};

#[derive(Debug, Clone)]
pub enum DotCmd {
    Show { output: String },
    Move { x: f64, y: f64 },
    Hide,
}

#[derive(Clone)]
pub struct DotHandle {
    cmd_tx: std_mpsc::Sender<DotCmd>,
    wake: Arc<std::fs::File>,
}

impl DotHandle {
    fn send(&self, cmd: DotCmd) {
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
    pub fn show(&self, output: &str) {
        self.send(DotCmd::Show {
            output: output.to_string(),
        });
    }
    pub fn move_to(&self, x: f64, y: f64) {
        self.send(DotCmd::Move { x, y });
    }
    pub fn hide(&self) {
        self.send(DotCmd::Hide);
    }
}

pub fn spawn(log: impl Fn(&str) + Send + 'static) -> Option<DotHandle> {
    let fd = unsafe { libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK) };
    if fd < 0 {
        return None;
    }
    let wake = Arc::new(unsafe { std::fs::File::from_raw_fd(fd) });
    let (cmd_tx, cmd_rx) = std_mpsc::channel::<DotCmd>();
    let wake_read = wake.clone();
    std::thread::Builder::new()
        .name("presenter-dot".into())
        .spawn(move || match run(cmd_rx, &wake_read, &log) {
            Ok(()) => {}
            Err(e) => log(&format!("presenter dot unavailable: {:#}", e)),
        })
        .ok()?;
    Some(DotHandle { cmd_tx, wake })
}

struct OutputInfo {
    proxy: WlOutput,
    name: String,
    scale: i32,
}

struct Slot {
    buffer: WlBuffer,
    busy: bool,
    drawn: Option<(i32, i32)>,
}

struct Shown {
    surface: WlSurface,
    layer: ZwlrLayerSurfaceV1,
    output_name: String,
    scale: i32,
    logical: Option<(u32, u32)>,
    mem: *mut u8,
    mem_len: usize,
    _file: Option<std::fs::File>,
    slots: Vec<Slot>,
    redraw_pending: bool,
}

struct DotState {
    outputs: Vec<OutputInfo>,
    compositor: Option<WlCompositor>,
    shm: Option<WlShm>,
    layer_shell: Option<ZwlrLayerShellV1>,
    fx: f64,
    fy: f64,
    shown: Option<Shown>,
}

impl Dispatch<WlRegistry, u32> for DotState {
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
                "wl_compositor" => {
                    state.compositor =
                        Some(registry.bind(name, version.min(6), qh, ()));
                }
                "wl_shm" => {
                    state.shm = Some(registry.bind(name, 1, qh, ()));
                }
                "zwlr_layer_shell_v1" => {
                    state.layer_shell =
                        Some(registry.bind(name, version.min(4), qh, ()));
                }
                "wl_output" => {
                    let idx = state.outputs.len();
                    let proxy: WlOutput =
                        registry.bind(name, version.min(4), qh, idx);
                    state.outputs.push(OutputInfo {
                        proxy,
                        name: String::new(),
                        scale: 1,
                    });
                }
                _ => {}
            }
        }
    }
}

impl Dispatch<WlOutput, usize> for DotState {
    fn event(
        state: &mut Self,
        _: &WlOutput,
        event: wayland_client::protocol::wl_output::Event,
        idx: &usize,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let Some(out) = state.outputs.get_mut(*idx) else {
            return;
        };
        match event {
            wayland_client::protocol::wl_output::Event::Name { name } => {
                out.name = name;
            }
            wayland_client::protocol::wl_output::Event::Scale { factor } => {
                out.scale = factor.max(1);
            }
            _ => {}
        }
    }
}

impl Dispatch<WlCompositor, ()> for DotState {
    fn event(
        _: &mut Self,
        _: &WlCompositor,
        _: <WlCompositor as Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<WlShm, ()> for DotState {
    fn event(
        _: &mut Self,
        _: &WlShm,
        _: <WlShm as Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<WlShmPool, ()> for DotState {
    fn event(
        _: &mut Self,
        _: &WlShmPool,
        _: <WlShmPool as Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<WlSurface, ()> for DotState {
    fn event(
        _: &mut Self,
        _: &WlSurface,
        _: <WlSurface as Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<WlRegion, ()> for DotState {
    fn event(
        _: &mut Self,
        _: &WlRegion,
        _: <WlRegion as Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<ZwlrLayerShellV1, ()> for DotState {
    fn event(
        _: &mut Self,
        _: &ZwlrLayerShellV1,
        _: <ZwlrLayerShellV1 as Proxy>::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<WlBuffer, ()> for DotState {
    fn event(
        state: &mut Self,
        proxy: &WlBuffer,
        event: wayland_client::protocol::wl_buffer::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let wayland_client::protocol::wl_buffer::Event::Release = event {
            let mut redraw = false;
            if let Some(shown) = &mut state.shown {
                for slot in &mut shown.slots {
                    if slot.buffer.id() == proxy.id() {
                        slot.busy = false;
                    }
                }
                redraw = shown.redraw_pending;
            }
            if redraw {
                draw_current(state, qh);
            }
        }
    }
}

impl Dispatch<ZwlrLayerSurfaceV1, ()> for DotState {
    fn event(
        state: &mut Self,
        _: &ZwlrLayerSurfaceV1,
        event: wayland_protocols_wlr::layer_shell::v1::client::zwlr_layer_surface_v1::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        use wayland_protocols_wlr::layer_shell::v1::client::zwlr_layer_surface_v1::Event;
        match event {
            Event::Configure {
                serial,
                width,
                height,
            } => {
                if let Some(shown) = &state.shown {
                    shown.layer.ack_configure(serial);
                }
                ensure_buffers(state, qh, width.max(1), height.max(1));
            }
            Event::Closed => {
                destroy_shown(state);
            }
            _ => {}
        }
    }
}

fn destroy_shown(state: &mut DotState) {
    if let Some(shown) = state.shown.take() {
        for slot in &shown.slots {
            slot.buffer.destroy();
        }
        shown.layer.destroy();
        shown.surface.destroy();
        if !shown.mem.is_null() {
            unsafe {
                libc::munmap(shown.mem as *mut libc::c_void, shown.mem_len);
            }
        }
    }
}

fn create_shown(state: &mut DotState, qh: &QueueHandle<DotState>, output_name: &str) {
    let (Some(compositor), Some(layer_shell)) =
        (state.compositor.clone(), state.layer_shell.clone())
    else {
        return;
    };
    let out = state
        .outputs
        .iter()
        .find(|o| o.name == output_name)
        .or_else(|| state.outputs.first());
    let Some(out) = out else { return };
    let (oproxy, oname, oscale) = (out.proxy.clone(), out.name.clone(), out.scale);
    let surface = compositor.create_surface(qh, ());
    let layer = layer_shell.get_layer_surface(
        &surface,
        Some(&oproxy),
        Layer::Overlay,
        "hyprconnect-presenter".to_string(),
        qh,
        (),
    );
    layer.set_anchor(Anchor::Top | Anchor::Bottom | Anchor::Left | Anchor::Right);
    layer.set_exclusive_zone(-1);
    layer.set_keyboard_interactivity(KeyboardInteractivity::None);
    layer.set_size(0, 0);
    let region = compositor.create_region(qh, ());
    surface.set_input_region(Some(&region));
    region.destroy();
    surface.commit();
    state.shown = Some(Shown {
        surface,
        layer,
        output_name: oname,
        scale: oscale,
        logical: None,
        mem: std::ptr::null_mut(),
        mem_len: 0,
        _file: None,
        slots: Vec::new(),
        redraw_pending: false,
    });
}

fn ensure_buffers(state: &mut DotState, qh: &QueueHandle<DotState>, w: u32, h: u32) {
    let already = matches!(&state.shown, Some(s) if s.logical == Some((w, h)) && !s.slots.is_empty());
    if already {
        draw_current(state, qh);
        return;
    }
    let Some(shm) = state.shm.clone() else { return };
    let scale = match &state.shown {
        Some(s) => s.scale.max(1) as u32,
        None => return,
    };
    // Free the previous allocation, if any.
    if let Some(shown) = &mut state.shown {
        for slot in shown.slots.drain(..) {
            slot.buffer.destroy();
        }
        if !shown.mem.is_null() {
            unsafe {
                libc::munmap(shown.mem as *mut libc::c_void, shown.mem_len);
            }
            shown.mem = std::ptr::null_mut();
            shown.mem_len = 0;
        }
        shown._file = None;
        shown.logical = None;
    }
    let (bw, bh) = (w * scale, h * scale);
    let stride = bw * 4;
    let size = (stride * bh) as usize;
    let total = size * 2;
    let fd = unsafe {
        libc::memfd_create(
            b"hyprconnect-dot\0".as_ptr() as *const libc::c_char,
            libc::MFD_CLOEXEC,
        )
    };
    if fd < 0 {
        return;
    }
    unsafe {
        libc::ftruncate(fd, total as libc::off_t);
    }
    let file = unsafe { std::fs::File::from_raw_fd(fd) };
    let mem = unsafe {
        libc::mmap(
            std::ptr::null_mut(),
            total,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED,
            fd,
            0,
        )
    };
    if mem == libc::MAP_FAILED {
        return;
    }
    unsafe {
        std::ptr::write_bytes(mem as *mut u8, 0, total);
    }
    let pool = shm.create_pool(file.as_fd(), total as i32, qh, ());
    let mut slots = Vec::new();
    for i in 0..2 {
        let buffer = pool.create_buffer(
            (size * i) as i32,
            bw as i32,
            bh as i32,
            stride as i32,
            wl_shm::Format::Argb8888,
            qh,
            (),
        );
        slots.push(Slot {
            buffer,
            busy: false,
            drawn: None,
        });
    }
    pool.destroy();
    if let Some(shown) = &mut state.shown {
        shown.mem = mem as *mut u8;
        shown.mem_len = total;
        shown._file = Some(file);
        shown.slots = slots;
        shown.logical = Some((w, h));
    }
    draw_current(state, qh);
}

fn clear_rect(base: *mut u32, w: u32, h: u32, cx: i32, cy: i32, ext: i32) {
    for y in (cy - ext)..=(cy + ext) {
        if y < 0 || y >= h as i32 {
            continue;
        }
        for x in (cx - ext)..=(cx + ext) {
            if x < 0 || x >= w as i32 {
                continue;
            }
            unsafe {
                *base.add((y as u32 * w + x as u32) as usize) = 0;
            }
        }
    }
}

fn draw_dot(base: *mut u32, w: u32, h: u32, cx: i32, cy: i32, r: i32) {
    let ext = r + 2;
    let rf = r as f32;
    for y in (cy - ext)..=(cy + ext) {
        if y < 0 || y >= h as i32 {
            continue;
        }
        for x in (cx - ext)..=(cx + ext) {
            if x < 0 || x >= w as i32 {
                continue;
            }
            let dx = (x - cx) as f32;
            let dy = (y - cy) as f32;
            let d = (dx * dx + dy * dy).sqrt();
            let val: u32 = if d <= rf - 1.5 {
                // Red core at 80% opacity, premultiplied.
                (204 << 24) | (204 << 16)
            } else if d <= rf + 0.5 {
                // White border.
                (204 << 24) | (204 << 16) | (204 << 8) | 204
            } else if d <= rf + 1.5 {
                // Soft red edge.
                let a = ((rf + 1.5 - d) * 204.0) as u32;
                (a << 24) | (a << 16)
            } else {
                continue;
            };
            unsafe {
                *base.add((y as u32 * w + x as u32) as usize) = val;
            }
        }
    }
}

fn draw_current(state: &mut DotState, _qh: &QueueHandle<DotState>) {
    let (fx, fy) = (state.fx, state.fy);
    let Some(shown) = &mut state.shown else { return };
    let Some((lw, lh)) = shown.logical else { return };
    if shown.slots.is_empty() {
        return;
    }
    let Some(slot_idx) = shown.slots.iter().position(|s| !s.busy) else {
        shown.redraw_pending = true;
        return;
    };
    let scale = shown.scale.max(1) as u32;
    let (bw, bh) = (lw * scale, lh * scale);
    let cx = (fx * bw as f64) as i32;
    let cy = (fy * bh as f64) as i32;
    let r = ((bw as f64 / 300.0).round() as i32).max(5);
    let frame_bytes = (bw * bh * 4) as usize;
    let base = unsafe { shown.mem.add(slot_idx * frame_bytes) } as *mut u32;
    let slot = &mut shown.slots[slot_idx];
    if let Some((ox, oy)) = slot.drawn {
        clear_rect(base, bw, bh, ox, oy, r + 2);
    }
    draw_dot(base, bw, bh, cx, cy, r);
    slot.drawn = Some((cx, cy));
    slot.busy = true;
    shown.redraw_pending = false;
    let buffer = slot.buffer.clone();
    shown.surface.attach(Some(&buffer), 0, 0);
    if shown.surface.version() >= 4 {
        shown.surface.damage_buffer(0, 0, bw as i32, bh as i32);
    } else {
        shown.surface.damage(0, 0, lw as i32, lh as i32);
    }
    shown.surface.commit();
}

fn apply_cmd(state: &mut DotState, qh: &QueueHandle<DotState>, cmd: DotCmd) {
    match cmd {
        DotCmd::Show { output } => {
            let same = matches!(&state.shown, Some(s) if s.output_name == output);
            if !same {
                destroy_shown(state);
                create_shown(state, qh, &output);
            }
        }
        DotCmd::Move { x, y } => {
            state.fx = x;
            state.fy = y;
            if state.shown.is_some() {
                draw_current(state, qh);
            }
        }
        DotCmd::Hide => {
            destroy_shown(state);
        }
    }
}

fn run(
    cmd_rx: std_mpsc::Receiver<DotCmd>,
    wake: &std::fs::File,
    log: &dyn Fn(&str),
) -> anyhow::Result<()> {
    let conn = crate::wayland::connect("presenter dot", log);
    let mut queue = conn.new_event_queue::<DotState>();
    let qh = queue.handle();
    let _registry = conn.display().get_registry(&qh, 0u32);
    let mut state = DotState {
        outputs: Vec::new(),
        compositor: None,
        shm: None,
        layer_shell: None,
        fx: 0.5,
        fy: 0.5,
        shown: None,
    };
    queue.roundtrip(&mut state).context("registry roundtrip")?;
    if state.layer_shell.is_none() {
        anyhow::bail!("compositor does not offer zwlr_layer_shell_v1");
    }
    log("presenter dot overlay ready (layer-shell)");
    let conn_fd = conn.as_fd();
    loop {
        while let Ok(cmd) = cmd_rx.try_recv() {
            apply_cmd(&mut state, &qh, cmd);
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
