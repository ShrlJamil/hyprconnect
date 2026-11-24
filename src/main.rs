//! HyprConnect daemon and CLI.
//!
//! Phase 0: discovery, TLS transport, KDE Connect-style pairing with
//! persistent trust and automatic reconnection. The daemon exposes a
//! JSON-lines control socket in its state directory; the CLI (and later
//! the GTK app) talk to it there.

use anyhow::{Context, Result};
use hyprconnect::clipboard;
use hyprconnect::dot;
use hyprconnect::pointer;
use hyprconnect::identity::{self, LocalIdentity};
use hyprconnect::packet::{plugin_for_packet, Packet, PLUGIN_NAMES};
use hyprconnect::store::{hex_encode, TrustStore, TrustedDevice};
use hyprconnect::{tls, identity::state_dir};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream, UdpSocket, UnixListener};
use tokio::sync::{mpsc, Mutex};

const UDP_PORT: u16 = 1716;
const TCP_FIRST: u16 = 1714;
const TCP_LAST: u16 = 1764;
const PAIR_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Debug, Clone)]
struct DeviceInfo {
    id: String,
    name: String,
    dtype: String,
    last_ip: Option<IpAddr>,
    last_tcp_port: Option<u16>,
    last_seen: Option<Instant>,
    connected: bool,
    paired: bool,
    pending_in: bool,
    pending_out: bool,
    pair_deadline: Option<Instant>,
    /// Failed outgoing connect attempts since the last live channel;
    /// drives the sweeper's reconnect backoff.
    connect_attempts: u32,
    last_attempt: Option<Instant>,
    /// Generation of the channel that currently owns this device; a
    /// replaced channel's teardown must not clear newer state.
    channel_gen: u64,
    peer_spki: Vec<u8>,
    peer_cert: Vec<u8>,
    battery_level: Option<i64>,
    battery_charging: bool,
}

impl DeviceInfo {
    fn new(id: &str) -> Self {
        DeviceInfo {
            id: id.to_string(),
            name: String::new(),
            dtype: String::new(),
            last_ip: None,
            last_tcp_port: None,
            last_seen: None,
            connected: false,
            paired: false,
            pending_in: false,
            pending_out: false,
            pair_deadline: None,
            connect_attempts: 0,
            last_attempt: None,
            channel_gen: 0,
            peer_spki: Vec::new(),
            peer_cert: Vec::new(),
            battery_level: None,
            battery_charging: false,
        }
    }

    fn to_json(&self, local_spki: &[u8]) -> Value {
        let available = self
            .last_seen
            .map(|t| t.elapsed() < Duration::from_secs(60))
            .unwrap_or(false);
        let mut v = json!({
            "deviceId": self.id,
            "name": self.name,
            "type": self.dtype,
            "connected": self.connected,
            "available": available,
            "paired": self.paired,
            "pendingIn": self.pending_in,
            "pendingOut": self.pending_out,
        });
        if let Some(level) = self.battery_level {
            v["battery"] = json!(level);
            v["batteryCharging"] = json!(self.battery_charging);
        }
        if let Some(ip) = self.last_ip {
            v["host"] = json!(ip.to_string());
        }
        if !self.peer_spki.is_empty() {
            v["verificationKey"] =
                json!(identity::verification_key(local_spki, &self.peer_spki));
        }
        v
    }
}

struct Inner {
    devices: HashMap<String, DeviceInfo>,
    channels: HashMap<String, mpsc::Sender<Packet>>,
    connecting: HashSet<String>,
    next_channel_gen: u64,
    trust: TrustStore,
    subscribers: Vec<mpsc::Sender<String>>,
    /// Phone notification id -> desktop notification id.
    notif_ids: HashMap<String, u32>,
    /// Desktop notification id -> where its actions and replies go.
    notif_routes: HashMap<u32, NotifRoute>,
    /// Desktop MPRIS players by display name.
    mpris_players: HashMap<String, MprisPlayer>,
    /// Last album art path attached for each player (dedupe).
    mpris_art_sent: HashMap<String, String>,
    /// Cached audio sinks for system volume control.
    sinks: Vec<SinkInfo>,
    /// Latest requested sink volume not yet applied (drag coalescing).
    sink_pending: HashMap<String, i64>,
    /// Sinks with a volume-apply worker currently running.
    sink_applying: std::collections::HashSet<String>,
    /// Active SFTP mounts: device id -> mountpoints (primary first).
    sftp_mounts: HashMap<String, Vec<PathBuf>>,
    /// Monitor the presenter pointer is pinned to (None = automatic).
    presenter_monitor: Option<String>,
    /// The phone's own media players: device id -> player -> state.
    phone_players: HashMap<String, HashMap<String, Value>>,
    /// Phone album art saved on disk: device id -> player -> path.
    phone_art: HashMap<String, HashMap<String, String>>,
    /// Album art URLs already pulled from the phone: device id ->
    /// player -> albumArtUrl.
    phone_art_wanted: HashMap<String, HashMap<String, String>>,
    /// Plugins the user switched off in the app's plugin page.
    plugins_disabled: std::collections::HashSet<String>,
    /// Run-command definitions the phone may execute: key -> {name, command}.
    commands: serde_json::Map<String, Value>,
    /// Running run-command processes: execution id -> pid.
    running_cmds: std::collections::HashMap<u32, u32>,
    next_cmd_id: u32,
    /// Presentation remote session state.
    presenter: PresenterState,
    /// Touchpad deltas waiting for the next flush tick.
    mousepad_acc: (f64, f64),
}

#[derive(Clone, PartialEq)]
struct SinkInfo {
    name: String,
    description: String,
    volume: i64,
    muted: bool,
    is_default: bool,
}

#[derive(Clone, PartialEq)]
struct MprisPlayer {
    bus_name: String,
    name: String,
    title: String,
    artist: String,
    album: String,
    art_url: String,
    is_playing: bool,
    length_ms: i64,
    volume: i32,
    can_play: bool,
    can_pause: bool,
    can_next: bool,
    can_prev: bool,
    can_seek: bool,
    track_id: String,
}

#[derive(Clone)]
struct NotifRoute {
    device_id: String,
    phone_id: String,
    reply_id: Option<String>,
}

struct Daemon {
    identity: Arc<LocalIdentity>,
    state: PathBuf,
    tcp_port: u16,
    inner: Mutex<Inner>,
    clipboard: Option<clipboard::ClipboardHandle>,
    dot: Option<dot::DotHandle>,
    pointer: Option<pointer::PointerHandle>,
    last_clipboard: Mutex<Option<String>>,
    dbus: Mutex<Option<zbus::Connection>>,
}

fn log(msg: &str) {
    println!("[hyprconnect] {}", msg);
    use std::io::Write;
    let _ = std::io::stdout().flush();
}

impl Daemon {
    async fn emit(&self, event: Value) {
        let line = event.to_string();
        let mut inner = self.inner.lock().await;
        inner.subscribers.retain(|tx| tx.try_send(line.clone()).is_ok());
    }

    async fn send_packet(&self, device_id: &str, packet: Packet) -> bool {
        let inner = self.inner.lock().await;
        if let Some(plugin) = plugin_for_packet(packet.ptype.as_str()) {
            if inner.plugins_disabled.contains(plugin) {
                return false;
            }
        }
        match inner.channels.get(device_id) {
            Some(tx) => tx.send(packet).await.is_ok(),
            None => false,
        }
    }

    async fn plugin_on(&self, plugin: &str) -> bool {
        let inner = self.inner.lock().await;
        !inner.plugins_disabled.contains(plugin)
    }

    async fn disabled_set(&self) -> std::collections::HashSet<String> {
        let inner = self.inner.lock().await;
        inner.plugins_disabled.clone()
    }

    async fn device_snapshot(&self) -> Vec<Value> {
        let inner = self.inner.lock().await;
        inner
            .devices
            .values()
            .map(|d| {
                let mut v = d.to_json(&self.identity.spki_der);
                if let Some(players) = inner.phone_players.get(&d.id) {
                    let mut list: Vec<Value> = players.values().cloned().collect();
                    if let Some(art) = inner.phone_art.get(&d.id) {
                        for p in list.iter_mut() {
                            if let Some(path) = p["player"]
                                .as_str()
                                .and_then(|name| art.get(name))
                            {
                                p["albumArtPath"] = json!(path);
                            }
                        }
                    }
                    list.sort_by_key(|p| {
                        p["player"].as_str().unwrap_or("").to_string()
                    });
                    v["phonePlayers"] = json!(list);
                }
                let mounts = inner.sftp_mounts.get(&d.id);
                v["mounted"] = json!(mounts.is_some());
                v["mountpoints"] = json!(mounts
                    .map(|ms| ms
                        .iter()
                        .map(|m| m.to_string_lossy().to_string())
                        .collect::<Vec<_>>())
                    .unwrap_or_default());
                v
            })
            .collect()
    }

    // ---- pairing actions -------------------------------------------------

    async fn request_pair(self: &Arc<Self>, device_id: &str) -> Result<Value> {
        let target = {
            let mut inner = self.inner.lock().await;
            let dev = inner
                .devices
                .get_mut(device_id)
                .context("unknown device; wait until it is discovered")?;
            if dev.paired {
                anyhow::bail!("device is already paired");
            }
            if dev.pending_out {
                anyhow::bail!("pair request already sent");
            }
            dev.pending_out = true;
            dev.pair_deadline = Some(Instant::now() + PAIR_TIMEOUT);
            if dev.connected {
                None
            } else {
                match (dev.last_ip, dev.last_tcp_port) {
                    (Some(ip), Some(port)) => Some((ip, port)),
                    _ => anyhow::bail!("device address unknown; wait for discovery"),
                }
            }
        };
        if let Some((ip, port)) = target {
            // Not connected yet: open the channel now; register_channel
            // sends the pending pair request as soon as it is up.
            let mut inner = self.inner.lock().await;
            if !inner.connecting.contains(device_id) {
                inner.connecting.insert(device_id.to_string());
                let d = self.clone();
                let id = device_id.to_string();
                tokio::spawn(async move { connect_to(d, id, ip, port).await });
            }
        } else {
            self.send_packet(device_id, Packet::pair(true)).await;
        }
        self.emit(json!({"event": "pair_outgoing", "deviceId": device_id}))
            .await;
        Ok(json!({"ok": true}))
    }

    async fn accept_pair(&self, device_id: &str) -> Result<Value> {
        let dev_info;
        {
            let mut inner = self.inner.lock().await;
            let dev = inner
                .devices
                .get_mut(device_id)
                .context("unknown device")?;
            if !dev.pending_in {
                anyhow::bail!("no incoming pair request from this device");
            }
            dev.pending_in = false;
            dev.pair_deadline = None;
            dev.paired = true;
            dev_info = dev.clone();
            let trusted = TrustedDevice {
                device_id: dev_info.id.clone(),
                name: dev_info.name.clone(),
                device_type: dev_info.dtype.clone(),
                cert_hex: hex_encode(&dev_info.peer_cert),
            };
            inner.trust.add(trusted)?;
        }
        self.send_packet(device_id, Packet::pair(true)).await;
        log(&format!("paired with {} ({})", dev_info.name, dev_info.id));
        self.emit(json!({"event": "paired", "deviceId": device_id}))
            .await;
        Ok(json!({"ok": true}))
    }

    async fn reject_pair(&self, device_id: &str) -> Result<Value> {
        {
            let mut inner = self.inner.lock().await;
            let dev = inner
                .devices
                .get_mut(device_id)
                .context("unknown device")?;
            dev.pending_in = false;
            dev.pending_out = false;
            dev.pair_deadline = None;
        }
        self.send_packet(device_id, Packet::pair(false)).await;
        self.emit(json!({"event": "pair_rejected", "deviceId": device_id}))
            .await;
        Ok(json!({"ok": true}))
    }

    async fn unpair(&self, device_id: &str) -> Result<Value> {
        {
            let mut inner = self.inner.lock().await;
            if let Some(dev) = inner.devices.get_mut(device_id) {
                dev.paired = false;
                dev.pending_in = false;
                dev.pending_out = false;
                dev.pair_deadline = None;
            }
            inner.trust.remove(device_id)?;
        }
        self.send_packet(device_id, Packet::pair(false)).await;
        self.emit(json!({"event": "unpaired", "deviceId": device_id}))
            .await;
        Ok(json!({"ok": true}))
    }

    // ---- packet handling ---------------------------------------------------

    async fn handle_packet(self: &Arc<Self>, device_id: &str, packet: Packet) {
        if let Some(plugin) = plugin_for_packet(packet.ptype.as_str()) {
            if !self.plugin_on(plugin).await {
                log(&format!(
                    "packet {} from {} dropped (plugin {} disabled)",
                    packet.ptype, device_id, plugin
                ));
                return;
            }
        }
        match packet.ptype.as_str() {
            "kdeconnect.pair" => {
                let pair = packet.body["pair"].as_bool().unwrap_or(false);
                if pair {
                    let mut complete_outgoing = false;
                    let mut incoming_request = false;
                    {
                        let mut inner = self.inner.lock().await;
                        if let Some(dev) = inner.devices.get_mut(device_id) {
                            if dev.paired {
                                // already paired, nothing to do
                            } else if dev.pending_out {
                                complete_outgoing = true;
                                dev.pending_out = false;
                                dev.pair_deadline = None;
                                dev.paired = true;
                                let trusted = TrustedDevice {
                                    device_id: dev.id.clone(),
                                    name: dev.name.clone(),
                                    device_type: dev.dtype.clone(),
                                    cert_hex: hex_encode(&dev.peer_cert),
                                };
                                let _ = inner.trust.add(trusted);
                            } else if !dev.pending_in {
                                incoming_request = true;
                                dev.pending_in = true;
                                dev.pair_deadline =
                                    Some(Instant::now() + PAIR_TIMEOUT);
                            }
                        }
                    }
                    if complete_outgoing {
                        log(&format!("pairing completed with {}", device_id));
                        self.emit(json!({"event": "paired", "deviceId": device_id}))
                            .await;
                    } else if incoming_request {
                        let key = {
                            let inner = self.inner.lock().await;
                            inner.devices.get(device_id).map(|d| {
                                identity::verification_key(
                                    &self.identity.spki_der,
                                    &d.peer_spki,
                                )
                            })
                        };
                        log(&format!(
                            "incoming pair request from {} (verification key {})",
                            device_id,
                            key.clone().unwrap_or_default()
                        ));
                        self.emit(json!({
                            "event": "pair_request",
                            "deviceId": device_id,
                            "verificationKey": key,
                        }))
                        .await;
                    }
                } else {
                    // pair: false = rejection or unpair
                    let mut was_paired = false;
                    {
                        let mut inner = self.inner.lock().await;
                        if let Some(dev) = inner.devices.get_mut(device_id) {
                            was_paired = dev.paired;
                            dev.paired = false;
                            dev.pending_in = false;
                            dev.pending_out = false;
                            dev.pair_deadline = None;
                        }
                        if was_paired {
                            let _ = inner.trust.remove(device_id);
                        }
                    }
                    self.emit(json!({
                        "event": if was_paired { "unpaired" } else { "pair_rejected" },
                        "deviceId": device_id,
                    }))
                    .await;
                }
            }
            "kdeconnect.ping" => {
                let paired = {
                    let inner = self.inner.lock().await;
                    inner
                        .devices
                        .get(device_id)
                        .map(|d| d.paired)
                        .unwrap_or(false)
                };
                if paired {
                    let message = packet
                        .body
                        .get("message")
                        .and_then(|m| m.as_str())
                        .unwrap_or("")
                        .to_string();
                    log(&format!("ping from {}: {}", device_id, message));
                    self.emit(json!({
                        "event": "ping",
                        "deviceId": device_id,
                        "message": message,
                    }))
                    .await;
                }
            }
            "kdeconnect.presenter" => {
                let paired = {
                    let inner = self.inner.lock().await;
                    inner
                        .devices
                        .get(device_id)
                        .map(|d| d.paired)
                        .unwrap_or(false)
                };
                if paired {
                    self.handle_presenter(device_id, &packet.body).await;
                }
            }
            "kdeconnect.mousepad.request" => {
                let paired = {
                    let inner = self.inner.lock().await;
                    inner
                        .devices
                        .get(device_id)
                        .map(|d| d.paired)
                        .unwrap_or(false)
                };
                if paired {
                    self.handle_mousepad(&packet.body).await;
                }
            }
            "kdeconnect.sftp" => {
                let paired = {
                    let inner = self.inner.lock().await;
                    inner
                        .devices
                        .get(device_id)
                        .map(|d| d.paired)
                        .unwrap_or(false)
                };
                log(&format!(
                    "sftp params from {}: {}",
                    device_id,
                    serde_json::to_string(&packet.body).unwrap_or_default()
                ));
                if paired {
                    let d = self.clone();
                    let id = device_id.to_string();
                    let body = packet.body.clone();
                    tokio::spawn(async move { d.mount_sftp(&id, &body).await });
                }
            }
            "kdeconnect.systemvolume.request" => {
                let paired = {
                    let inner = self.inner.lock().await;
                    inner
                        .devices
                        .get(device_id)
                        .map(|d| d.paired)
                        .unwrap_or(false)
                };
                if paired {
                    self.handle_systemvolume_request(device_id, &packet)
                        .await;
                }
            }
            "kdeconnect.mpris.request" => {
                let paired = {
                    let inner = self.inner.lock().await;
                    inner
                        .devices
                        .get(device_id)
                        .map(|d| d.paired)
                        .unwrap_or(false)
                };
                if paired {
                    self.handle_mpris_request(device_id, &packet).await;
                }
            }
            "kdeconnect.mpris" => {
                // The phone's own players, kept for the desktop-side
                // control surface in the app.
                let paired = {
                    let inner = self.inner.lock().await;
                    inner
                        .devices
                        .get(device_id)
                        .map(|d| d.paired)
                        .unwrap_or(false)
                };
                if paired {
                    self.store_phone_player(device_id, &packet).await;
                }
            }
            "kdeconnect.runcommand.request" => {
                let paired = self
                    .inner
                    .lock()
                    .await
                    .devices
                    .get(device_id)
                    .map(|d| d.paired)
                    .unwrap_or(false);
                if !paired {
                    return;
                }
                if packet
                    .body
                    .get("requestCommandList")
                    .and_then(|v| v.as_bool())
                    == Some(true)
                {
                    self.send_command_list(&device_id).await;
                } else if let Some(key) = packet.body.get("key").and_then(|v| v.as_str()) {
                    let key = key.to_string();
                    self.run_remote_command(&device_id, &key).await;
                } else if packet.body.get("setup").and_then(|v| v.as_bool()) == Some(true) {
                    // The phone asked to edit the command list: open our app.
                    if let Ok(exe) = std::env::current_exe() {
                        let _ = std::process::Command::new(exe.with_file_name("hyprconnect-app"))
                            .spawn();
                    }
                } else if packet.body.get("stop").and_then(|v| v.as_bool()) == Some(true) {
                    self.stop_remote_commands().await;
                }
            }
            "kdeconnect.battery" => {
                let paired = {
                    let inner = self.inner.lock().await;
                    inner
                        .devices
                        .get(device_id)
                        .map(|d| d.paired)
                        .unwrap_or(false)
                };
                if paired {
                    let level = packet.body["currentCharge"].as_i64();
                    let charging =
                        packet.body["isCharging"].as_bool().unwrap_or(false);
                    let mut inner = self.inner.lock().await;
                    if let Some(dev) = inner.devices.get_mut(device_id) {
                        dev.battery_level = level;
                        dev.battery_charging = charging;
                    }
                }
            }
            "kdeconnect.notification" => {
                let paired = {
                    let inner = self.inner.lock().await;
                    inner
                        .devices
                        .get(device_id)
                        .map(|d| d.paired)
                        .unwrap_or(false)
                };
                if paired {
                    self.handle_notification(device_id, &packet).await;
                }
            }
            "kdeconnect.share.request" => {
                let paired = {
                    let inner = self.inner.lock().await;
                    inner
                        .devices
                        .get(device_id)
                        .map(|d| d.paired)
                        .unwrap_or(false)
                };
                if paired {
                    self.handle_share_request(device_id, &packet).await;
                }
            }
            "kdeconnect.clipboard" | "kdeconnect.clipboard.connect" => {
                let paired = {
                    let inner = self.inner.lock().await;
                    inner
                        .devices
                        .get(device_id)
                        .map(|d| d.paired)
                        .unwrap_or(false)
                };
                if paired {
                    if let Some(content) =
                        packet.body.get("content").and_then(|c| c.as_str())
                    {
                        self.apply_remote_clipboard(content).await;
                    }
                }
            }
            other => {
                log(&format!("packet {} from {} (no handler)", other, device_id));
            }
        }
    }

    /// Clipboard content arrived from a paired device: apply it
    /// locally unless it is what we already have (echo guard).
    async fn apply_remote_clipboard(&self, content: &str) {
        if content.len() > 512_000 {
            return;
        }
        {
            let mut last = self.last_clipboard.lock().await;
            if last.as_deref() == Some(content) {
                return;
            }
            *last = Some(content.to_string());
        }
        log(&format!("clipboard received ({} chars), applying", content.len()));
        if let Some(handle) = &self.clipboard {
            let _ = handle
                .cmd_tx
                .send(clipboard::ClipboardCmd::Set(content.to_string()));
        }
    }

    /// The local clipboard changed (reported by the Wayland watcher):
    /// forward it to every paired, connected device.
    async fn on_local_clipboard_changed(&self, content: String) {
        if content.len() > 512_000 {
            return;
        }
        let targets: Vec<String> = {
            let mut last = self.last_clipboard.lock().await;
            if last.as_deref() == Some(content.as_str()) {
                return;
            }
            *last = Some(content.clone());
            let inner = self.inner.lock().await;
            inner
                .devices
                .values()
                .filter(|d| d.paired && d.connected)
                .map(|d| d.id.clone())
                .collect()
        };
        log(&format!(
            "local clipboard changed ({} chars), forwarding to {} device(s)",
            content.len(),
            targets.len()
        ));
        let packet = Packet::new(
            "kdeconnect.clipboard",
            json!({ "content": content }),
        );
        for id in targets {
            self.send_packet(&id, packet.clone()).await;
        }
    }

    /// A kdeconnect.share.request arrived from a paired device.
    /// Files come with an out-of-band payload on a separate
    /// connection; text and url shares ride in the packet itself.
    async fn handle_share_request(self: &Arc<Self>, device_id: &str, packet: &Packet) {
        log(&format!(
            "share.request from {}: {}",
            device_id,
            serde_json::to_string(packet).unwrap_or_default()
        ));
        if let Some(text) = packet.body.get("text").and_then(|t| t.as_str()) {
            log(&format!(
                "shared text from {} ({} chars), applying as clipboard",
                device_id,
                text.len()
            ));
            self.apply_remote_clipboard(text).await;
            return;
        }
        if let Some(url) = packet.body.get("url").and_then(|u| u.as_str()) {
            log(&format!("shared url from {}: {}", device_id, url));
            self.emit(json!({
                "event": "url_shared",
                "deviceId": device_id,
                "url": url,
            }))
            .await;
            return;
        }
        let filename = packet
            .body
            .get("filename")
            .and_then(|f| f.as_str())
            .unwrap_or("")
            .to_string();
        let port = packet
            .payload_transfer_info
            .as_ref()
            .and_then(|i| i.get("port"))
            .and_then(|p| p.as_u64());
        let size = packet.payload_size.unwrap_or(-1);
        if filename.is_empty() || port.is_none() || size < 0 {
            log("share.request without filename/payload info; not downloading");
            return;
        }
        let daemon = self.clone();
        let device_id = device_id.to_string();
        tokio::spawn(async move {
            if let Err(e) = daemon
                .receive_file(&device_id, &filename, port.unwrap() as u16, size as u64)
                .await
            {
                log(&format!(
                    "receiving {} from {} failed: {:#}",
                    filename, device_id, e
                ));
            }
        });
    }

    /// Download one shared file over its payload connection.
    async fn receive_file(
        self: &Arc<Self>,
        device_id: &str,
        filename: &str,
        port: u16,
        size: u64,
    ) -> Result<()> {
        let ip = {
            let inner = self.inner.lock().await;
            inner
                .devices
                .get(device_id)
                .and_then(|d| d.last_ip)
                .context("device address unknown")?
        };
        let tcp = TcpStream::connect((ip, port))
            .await
            .context("payload connect")?;
        // Payload connections use the natural TLS roles (listener =
        // server, connector = client), unlike the main channel where
        // the roles are reversed. Verified against the real Android
        // app: acting as server here starves the handshake.
        let (mut stream, peer_cert) =
            tls::handshake_as_client(tcp, &self.identity, device_id).await?;
        let (cn, _) = identity::cert_info(&peer_cert)?;
        if cn != device_id {
            anyhow::bail!("payload peer CN {} is not {}", cn, device_id);
        }
        let dest = unique_download_path(filename);
        let mut file = tokio::fs::File::create(&dest).await?;
        let mut remaining = size;
        let mut buf = vec![0u8; 64 * 1024];
        while remaining > 0 {
            let want = remaining.min(buf.len() as u64) as usize;
            let n = stream.read(&mut buf[..want]).await?;
            if n == 0 {
                anyhow::bail!("payload ended early, {} bytes missing", remaining);
            }
            file.write_all(&buf[..n]).await?;
            remaining -= n as u64;
        }
        file.flush().await?;
        log(&format!(
            "received {} ({} bytes) -> {}",
            filename,
            size,
            dest.display()
        ));
        self.emit(json!({
            "event": "file_received",
            "deviceId": device_id,
            "filename": filename,
            "path": dest.to_string_lossy(),
            "size": size,
        }))
        .await;
        Ok(())
    }

    /// Offer a local file to a paired, connected device. The share
    /// packet names a payload port; the device connects to it and we
    /// stream the bytes over a second TLS connection.
    async fn send_file(
        self: &Arc<Self>,
        device_id: &str,
        path: &str,
    ) -> Result<Value> {
        {
            let inner = self.inner.lock().await;
            let dev = inner
                .devices
                .get(device_id)
                .context("unknown device")?;
            if !dev.paired {
                anyhow::bail!("device is not paired");
            }
            if !dev.connected {
                anyhow::bail!("device is not connected");
            }
        }
        let meta = tokio::fs::metadata(path)
            .await
            .context("cannot read the file")?;
        if !meta.is_file() {
            anyhow::bail!("not a regular file");
        }
        let filename = std::path::Path::new(path)
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .context("path has no file name")?;
        let mut listener = None;
        let mut port = 0u16;
        for p in 1739..=1764u16 {
            if let Ok(l) = TcpListener::bind(("0.0.0.0", p)).await {
                listener = Some(l);
                port = p;
                break;
            }
        }
        let listener = listener.context("no free payload port")?;
        let mut packet = Packet::new(
            "kdeconnect.share.request",
            json!({ "filename": filename }),
        );
        packet.payload_size = Some(meta.len() as i64);
        packet.payload_transfer_info = Some(json!({ "port": port }));
        if !self.send_packet(device_id, packet).await {
            anyhow::bail!("could not send the share packet");
        }
        log(&format!(
            "offered {} ({} bytes) to {} on payload port {}",
            filename,
            meta.len(),
            device_id,
            port
        ));
        let daemon = self.clone();
        let device_id = device_id.to_string();
        let path = path.to_string();
        tokio::spawn(async move {
            match tokio::time::timeout(
                Duration::from_secs(120),
                listener.accept(),
            )
            .await
            {
                Ok(Ok((tcp, _))) => {
                    if let Err(e) = daemon.stream_file(&device_id, tcp, &path).await {
                        log(&format!("sending {} failed: {:#}", path, e));
                    }
                }
                Ok(Err(e)) => log(&format!("payload accept failed: {:#}", e)),
                Err(_) => log("file send timed out: the device never fetched the payload"),
            }
        });
        Ok(json!({ "ok": true, "port": port }))
    }

    /// Stream one file over an accepted payload connection.
    async fn stream_file(&self, device_id: &str, tcp: TcpStream, path: &str) -> Result<()> {
        // Payload connections use the natural TLS roles: we accepted
        // this connection, so we are the TLS server.
        let (mut stream, peer_cert) =
            tls::handshake_as_server(tcp, &self.identity).await?;
        let (cn, _) = identity::cert_info(&peer_cert)?;
        if cn != device_id {
            anyhow::bail!("payload peer CN {} is not {}", cn, device_id);
        }
        let mut file = tokio::fs::File::open(path).await?;
        let mut buf = vec![0u8; 64 * 1024];
        let mut total: u64 = 0;
        loop {
            let n = file.read(&mut buf).await?;
            if n == 0 {
                break;
            }
            stream.write_all(&buf[..n]).await?;
            total += n as u64;
        }
        stream.flush().await?;
        log(&format!("sent {} ({} bytes) to {}", path, total, device_id));
        self.emit(json!({
            "event": "file_sent",
            "deviceId": device_id,
            "path": path,
            "size": total,
        }))
        .await;
        Ok(())
    }

    async fn notify_conn(&self) -> Result<zbus::Connection> {
        let mut slot = self.dbus.lock().await;
        if let Some(conn) = slot.as_ref() {
            return Ok(conn.clone());
        }
        let conn = zbus::Connection::session()
            .await
            .context("connect to the session D-Bus")?;
        *slot = Some(conn.clone());
        Ok(conn)
    }

    /// A kdeconnect.notification arrived from a paired device: mirror
    /// it to the desktop notification server, and mirror dismissals
    /// the same way. Icons arrive as packet payloads.
    async fn handle_notification(self: &Arc<Self>, device_id: &str, packet: &Packet) {
        log(&format!(
            "notification from {}: {}",
            device_id,
            serde_json::to_string(packet).unwrap_or_default()
        ));
        let body = &packet.body;
        let notif_id = body
            .get("id")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if notif_id.is_empty() {
            return;
        }
        if body.get("isCancel").and_then(|v| v.as_bool()).unwrap_or(false) {
            let desktop_id = {
                let mut inner = self.inner.lock().await;
                let id = inner.notif_ids.remove(&notif_id);
                if let Some(id) = id {
                    inner.notif_routes.remove(&id);
                }
                id
            };
            if let Some(desktop_id) = desktop_id {
                if let Ok(conn) = self.notify_conn().await {
                    if let Ok(proxy) = NotificationsProxy::new(&conn).await {
                        let _ = proxy.close_notification(desktop_id).await;
                    }
                }
                log(&format!("notification {} dismissed on the phone, closed on desktop", notif_id));
            }
            return;
        }
        // The phone marks resent (already-seen) notifications as
        // silent. They still belong on the desktop, just quietly:
        // show them with low urgency instead of dropping them,
        // which is how the reference implementation treats them.
        let silent = body
            .get("silent")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        if silent {
            log(&format!(
                "notification {} is a silent resend, showing quietly",
                notif_id
            ));
        }
        // Icon payload, if any: same payload channel rules as files.
        let mut icon_path = String::new();
        if let (Some(info), Some(size)) = (&packet.payload_transfer_info, packet.payload_size) {
            if size > 0 && size <= 2_000_000 {
                if let Some(port) = info.get("port").and_then(|p| p.as_u64()) {
                    match self
                        .download_payload(device_id, port as u16, size as usize)
                        .await
                    {
                        Ok(bytes) => {
                            let safe: String = notif_id
                                .chars()
                                .map(|c| if c.is_alphanumeric() { c } else { '_' })
                                .collect();
                            let dir = self.state.join("icons");
                            let _ = tokio::fs::create_dir_all(&dir).await;
                            let path = dir.join(format!("{}.png", safe));
                            if tokio::fs::write(&path, &bytes).await.is_ok() {
                                icon_path = path.to_string_lossy().to_string();
                            }
                        }
                        Err(e) => {
                            log(&format!("notification icon download failed: {:#}", e))
                        }
                    }
                }
            }
        }
        let app_name = body.get("appName").and_then(|v| v.as_str()).unwrap_or("Phone");
        let title = body.get("title").and_then(|v| v.as_str()).unwrap_or("");
        let text = body.get("text").and_then(|v| v.as_str()).unwrap_or("");
        let (summary, body_text) = if title.is_empty() {
            (app_name.to_string(), text.to_string())
        } else {
            (title.to_string(), text.to_string())
        };
        let replaces = {
            let inner = self.inner.lock().await;
            inner.notif_ids.get(&notif_id).copied().unwrap_or(0)
        };
        // Forward the phone's action buttons (the action id is the
        // label itself, which is how the phone matches them), plus
        // the freedesktop inline-reply action when the notification
        // can be replied to.
        let reply_id = body
            .get("requestReplyId")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        let mut action_pairs: Vec<String> = Vec::new();
        if let Some(actions) = body.get("actions").and_then(|v| v.as_array()) {
            for a in actions {
                if let Some(label) = a.as_str() {
                    action_pairs.push(label.to_string());
                    action_pairs.push(label.to_string());
                }
            }
        }
        if reply_id.is_some() {
            action_pairs.push("inline-reply".to_string());
            action_pairs.push("Reply".to_string());
        }
        let action_refs: Vec<&str> = action_pairs.iter().map(|s| s.as_str()).collect();
        let mut hints: HashMap<&str, zbus::zvariant::Value> = HashMap::new();
        hints.insert(
            "urgency",
            zbus::zvariant::Value::U8(if silent { 0 } else { 1 }),
        );
        match self.notify_conn().await {
            Ok(conn) => match NotificationsProxy::new(&conn).await {
                Ok(proxy) => {
                    match proxy
                        .notify(
                            app_name,
                            replaces,
                            &icon_path,
                            &summary,
                            &body_text,
                            action_refs,
                            hints,
                            -1,
                        )
                        .await
                    {
                        Ok(desktop_id) => {
                            let mut inner = self.inner.lock().await;
                            inner.notif_ids.insert(notif_id.clone(), desktop_id);
                            inner.notif_routes.insert(
                                desktop_id,
                                NotifRoute {
                                    device_id: device_id.to_string(),
                                    phone_id: notif_id.clone(),
                                    reply_id: reply_id.clone(),
                                },
                            );
                            log(&format!(
                                "notification {} shown on desktop as {}",
                                notif_id, desktop_id
                            ));
                        }
                        Err(e) => log(&format!("Notify call failed: {:#}", e)),
                    }
                }
                Err(e) => log(&format!("notification proxy failed: {:#}", e)),
            },
            Err(e) => log(&format!("no session D-Bus for notifications: {:#}", e)),
        }
    }

    /// Fetch a small payload (a notification icon) into memory.
    async fn download_payload(
        &self,
        device_id: &str,
        port: u16,
        size: usize,
    ) -> Result<Vec<u8>> {
        let ip = {
            let inner = self.inner.lock().await;
            inner
                .devices
                .get(device_id)
                .and_then(|d| d.last_ip)
                .context("device address unknown")?
        };
        let tcp = TcpStream::connect((ip, port))
            .await
            .context("payload connect")?;
        let (mut stream, peer_cert) =
            tls::handshake_as_client(tcp, &self.identity, device_id).await?;
        let (cn, _) = identity::cert_info(&peer_cert)?;
        if cn != device_id {
            anyhow::bail!("payload peer CN {} is not {}", cn, device_id);
        }
        let mut data = Vec::with_capacity(size);
        let mut buf = vec![0u8; 16 * 1024];
        while data.len() < size {
            let want = (size - data.len()).min(buf.len());
            let n = stream.read(&mut buf[..want]).await?;
            if n == 0 {
                anyhow::bail!("payload ended early");
            }
            data.extend_from_slice(&buf[..n]);
        }
        Ok(data)
    }

    /// Listen for action clicks and inline replies from the desktop
    /// notification server and route them back to the phone.
    async fn notif_signal_loop(self: Arc<Self>) {
        loop {
            if let Err(e) = self.notif_signals_once().await {
                log(&format!("notification signals failed: {:#}", e));
            }
            tokio::time::sleep(Duration::from_secs(5)).await;
        }
    }

    async fn notif_signals_once(&self) -> Result<()> {
        use futures_lite::StreamExt;
        let conn = self.notify_conn().await?;
        let proxy = NotificationsProxy::new(&conn).await?;
        let mut actions = proxy.receive_action_invoked().await?;
        let mut replies = proxy.receive_notification_replied().await?;
        let mut closeds = proxy.receive_notification_closed().await?;
        log("notification action/reply listener active");
        loop {
            tokio::select! {
                Some(sig) = actions.next() => {
                    if let Ok(args) = sig.args() {
                        self.on_action_invoked(args.id, args.action_key).await;
                    }
                }
                Some(sig) = replies.next() => {
                    if let Ok(args) = sig.args() {
                        self.on_notification_reply(args.id, args.text).await;
                    }
                }
                Some(sig) = closeds.next() => {
                    if let Ok(args) = sig.args() {
                        let mut inner = self.inner.lock().await;
                        if let Some(route) = inner.notif_routes.remove(&args.id) {
                            inner.notif_ids.remove(&route.phone_id);
                        }
                    }
                }
                else => break,
            }
        }
        Ok(())
    }

    async fn on_action_invoked(&self, desktop_id: u32, action_key: &str) {
        if action_key == "default" || action_key == "inline-reply" {
            return;
        }
        let route = {
            let inner = self.inner.lock().await;
            inner.notif_routes.get(&desktop_id).cloned()
        };
        if let Some(route) = route {
            self.send_packet(
                &route.device_id,
                Packet::new(
                    "kdeconnect.notification.action",
                    json!({ "id": route.phone_id, "action": action_key }),
                ),
            )
            .await;
            log(&format!(
                "notification action '{}' routed to {}",
                action_key, route.device_id
            ));
        }
    }

    async fn on_notification_reply(&self, desktop_id: u32, text: &str) {
        let route = {
            let inner = self.inner.lock().await;
            inner.notif_routes.get(&desktop_id).cloned()
        };
        if let Some(route) = route {
            if let Some(reply_id) = &route.reply_id {
                self.send_packet(
                    &route.device_id,
                    Packet::new(
                        "kdeconnect.notification.reply",
                        json!({ "requestReplyId": reply_id, "message": text }),
                    ),
                )
                .await;
                log(&format!(
                    "notification reply routed to {}",
                    route.device_id
                ));
            }
        }
    }

    // ---- MPRIS bridge -------------------------------------------------------

    async fn mpris_send_all_to(self: &Arc<Self>, device_id: &str) {
        let buses: Vec<String> = {
            let inner = self.inner.lock().await;
            inner
                .mpris_players
                .values()
                .map(|p| p.bus_name.clone())
                .collect()
        };
        if buses.is_empty() {
            self.send_packet(
                device_id,
                Packet::new("kdeconnect.mpris", json!({ "playerList": [] })),
            )
            .await;
            return;
        }
        let Ok(conn) = self.notify_conn().await else {
            return;
        };
        let mut names = Vec::new();
        for bus in &buses {
            if let Some((player, pos)) = self.mpris_read_player(&conn, bus).await {
                names.push(player.name.clone());
                self.send_mpris_state(device_id, &player, pos).await;
            }
        }
        self.send_packet(
            device_id,
            Packet::new("kdeconnect.mpris", json!({ "playerList": names })),
        )
        .await;
    }

    async fn mpris_broadcast(&self, packet: Packet) {
        let targets: Vec<String> = {
            let inner = self.inner.lock().await;
            inner
                .devices
                .values()
                .filter(|d| d.paired && d.connected)
                .map(|d| d.id.clone())
                .collect()
        };
        for t in targets {
            self.send_packet(&t, packet.clone()).await;
        }
    }

    async fn mpris_read_player(
        &self,
        conn: &zbus::Connection,
        bus: &str,
    ) -> Option<(MprisPlayer, i64)> {
        use zbus::zvariant::OwnedValue;
        let player_proxy = zbus::Proxy::new(
            conn,
            bus,
            "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player",
        )
        .await
        .ok()?;
        let root_proxy = zbus::Proxy::new(
            conn,
            bus,
            "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2",
        )
        .await
        .ok()?;
        let mut name: String = root_proxy
            .get_property("Identity")
            .await
            .unwrap_or_default();
        if name.is_empty() {
            name = bus
                .trim_start_matches("org.mpris.MediaPlayer2.")
                .to_string();
        }
        let metadata: HashMap<String, OwnedValue> =
            player_proxy.get_property("Metadata").await.unwrap_or_default();
        let get = |k: &str| metadata.get(k);
        let title = get("xesam:title").map(ov_str).unwrap_or_default();
        let artist = get("xesam:artist").map(ov_str_list).unwrap_or_default();
        let album = get("xesam:album").map(ov_str).unwrap_or_default();
        let art_url = get("mpris:artUrl").map(ov_str).unwrap_or_default();
        let length_ms = get("mpris:length").map(ov_i64).unwrap_or(0) / 1000;
        let track_id = get("mpris:trackid").map(ov_str).unwrap_or_default();
        let status: String = player_proxy
            .get_property("PlaybackStatus")
            .await
            .unwrap_or_default();
        let volume: f64 = player_proxy.get_property("Volume").await.unwrap_or(0.0);
        let position: i64 = player_proxy.get_property("Position").await.unwrap_or(0);
        let can_play = player_proxy
            .get_property::<bool>("CanPlay")
            .await
            .unwrap_or(false);
        let can_pause = player_proxy
            .get_property::<bool>("CanPause")
            .await
            .unwrap_or(false);
        let can_next = player_proxy
            .get_property::<bool>("CanGoNext")
            .await
            .unwrap_or(false);
        let can_prev = player_proxy
            .get_property::<bool>("CanGoPrevious")
            .await
            .unwrap_or(false);
        let can_seek = player_proxy
            .get_property::<bool>("CanSeek")
            .await
            .unwrap_or(false);
        let player = MprisPlayer {
            bus_name: bus.to_string(),
            name,
            title,
            artist,
            album,
            art_url,
            is_playing: status == "Playing",
            length_ms,
            volume: (volume * 100.0).round() as i32,
            can_play,
            can_pause,
            can_next,
            can_prev,
            can_seek,
            track_id,
        };
        Some((player, position / 1000))
    }

    async fn mpris_refresh_players(self: &Arc<Self>) {
        let Ok(conn) = self.notify_conn().await else {
            return;
        };
        let Ok(dbus) = zbus::fdo::DBusProxy::new(&conn).await else {
            return;
        };
        let Ok(names) = dbus.list_names().await else {
            return;
        };
        let live: Vec<String> = names
            .iter()
            .map(|n| n.to_string())
            .filter(|n| n.starts_with("org.mpris.MediaPlayer2."))
            .collect();
        let known: Vec<String> = {
            let inner = self.inner.lock().await;
            inner
                .mpris_players
                .values()
                .map(|p| p.bus_name.clone())
                .collect()
        };
        let mut changed = false;
        for bus in &live {
            if !known.contains(bus) {
                if let Some((player, _)) = self.mpris_read_player(&conn, bus).await {
                    log(&format!("mpris player appeared: {}", player.name));
                    let mut inner = self.inner.lock().await;
                    inner
                        .mpris_players
                        .insert(player.name.clone(), player);
                    changed = true;
                    let d = self.clone();
                    let b = bus.clone();
                    tokio::spawn(d.mpris_watch_player(b));
                }
            }
        }
        {
            let mut inner = self.inner.lock().await;
            let gone: Vec<String> = inner
                .mpris_players
                .values()
                .filter(|p| !live.contains(&p.bus_name))
                .map(|p| p.name.clone())
                .collect();
            for name in gone {
                log(&format!("mpris player gone: {}", name));
                inner.mpris_players.remove(&name);
                changed = true;
            }
        }
        if changed {
            let names_now: Vec<String> = {
                let inner = self.inner.lock().await;
                inner.mpris_players.keys().cloned().collect()
            };
            self.mpris_broadcast(Packet::new(
                "kdeconnect.mpris",
                json!({ "playerList": names_now }),
            ))
            .await;
            let targets: Vec<String> = {
                let inner = self.inner.lock().await;
                inner
                    .devices
                    .values()
                    .filter(|d| d.paired && d.connected)
                    .map(|d| d.id.clone())
                    .collect()
            };
            for t in targets {
                self.mpris_send_all_to(&t).await;
            }
        }
    }

    fn mpris_watch_player(
        self: Arc<Self>,
        bus: String,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>> {
        Box::pin(async move { self.mpris_watch_player_inner(bus).await })
    }

    async fn mpris_watch_player_inner(self: Arc<Self>, bus: String) {
        use futures_lite::StreamExt;
        let Ok(conn) = self.notify_conn().await else {
            return;
        };
        let Ok(proxy) = zbus::Proxy::new(
            &conn,
            bus.as_str(),
            "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player",
        )
        .await
        else {
            return;
        };
        let Ok(mut stream) = proxy.receive_signal("PropertiesChanged").await else {
            return;
        };
        while let Some(msg) = stream.next().await {
            let Ok((iface, _, _)) = msg.body().deserialize::<(
                String,
                HashMap<String, zbus::zvariant::OwnedValue>,
                Vec<String>,
            )>() else {
                continue;
            };
            if iface != "org.mpris.MediaPlayer2.Player" {
                continue;
            }
            if let Some((player, pos)) = self.mpris_read_player(&conn, &bus).await {
                let changed = {
                    let mut inner = self.inner.lock().await;
                    let old = inner.mpris_players.get(&player.name).cloned();
                    if old.as_ref() != Some(&player) {
                        inner
                            .mpris_players
                            .insert(player.name.clone(), player.clone());
                        true
                    } else {
                        false
                    }
                };
                if changed {
                    for t in self.mpris_targets().await {
                        self.send_mpris_state(&t, &player, pos).await;
                    }
                }
            }
        }
        let d = self.clone();
        tokio::spawn(async move { d.mpris_refresh_players().await });
    }

    async fn mpris_bridge_loop(self: Arc<Self>) {
        use futures_lite::StreamExt;
        self.mpris_refresh_players().await;
        loop {
            let Ok(conn) = self.notify_conn().await else {
                tokio::time::sleep(Duration::from_secs(10)).await;
                continue;
            };
            let Ok(dbus) = zbus::fdo::DBusProxy::new(&conn).await else {
                tokio::time::sleep(Duration::from_secs(10)).await;
                continue;
            };
            match dbus.receive_name_owner_changed().await {
                Ok(mut stream) => {
                    log("mpris bridge active");
                    loop {
                        tokio::select! {
                            sig = stream.next() => {
                                match sig {
                                    Some(s) => {
                                        if let Ok(args) = s.args() {
                                            if format!("{}", args.name).starts_with("org.mpris.MediaPlayer2.") {
                                                self.mpris_refresh_players().await;
                                            }
                                        }
                                    }
                                    None => break,
                                }
                            }
                            _ = tokio::time::sleep(Duration::from_secs(30)) => {
                                self.mpris_refresh_players().await;
                            }
                        }
                    }
                }
                Err(e) => {
                    log(&format!("mpris bridge signal failed: {:#}", e));
                    tokio::time::sleep(Duration::from_secs(10)).await;
                }
            }
        }
    }

    async fn handle_mpris_request(self: &Arc<Self>, device_id: &str, packet: &Packet) {
        log(&format!(
            "mpris.request from {}: {}",
            device_id,
            serde_json::to_string(packet).unwrap_or_default()
        ));
        let body = &packet.body;
        // Album art is a pull protocol: the phone asks for a specific
        // art URL, and only a packet flagged transferringAlbumArt with
        // the file as payload answers it. Pushing art on state packets
        // is silently dropped by the phone (its TLS handshake for the
        // payload never starts, which looks like an EOF on our side).
        if let Some(url) = body.get("albumArtUrl").and_then(|v| v.as_str()) {
            let player_name = body
                .get("player")
                .and_then(|v| v.as_str())
                .unwrap_or_default()
                .to_string();
            let current = {
                let inner = self.inner.lock().await;
                inner
                    .mpris_players
                    .get(&player_name)
                    .map(|p| p.art_url.clone())
            };
            if current.as_deref() == Some(url) {
                if let Some(path) = url.strip_prefix("file://") {
                    let answer = Packet::new(
                        "kdeconnect.mpris",
                        json!({
                            "transferringAlbumArt": true,
                            "player": player_name,
                            "albumArtUrl": url,
                        }),
                    );
                    if self
                        .send_packet_with_file_payload(device_id, answer, path, None)
                        .await
                    {
                        log(&format!(
                            "album art for {} requested and offered: {}",
                            player_name, url
                        ));
                    }
                }
            } else {
                log(&format!(
                    "album art request for {} does not match current art, ignored",
                    player_name
                ));
            }
            return;
        }
        if body
            .get("requestPlayerList")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
        {
            self.mpris_send_all_to(device_id).await;
            return;
        }
        let Some(player_name) = body.get("player").and_then(|v| v.as_str()) else {
            return;
        };
        let bus = {
            let inner = self.inner.lock().await;
            inner
                .mpris_players
                .get(player_name)
                .map(|p| p.bus_name.clone())
        };
        let Some(bus) = bus else {
            log(&format!("mpris request for unknown player {}", player_name));
            return;
        };
        if body
            .get("requestNowPlaying")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
        {
            if let Ok(conn) = self.notify_conn().await {
                if let Some((player, pos)) = self.mpris_read_player(&conn, &bus).await {
                    self.send_mpris_state(device_id, &player, pos).await;
                }
            }
            return;
        }
        let Ok(conn) = self.notify_conn().await else {
            return;
        };
        let Ok(proxy) = zbus::Proxy::new(
            &conn,
            bus.as_str(),
            "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player",
        )
        .await
        else {
            return;
        };
        if let Some(action) = body.get("action").and_then(|v| v.as_str()) {
            match action {
                "Play" | "Pause" | "PlayPause" | "Next" | "Previous" | "Stop" => {
                    let _ = proxy.call::<&str, _, ()>(action, &()).await;
                    log(&format!("mpris {} -> {}", action, player_name));
                }
                other => log(&format!("mpris unknown action {}", other)),
            }
        }
        if let Some(v) = body.get("setVolume").and_then(|v| v.as_i64()) {
            let _ = proxy
                .set_property("Volume", (v.clamp(0, 100) as f64) / 100.0)
                .await;
        }
        if let Some(seek) = body.get("Seek").and_then(|v| v.as_i64()) {
            // The phone sends MPRIS-native microseconds (a 10 second
            // jump arrives as 10000000), so pass it through untouched.
            let _ = proxy.call::<&str, _, ()>("Seek", &seek).await;
        }
        if let Some(pos) = body.get("SetPosition").and_then(|v| v.as_i64()) {
            let track = {
                let inner = self.inner.lock().await;
                inner
                    .mpris_players
                    .get(player_name)
                    .map(|p| p.track_id.clone())
                    .unwrap_or_default()
            };
            if let Ok(path) = zbus::zvariant::ObjectPath::try_from(track) {
                let _ = proxy
                    .call::<&str, _, ()>("SetPosition", &(path, pos))
                    .await;
            }
        }
        // Let the command land, then push the fresh state.
        tokio::time::sleep(Duration::from_millis(200)).await;
        if let Some((player, pos)) = self.mpris_read_player(&conn, &bus).await {
            let mut inner = self.inner.lock().await;
            inner
                .mpris_players
                .insert(player.name.clone(), player.clone());
            drop(inner);
            for t in self.mpris_targets().await {
                self.send_mpris_state(&t, &player, pos).await;
            }
        }
    }

    async fn mpris_targets(&self) -> Vec<String> {
        let inner = self.inner.lock().await;
        inner
            .devices
            .values()
            .filter(|d| d.paired && d.connected)
            .map(|d| d.id.clone())
            .collect()
    }

    /// Send a packet whose payload is a local file (album art, ...).
    /// Mirrors the send_file flow: listen on a payload port, advertise
    /// it in the packet, stream the file to whoever connects.
    async fn send_packet_with_file_payload(
        self: &Arc<Self>,
        device_id: &str,
        mut packet: Packet,
        path: &str,
        art_key: Option<String>,
    ) -> bool {
        let Ok(meta) = tokio::fs::metadata(path).await else {
            return false;
        };
        if !meta.is_file() {
            return false;
        }
        let mut listener = None;
        let mut port = 0u16;
        for p in 1739..=1764u16 {
            if let Ok(l) = TcpListener::bind(("0.0.0.0", p)).await {
                listener = Some(l);
                port = p;
                break;
            }
        }
        let Some(listener) = listener else {
            return false;
        };
        packet.payload_size = Some(meta.len() as i64);
        packet.payload_transfer_info = Some(json!({ "port": port }));
        if !self.send_packet(device_id, packet).await {
            return false;
        }
        let daemon = self.clone();
        let device_id = device_id.to_string();
        let path = path.to_string();
        tokio::spawn(async move {
            let mut failed = false;
            match tokio::time::timeout(Duration::from_secs(120), listener.accept()).await {
                Ok(Ok((tcp, addr))) => {
                    log(&format!("payload fetch of {} from {}", path, addr));
                    if let Err(e) = daemon.stream_file(&device_id, tcp, &path).await {
                        log(&format!("payload stream {} failed: {:#}", path, e));
                        failed = true;
                    }
                }
                Ok(Err(e)) => {
                    log(&format!("payload accept failed: {:#}", e));
                    failed = true;
                }
                Err(_) => {
                    log("payload timed out: the device never fetched it");
                    failed = true;
                }
            }
            // A failed art transfer unmarks the art, so the next state
            // send (e.g. when the phone opens the player UI and asks
            // for nowPlaying) offers it again.
            if failed {
                if let Some(key) = art_key {
                    let mut inner = daemon.inner.lock().await;
                    inner.mpris_art_sent.remove(&key);
                }
            }
        });
        true
    }

    /// Send one player's state. Album art is NOT attached here: the
    /// phone pulls it separately (see handle_mpris_request).
    async fn send_mpris_state(self: &Arc<Self>, device_id: &str, player: &MprisPlayer, pos_ms: i64) {
        self.send_packet(device_id, mpris_state_packet(player, pos_ms))
            .await;
    }

    // ---- system volume (PulseAudio via pactl) --------------------------------

    async fn pactl(&self, args: &[&str]) -> Option<String> {
        let runtime = std::env::var("XDG_RUNTIME_DIR")
            .unwrap_or_else(|_| format!("/run/user/{}", unsafe { libc::getuid() }));
        let out = tokio::process::Command::new("pactl")
            .args(args)
            .env("XDG_RUNTIME_DIR", runtime)
            .output()
            .await
            .ok()?;
        if !out.status.success() {
            return None;
        }
        Some(String::from_utf8_lossy(&out.stdout).to_string())
    }

    async fn read_sinks(&self) -> Vec<SinkInfo> {
        let Some(text) = self.pactl(&["--format=json", "list", "sinks"]).await else {
            return Vec::new();
        };
        let Ok(Value::Array(list)) = serde_json::from_str::<Value>(&text) else {
            return Vec::new();
        };
        let default_name = self
            .pactl(&["info"])
            .await
            .and_then(|info| {
                info.lines().find_map(|l| {
                    l.strip_prefix("Default Sink:").map(|s| s.trim().to_string())
                })
            })
            .unwrap_or_default();
        let mut sinks = Vec::new();
        for s in &list {
            let name = s["name"].as_str().unwrap_or_default().to_string();
            if name.is_empty() {
                continue;
            }
            // Hide sinks whose ports are all unavailable (unplugged HDMI).
            if let Some(ports) = s["ports"].as_array() {
                if !ports.is_empty()
                    && ports
                        .iter()
                        .all(|p| p["availability"].as_str() == Some("not available"))
                {
                    continue;
                }
            }
            let mut total: i64 = 0;
            let mut channels: i64 = 0;
            if let Some(vol) = s["volume"].as_object() {
                for (_, ch) in vol {
                    if let Some(v) = ch["value"].as_i64() {
                        total += v;
                        channels += 1;
                    }
                }
            }
            let volume = if channels > 0 { total / channels } else { 0 };
            sinks.push(SinkInfo {
                description: s["description"]
                    .as_str()
                    .unwrap_or_default()
                    .to_string(),
                muted: s["mute"].as_bool().unwrap_or(false),
                is_default: name == default_name,
                name,
                volume,
            });
        }
        sinks
    }

    async fn send_sink_list(&self, device_id: &str) {
        let sinks = self.read_sinks().await;
        {
            let mut inner = self.inner.lock().await;
            inner.sinks = sinks.clone();
        }
        let list: Vec<Value> = sinks
            .iter()
            .map(|s| {
                json!({
                    "name": s.name,
                    "description": s.description,
                    "muted": s.muted,
                    "volume": s.volume,
                    "maxVolume": 65536,
                    "enabled": s.is_default,
                })
            })
            .collect();
        self.send_packet(
            device_id,
            Packet::new("kdeconnect.systemvolume", json!({ "sinkList": list })),
        )
        .await;
    }

    /// Re-read the sinks and push whatever changed to every device.
    async fn sink_refresh_and_broadcast(&self) {
        let new = self.read_sinks().await;
        let old = {
            let mut inner = self.inner.lock().await;
            let old = inner.sinks.clone();
            inner.sinks = new.clone();
            old
        };
        let structure_changed = new.len() != old.len()
            || new
                .iter()
                .zip(old.iter())
                .any(|(n, o)| n.name != o.name || n.is_default != o.is_default);
        if structure_changed {
            let targets = self.mpris_targets().await;
            for t in targets {
                self.send_sink_list(&t).await;
            }
            return;
        }
        for (n, o) in new.iter().zip(old.iter()) {
            if n.volume != o.volume {
                self.mpris_broadcast(Packet::new(
                    "kdeconnect.systemvolume",
                    json!({ "name": n.name, "volume": n.volume }),
                ))
                .await;
            }
            if n.muted != o.muted {
                self.mpris_broadcast(Packet::new(
                    "kdeconnect.systemvolume",
                    json!({ "name": n.name, "muted": n.muted }),
                ))
                .await;
            }
        }
    }

    async fn sink_watch_loop(self: Arc<Self>) {
        use tokio::io::AsyncBufReadExt;
        let initial = self.read_sinks().await;
        {
            let mut inner = self.inner.lock().await;
            inner.sinks = initial;
        }
        log("system volume watcher active");
        loop {
            let runtime = std::env::var("XDG_RUNTIME_DIR")
                .unwrap_or_else(|_| format!("/run/user/{}", unsafe { libc::getuid() }));
            let child = tokio::process::Command::new("pactl")
                .arg("subscribe")
                .env("XDG_RUNTIME_DIR", runtime)
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::null())
                .spawn();
            let Ok(mut child) = child else {
                tokio::time::sleep(Duration::from_secs(5)).await;
                continue;
            };
            let Some(stdout) = child.stdout.take() else {
                tokio::time::sleep(Duration::from_secs(5)).await;
                continue;
            };
            let mut lines = tokio::io::BufReader::new(stdout).lines();
            let mut dirty = false;
            loop {
                tokio::select! {
                    line = lines.next_line() => {
                        match line {
                            Ok(Some(l)) => {
                                if l.contains("on sink") || l.contains("on server") {
                                    dirty = true;
                                }
                            }
                            _ => break,
                        }
                    }
                    _ = tokio::time::sleep(Duration::from_millis(250)), if dirty => {
                        dirty = false;
                        self.sink_refresh_and_broadcast().await;
                    }
                }
            }
            let _ = child.kill().await;
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    }

    async fn handle_systemvolume_request(
        self: &Arc<Self>,
        device_id: &str,
        packet: &Packet,
    ) {
        log(&format!(
            "systemvolume.request from {}: {}",
            device_id,
            serde_json::to_string(&packet.body).unwrap_or_default()
        ));
        let body = &packet.body;
        if body
            .get("requestSinks")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
        {
            self.send_sink_list(device_id).await;
            return;
        }
        let Some(name) = body.get("name").and_then(|v| v.as_str()) else {
            return;
        };
        let name = name.to_string();
        if let Some(v) = body.get("volume").and_then(|v| v.as_i64()) {
            // Slider drags arrive as a packet stream; only the newest
            // value matters. Queue it and let the apply worker drain.
            let spawn_worker = {
                let mut inner = self.inner.lock().await;
                inner.sink_pending.insert(name.clone(), v);
                inner.sink_applying.insert(name.clone())
            };
            if spawn_worker {
                let d = self.clone();
                tokio::spawn(async move { d.apply_sink_volume(name).await });
            }
        } else if let Some(m) = body.get("muted").and_then(|v| v.as_bool()) {
            self.pactl(&["set-sink-mute", &name, if m { "1" } else { "0" }])
                .await;
            log(&format!("systemvolume {} muted={}", name, m));
            {
                let mut inner = self.inner.lock().await;
                if let Some(s) = inner.sinks.iter_mut().find(|s| s.name == name) {
                    s.muted = m;
                }
            }
            self.mpris_broadcast(Packet::new(
                "kdeconnect.systemvolume",
                json!({ "name": name, "muted": m }),
            ))
            .await;
        } else if body
            .get("enabled")
            .and_then(|v| v.as_bool())
            .unwrap_or(false)
        {
            self.pactl(&["set-default-sink", &name]).await;
            log(&format!("systemvolume default -> {}", name));
            self.sink_refresh_and_broadcast().await;
        }
    }

    /// Drain queued volume values for one sink, newest first-class:
    /// intermediate drag values are dropped, so the sink tracks the
    /// slider instead of replaying its whole history.
    async fn apply_sink_volume(self: Arc<Self>, name: String) {
        loop {
            let target = {
                let mut inner = self.inner.lock().await;
                match inner.sink_pending.remove(&name) {
                    Some(v) => v,
                    None => {
                        inner.sink_applying.remove(&name);
                        return;
                    }
                }
            };
            // The phone sends PulseAudio units (0..=65536), like pactl.
            self.pactl(&["set-sink-volume", &name, &target.to_string()])
                .await;
            let was_muted = {
                let mut inner = self.inner.lock().await;
                if let Some(s) = inner.sinks.iter_mut().find(|s| s.name == name) {
                    let was = s.muted;
                    s.volume = target;
                    s.muted = false;
                    was
                } else {
                    false
                }
            };
            // Setting the volume unmutes, mirroring the KDE plugin;
            // only pay the extra call when the sink actually was muted.
            if was_muted {
                self.pactl(&["set-sink-mute", &name, "0"]).await;
            }
            self.mpris_broadcast(Packet::new(
                "kdeconnect.systemvolume",
                json!({ "name": name, "volume": target }),
            ))
            .await;
        }
    }

    // ---- SFTP browsing (sshfs mount) -----------------------------------------

    async fn request_sftp(&self, device_id: &str) {
        self.send_packet(
            device_id,
            Packet::new(
                "kdeconnect.sftp.request",
                json!({ "startBrowsing": true }),
            ),
        )
        .await;
    }

    async fn mount_sftp(self: &Arc<Self>, device_id: &str, body: &Value) {
        if body["serverRunning"].as_bool() == Some(false) {
            log(&format!(
                "sftp server on {} is not running (yet), waiting for parameters",
                device_id
            ));
            return;
        }
        {
            let existing = {
                let inner = self.inner.lock().await;
                inner.sftp_mounts.get(device_id).cloned()
            };
            if let Some(mounts) = existing {
                if let Some(first) = mounts.first() {
                    if mount_serves(first).await {
                        return; // still alive, nothing to do
                    }
                }
                log(&format!(
                    "recorded sftp mount for {} no longer serves, remounting",
                    device_id
                ));
                self.unmount_sftp(device_id).await;
            }
        }
        let (Some(ip), Some(port), Some(user), Some(password)) = (
            body["ip"].as_str(),
            body["port"].as_i64(),
            body["user"].as_str(),
            body["password"].as_str(),
        ) else {
            log(&format!(
                "sftp params from {} incomplete: {}",
                device_id,
                serde_json::to_string(body).unwrap_or_default()
            ));
            return;
        };
        // The phone names its own storages, so nothing is hardcoded:
        // "path" is the primary storage, multiPaths/pathNames list
        // every storage (an SD card shows up as an extra entry).
        let multi: Vec<String> = body["multiPaths"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_default();
        let names: Vec<String> = body["pathNames"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_default();
        let primary = body["path"]
            .as_str()
            .map(|s| s.to_string())
            .or_else(|| multi.first().cloned())
            .unwrap_or_else(|| "/".to_string());
        let mut storages: Vec<(String, Option<String>)> = vec![(primary.clone(), None)];
        for (i, p) in multi.iter().enumerate() {
            if *p != primary {
                storages.push((p.clone(), names.get(i).cloned()));
            }
        }
        let dev_name = {
            let inner = self.inner.lock().await;
            inner
                .devices
                .get(device_id)
                .map(|d| d.name.clone())
                .unwrap_or_else(|| device_id.to_string())
        };
        let base = sftp_mountpoint(&dev_name, device_id);
        let mut mounted: Vec<PathBuf> = Vec::new();
        for (remote, label) in &storages {
            let mountpoint = match label {
                Some(name) => {
                    let suffix: String = name
                        .trim()
                        .chars()
                        .map(|c| {
                            if c == '/' || c.is_control() {
                                '_'
                            } else {
                                c
                            }
                        })
                        .collect();
                    base.with_file_name(format!(
                        "{} ({})",
                        base.file_name().unwrap_or_default().to_string_lossy(),
                        suffix
                    ))
                }
                None => base.clone(),
            };
            if self
                .mount_one(device_id, user, ip, port, password, remote, &mountpoint)
                .await
            {
                mounted.push(mountpoint);
            }
        }
        if mounted.is_empty() {
            return;
        }
        {
            let mut inner = self.inner.lock().await;
            inner
                .sftp_mounts
                .insert(device_id.to_string(), mounted.clone());
        }
        self.emit(json!({
            "event": "sftp_mounted",
            "deviceId": device_id,
            "mountpoints": mounted
                .iter()
                .map(|m| m.to_string_lossy().to_string())
                .collect::<Vec<_>>(),
        }))
        .await;
    }

    async fn mount_one(
        &self,
        device_id: &str,
        user: &str,
        ip: &str,
        port: i64,
        password: &str,
        remote_path: &str,
        mountpoint: &std::path::Path,
    ) -> bool {
        // Clear a stale mount left by an earlier life FIRST: a dead
        // FUSE mount answers create_dir_all with EEXIST and blocks
        // the remount (seen live 2026-11-21).
        if mount_is_active(mountpoint).await {
            let _ = tokio::process::Command::new("fusermount3")
                .args(["-uz", &mountpoint.to_string_lossy()])
                .output()
                .await;
        }
        if let Err(e) = tokio::fs::create_dir_all(mountpoint).await {
            log(&format!("sftp mountpoint create failed: {:#}", e));
            return false;
        }
        log(&format!(
            "mounting {} at {} ({}@{}:{}{})",
            device_id,
            mountpoint.display(),
            user,
            ip,
            port,
            remote_path
        ));
        let mut cmd = tokio::process::Command::new("sshfs");
        cmd.args([
            "-o",
            "password_stdin",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "ServerAliveInterval=15",
            "-o",
            "ServerAliveCountMax=3",
            "-o",
            "reconnect",
            "-o",
            "idmap=user",
            "-p",
            &port.to_string(),
            &format!("{}@{}:{}", user, ip, remote_path),
            &mountpoint.to_string_lossy(),
        ])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                log(&format!("sshfs spawn failed: {:#}", e));
                return false;
            }
        };
        if let Some(mut stdin) = child.stdin.take() {
            use tokio::io::AsyncWriteExt;
            let _ = stdin
                .write_all(format!("{}\n", password).as_bytes())
                .await;
            let _ = stdin.shutdown().await;
        }
        let status = match child.wait().await {
            Ok(s) => s,
            Err(e) => {
                log(&format!("sshfs wait failed: {:#}", e));
                return false;
            }
        };
        if !status.success() {
            log(&format!("sshfs exited with {}", status));
            return false;
        }
        // Verify the mount actually serves content.
        match tokio::fs::read_dir(mountpoint).await {
            Ok(mut rd) => {
                let mut entries = Vec::new();
                while let Ok(Some(e)) = rd.next_entry().await {
                    entries.push(e.file_name().to_string_lossy().to_string());
                    if entries.len() >= 12 {
                        break;
                    }
                }
                log(&format!(
                    "sftp mounted at {}: {}",
                    mountpoint.display(),
                    entries.join(", ")
                ));
                true
            }
            Err(e) => {
                log(&format!(
                    "sftp mount at {} does not read: {:#}",
                    mountpoint.display(),
                    e
                ));
                false
            }
        }
    }

    async fn unmount_sftp(&self, device_id: &str) {
        let mountpoints = {
            let mut inner = self.inner.lock().await;
            inner.sftp_mounts.remove(device_id)
        };
        let Some(mountpoints) = mountpoints else {
            return;
        };
        for mountpoint in &mountpoints {
            let mp = mountpoint.to_string_lossy().to_string();
            let out = tokio::process::Command::new("fusermount3")
                .args(["-u", &mp])
                .output()
                .await;
            let ok = matches!(out, Ok(o) if o.status.success());
            if !ok {
                let _ = tokio::process::Command::new("fusermount3")
                    .args(["-uz", &mp])
                    .output()
                    .await;
            }
            log(&format!("sftp unmounted {}", mp));
        }
        self.emit(json!({
            "event": "sftp_unmounted",
            "deviceId": device_id,
            "mountpoints": mountpoints
                .iter()
                .map(|m| m.to_string_lossy().to_string())
                .collect::<Vec<_>>(),
        }))
        .await;
    }

    // ---- connection lifecycle ----------------------------------------------

    async fn register_channel(
        self: &Arc<Self>,
        info: DeviceInfo,
        stream: impl tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
    ) {
        let device_id = info.id.clone();
        let (tx, mut rx) = mpsc::channel::<Packet>(32);
        let channel_gen = {
            let mut inner = self.inner.lock().await;
            inner.next_channel_gen += 1;
            if inner
                .devices
                .get(&device_id)
                .map(|d| d.connected)
                .unwrap_or(false)
            {
                // The newest channel wins: the old one may be a zombie
                // whose peer already vanished (Wi-Fi switch, NAT
                // timeout). Its teardown is generation-guarded below
                // and cannot clear this channel's state.
                log(&format!(
                    "new connection to {} replaces the existing channel",
                    device_id
                ));
            }
            inner.next_channel_gen
        };
        {
            let mut inner = self.inner.lock().await;
            let paired = inner.trust.is_trusted(&device_id);
            let mut dev = info;
            dev.connected = true;
            dev.paired = paired;
            dev.channel_gen = channel_gen;
            dev.connect_attempts = 0;
            dev.last_attempt = None;
            // Preserve pairing state set before the channel came up
            // (a pair request is what triggered this connection).
            if let Some(old) = inner.devices.get(&device_id) {
                dev.pending_in = old.pending_in;
                dev.pending_out = old.pending_out;
                dev.pair_deadline = old.pair_deadline;
            }
            inner.devices.insert(device_id.clone(), dev);
            inner.channels.insert(device_id.clone(), tx);
        }
        log(&format!("connected to {}", device_id));
        self.emit(json!({"event": "connected", "deviceId": device_id}))
            .await;
        let pending_out = {
            let inner = self.inner.lock().await;
            inner
                .devices
                .get(&device_id)
                .map(|d| d.pending_out)
                .unwrap_or(false)
        };
        if pending_out {
            self.send_packet(&device_id, Packet::pair(true)).await;
        }
        let is_paired = {
            let inner = self.inner.lock().await;
            inner
                .devices
                .get(&device_id)
                .map(|d| d.paired)
                .unwrap_or(false)
        };
        if is_paired {
            self.send_packet(
                &device_id,
                Packet::new(
                    "kdeconnect.notification.request",
                    json!({ "request": true }),
                ),
            )
            .await;
            self.mpris_send_all_to(&device_id).await;
            self.send_packet(
                &device_id,
                Packet::new(
                    "kdeconnect.mpris.request",
                    json!({ "requestPlayerList": true }),
                ),
            )
            .await;
            self.send_sink_list(&device_id).await;
            self.request_sftp(&device_id).await;
            self.send_command_list(&device_id).await;
            self.send_packet(
                &device_id,
                Packet::new("kdeconnect.battery.request", json!({ "request": true })),
            )
            .await;
            self.send_packet(
                &device_id,
                Packet::new(
                    "kdeconnect.mpris.request",
                    json!({ "requestPlayerList": true }),
                ),
            )
            .await;
            if let Some(handle) = &self.clipboard {
                let current = handle.current.lock().unwrap().clone();
                if let Some(content) = current {
                    self.send_packet(
                        &device_id,
                        Packet::new(
                            "kdeconnect.clipboard.connect",
                            json!({ "content": content }),
                        ),
                    )
                    .await;
                }
            }
        }

        let (read_half, mut write_half) = tokio::io::split(stream);
        let writer = tokio::spawn(async move {
            while let Some(packet) = rx.recv().await {
                if write_half
                    .write_all(packet.to_line().as_bytes())
                    .await
                    .is_err()
                {
                    break;
                }
            }
        });

        let daemon = self.clone();
        let read_id = device_id.clone();
        tokio::spawn(async move {
            let mut reader = BufReader::new(read_half);
            let mut line = String::new();
            loop {
                line.clear();
                match reader.read_line(&mut line).await {
                    Ok(0) | Err(_) => break,
                    Ok(_) => {
                        let trimmed = line.trim();
                        if trimmed.is_empty() {
                            continue;
                        }
                        match serde_json::from_str::<Packet>(trimmed) {
                            Ok(packet) => {
                                if packet.ptype == "kdeconnect.identity" {
                                    // Encrypted identity exchange: the
                                    // device id must not change mid-channel.
                                    let claimed =
                                        packet.body["deviceId"].as_str().unwrap_or("");
                                    if claimed != read_id {
                                        log(&format!(
                                            "identity mismatch on channel to {} (claims {}), closing",
                                            read_id, claimed
                                        ));
                                        break;
                                    }
                                } else {
                                    daemon.handle_packet(&read_id, packet).await;
                                }
                            }
                            Err(e) => {
                                log(&format!("bad packet from {}: {}", read_id, e));
                            }
                        }
                    }
                }
            }
            writer.abort();
            let mut inner = daemon.inner.lock().await;
            let is_current = inner
                .devices
                .get(&read_id)
                .map(|d| d.channel_gen == channel_gen)
                .unwrap_or(false);
            if is_current {
                if let Some(dev) = inner.devices.get_mut(&read_id) {
                    dev.connected = false;
                    // Pairing state survives a channel flap on purpose:
                    // the pair deadline (sweeper) owns its expiry, and
                    // a fresh channel re-sends a pending request when
                    // it registers.
                }
                inner.channels.remove(&read_id);
            }
            drop(inner);
            if is_current {
                log(&format!("disconnected from {}", read_id));
                daemon.unmount_sftp(&read_id).await;
                daemon
                    .emit(json!({"event": "disconnected", "deviceId": read_id}))
                    .await;
            } else {
                log(&format!(
                    "stale channel to {} closed (already replaced)",
                    read_id
                ));
            }
        });
    }
}

// ---- connection establishment ---------------------------------------------

/// The protocol's connection opening: the TCP initiator sends its
/// identity packet in plaintext first. The acceptor reads it, and only
/// then does TLS start (initiator = TLS server, acceptor = TLS client).
/// Identity is also re-sent over the encrypted channel afterwards and
/// must name the same device (checked in the read loop).
async fn send_plaintext_identity<S>(daemon: &Daemon, stream: &mut S) -> Result<()>
where
    S: tokio::io::AsyncWrite + Unpin,
{
    let disabled = daemon.disabled_set().await;
    let packet = Packet::identity(&daemon.identity, daemon.tcp_port, &disabled);
    stream
        .write_all(packet.to_line().as_bytes())
        .await
        .context("send plaintext identity")?;
    Ok(())
}

async fn read_plaintext_identity<S>(
    stream: &mut S,
    remote_ip: IpAddr,
) -> Result<DeviceInfo>
where
    S: tokio::io::AsyncRead + Unpin,
{
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    let n = tokio::time::timeout(
        Duration::from_secs(10),
        reader.read_line(&mut line),
    )
    .await
    .context("plaintext identity timed out")??;
    if n == 0 {
        anyhow::bail!("peer closed before plaintext identity");
    }
    if line.len() > 8192 {
        anyhow::bail!("plaintext identity too large");
    }
    let packet: Packet = serde_json::from_str(line.trim())?;
    if packet.ptype != "kdeconnect.identity" {
        anyhow::bail!("first packet is not identity: {}", packet.ptype);
    }
    device_info_from_identity(&packet.body, remote_ip)
}

fn device_info_from_identity(body: &Value, remote_ip: IpAddr) -> Result<DeviceInfo> {
    let device_id = body["deviceId"].as_str().context("identity deviceId")?;
    if !identity::valid_device_id(device_id) {
        anyhow::bail!("invalid device id {:?}", device_id);
    }
    let mut info = DeviceInfo::new(device_id);
    info.name = body["deviceName"].as_str().unwrap_or("").to_string();
    info.dtype = body["deviceType"].as_str().unwrap_or("").to_string();
    info.last_ip = Some(remote_ip);
    info.last_tcp_port = body["tcpPort"].as_u64().map(|p| p as u16);
    info.last_seen = Some(Instant::now());
    Ok(info)
}

/// Validate the peer certificate against the identity we already have:
/// the certificate common name must be the device id.
fn attach_cert(info: &mut DeviceInfo, peer_cert_der: &[u8]) -> Result<()> {
    let (cn, spki) = identity::cert_info(peer_cert_der)?;
    if cn != info.id {
        anyhow::bail!(
            "certificate CN {} does not match identity deviceId {}",
            cn,
            info.id
        );
    }
    info.peer_spki = spki;
    info.peer_cert = peer_cert_der.to_vec();
    Ok(())
}

/// TCP keepalive so a channel whose peer vanished silently (Wi-Fi
/// switch, NAT timeout) eventually errors out instead of looking
/// connected forever.
fn set_keepalive(stream: &TcpStream) {
    let sock = socket2::SockRef::from(stream);
    let keepalive = socket2::TcpKeepalive::new()
        .with_time(Duration::from_secs(30))
        .with_interval(Duration::from_secs(10));
    let _ = sock.set_tcp_keepalive(&keepalive);
}

/// Exponential backoff for sweeper reconnects: a trusted device is
/// retried for as long as its last address is known, just less and
/// less often (5s, 10s, 20s, 40s, then every 60s).
fn reconnect_due(dev: &DeviceInfo) -> bool {
    match dev.last_attempt {
        None => true,
        Some(t) => {
            let shift = dev.connect_attempts.saturating_sub(1).min(4);
            let wait = Duration::from_secs((5u64 << shift).min(60));
            t.elapsed() >= wait
        }
    }
}

async fn connect_to(daemon: Arc<Daemon>, device_id: String, ip: IpAddr, port: u16) {
    {
        let mut inner = daemon.inner.lock().await;
        if let Some(dev) = inner.devices.get_mut(&device_id) {
            dev.last_attempt = Some(Instant::now());
        }
    }
    let result = async {
        // Bounded attempts: one dial to a stale address must not park
        // the device's connecting slot until the OS gives up.
        let mut tcp = tokio::time::timeout(
            Duration::from_secs(5),
            TcpStream::connect((ip, port)),
        )
        .await
        .context("TCP connect timed out")?
        .context("TCP connect")?;
        set_keepalive(&tcp);
        // We opened the TCP connection: send our identity in plaintext
        // first, then act as the TLS server.
        send_plaintext_identity(&daemon, &mut tcp).await?;
        let (stream, peer_cert) = tokio::time::timeout(
            Duration::from_secs(10),
            tls::handshake_as_server(tcp, &daemon.identity),
        )
        .await
        .context("TLS handshake timed out")??;
        let mut info = {
            let inner = daemon.inner.lock().await;
            inner
                .devices
                .get(&device_id)
                .cloned()
                .unwrap_or_else(|| DeviceInfo::new(&device_id))
        };
        info.last_ip = Some(ip);
        info.last_tcp_port = Some(port);
        info.last_seen = Some(Instant::now());
        attach_cert(&mut info, &peer_cert)?;
        // Authenticate trusted devices by their stored certificate.
        {
            let inner = daemon.inner.lock().await;
            if inner.trust.is_trusted(&info.id)
                && !inner.trust.cert_matches(&info.id, &info.peer_cert)
            {
                anyhow::bail!("certificate mismatch for trusted device");
            }
        }
        daemon.register_channel(info, stream).await;
        Ok::<(), anyhow::Error>(())
    }
    .await;
    let failed = result.is_err();
    if let Err(e) = result {
        log(&format!("connect to {} failed: {:#}", device_id, e));
    }
    {
        let mut inner = daemon.inner.lock().await;
        if failed {
            if let Some(dev) = inner.devices.get_mut(&device_id) {
                dev.connect_attempts = dev.connect_attempts.saturating_add(1);
            }
        }
        inner.connecting.remove(&device_id);
    }
}

async fn maybe_connect(daemon: &Arc<Daemon>, device_id: &str) {
    let target = {
        let mut inner = daemon.inner.lock().await;
        // Connect back to unpaired devices too, not just trusted
        // ones: a phone that has never paired cannot open the channel
        // itself in the TLS-server role without knowing this device's
        // certificate, so first pairing starts with this device
        // connecting to the phone's listener when it is heard on
        // discovery. The channel stays inert until pairing is
        // explicitly accepted here; every feature stays gated on the
        // paired state, like kdeconnectd linking to discovered peers.
        let dev = inner.devices.get(device_id);
        let ready = dev.map(|d| !d.connected).unwrap_or(false)
            && !inner.connecting.contains(device_id);
        match (ready, dev) {
            (true, Some(d)) => match (d.last_ip, d.last_tcp_port) {
                (Some(ip), Some(port)) => {
                    inner.connecting.insert(device_id.to_string());
                    Some((ip, port))
                }
                _ => None,
            },
            _ => None,
        }
    };
    if let Some((ip, port)) = target {
        let d = daemon.clone();
        let id = device_id.to_string();
        tokio::spawn(async move { connect_to(d, id, ip, port).await });
    }
}

async fn handle_incoming(daemon: Arc<Daemon>, tcp: TcpStream, remote: SocketAddr) {
    let result = async {
        // The TCP initiator speaks first: read its plaintext identity,
        // then act as the TLS client (SNI names that device, as the
        // protocol expects).
        let mut tcp = tcp;
        set_keepalive(&tcp);
        let mut info = read_plaintext_identity(&mut tcp, remote.ip()).await?;
        let (stream, peer_cert) = tokio::time::timeout(
            Duration::from_secs(10),
            tls::handshake_as_client(tcp, &daemon.identity, &info.id.clone()),
        )
        .await
        .context("TLS handshake timed out")??;
        attach_cert(&mut info, &peer_cert)?;
        {
            let inner = daemon.inner.lock().await;
            if inner.trust.is_trusted(&info.id)
                && !inner.trust.cert_matches(&info.id, &info.peer_cert)
            {
                anyhow::bail!("certificate mismatch for trusted device");
            }
        }
        daemon.register_channel(info, stream).await;
        Ok::<(), anyhow::Error>(())
    }
    .await;
    if let Err(e) = result {
        log(&format!("incoming connection from {} failed: {:#}", remote, e));
    }
}

// ---- discovery --------------------------------------------------------------

fn udp_socket() -> Result<UdpSocket> {
    let socket = socket2::Socket::new(
        socket2::Domain::IPV4,
        socket2::Type::DGRAM,
        Some(socket2::Protocol::UDP),
    )?;
    socket.set_reuse_address(true)?;
    socket.set_broadcast(true)?;
    socket.set_nonblocking(true)?;
    socket.bind(&SocketAddr::from(([0, 0, 0, 0], UDP_PORT)).into())?;
    Ok(UdpSocket::from_std(socket.into())?)
}

async fn discovery_task(daemon: Arc<Daemon>, udp: Arc<UdpSocket>) {
    let mut buf = vec![0u8; 8192];
    loop {
        match udp.recv_from(&mut buf).await {
            Ok((n, src)) => {
                let packet: Packet = match serde_json::from_slice(&buf[..n]) {
                    Ok(p) => p,
                    Err(_) => continue,
                };
                if packet.ptype != "kdeconnect.identity" {
                    continue;
                }
                let body = &packet.body;
                let device_id = match body["deviceId"].as_str() {
                    Some(id) if identity::valid_device_id(id) => id.to_string(),
                    _ => continue,
                };
                if device_id == daemon.identity.device_id {
                    continue;
                }
                {
                    let mut inner = daemon.inner.lock().await;
                    let trusted = inner.trust.is_trusted(&device_id);
                    let dev = inner
                        .devices
                        .entry(device_id.clone())
                        .or_insert_with(|| DeviceInfo::new(&device_id));
                    dev.name = body["deviceName"].as_str().unwrap_or("").to_string();
                    dev.dtype =
                        body["deviceType"].as_str().unwrap_or("").to_string();
                    dev.last_ip = Some(src.ip());
                    dev.last_tcp_port = body["tcpPort"].as_u64().map(|p| p as u16);
                    dev.last_seen = Some(Instant::now());
                    dev.paired = trusted;
                }
                maybe_connect(&daemon, &device_id).await;
            }
            Err(e) => {
                log(&format!("UDP receive error: {}", e));
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        }
    }
}

async fn announce_task(daemon: Arc<Daemon>, udp: Arc<UdpSocket>) {
    let target = SocketAddr::from(([255, 255, 255, 255], UDP_PORT));
    loop {
        let disabled = daemon.disabled_set().await;
        let packet = Packet::identity(&daemon.identity, daemon.tcp_port, &disabled);
        let data = serde_json::to_vec(&packet).unwrap_or_default();
        let _ = udp.send_to(&data, target).await;
        tokio::time::sleep(Duration::from_secs(3)).await;
    }
}

async fn sweeper_task(daemon: Arc<Daemon>) {
    loop {
        tokio::time::sleep(Duration::from_secs(2)).await;
        let mut expired: Vec<String> = Vec::new();
        let mut reconnect: Vec<String> = Vec::new();
        {
            let mut inner = daemon.inner.lock().await;
            let trusted_ids: HashSet<String> =
                inner.trust.devices.keys().cloned().collect();
            let connecting_snapshot = inner.connecting.clone();
            for dev in inner.devices.values_mut() {
                if (dev.pending_in || dev.pending_out)
                    && dev
                        .pair_deadline
                        .map(|d| Instant::now() > d)
                        .unwrap_or(false)
                {
                    dev.pending_in = false;
                    dev.pending_out = false;
                    dev.pair_deadline = None;
                    expired.push(dev.id.clone());
                }
                if trusted_ids.contains(&dev.id)
                    && !dev.connected
                    && !connecting_snapshot.contains(&dev.id)
                    && dev.last_ip.is_some()
                    && dev.last_tcp_port.is_some()
                    && reconnect_due(dev)
                {
                    reconnect.push(dev.id.clone());
                }
            }
        }
        for id in expired {
            daemon
                .emit(json!({"event": "pair_timeout", "deviceId": id}))
                .await;
        }
        for id in reconnect {
            maybe_connect(&daemon, &id).await;
        }
    }
}

// ---- control socket -----------------------------------------------------------

async fn control_task(daemon: Arc<Daemon>, path: PathBuf) {
    let _ = std::fs::remove_file(&path);
    let listener = match UnixListener::bind(&path) {
        Ok(l) => l,
        Err(e) => {
            log(&format!("cannot bind control socket {}: {}", path.display(), e));
            return;
        }
    };
    log(&format!("control socket at {}", path.display()));
    loop {
        let (stream, _) = match listener.accept().await {
            Ok(v) => v,
            Err(_) => continue,
        };
        let daemon = daemon.clone();
        tokio::spawn(async move {
            let (read_half, mut write_half) = tokio::io::split(stream);
            let mut reader = BufReader::new(read_half);
            let mut line = String::new();
            if reader.read_line(&mut line).await.unwrap_or(0) == 0 {
                return;
            }
            let req: Value = match serde_json::from_str(line.trim()) {
                Ok(v) => v,
                Err(e) => {
                    let _ = write_half
                        .write_all(
                            json!({"ok": false, "error": format!("bad request: {}", e)})
                                .to_string()
                                .as_bytes(),
                        )
                        .await;
                    return;
                }
            };
            let cmd = req["cmd"].as_str().unwrap_or("");
            if cmd == "monitor" {
                let (tx, mut rx) = mpsc::channel::<String>(64);
                daemon.inner.lock().await.subscribers.push(tx);
                while let Some(event) = rx.recv().await {
                    if write_half
                        .write_all(format!("{}\n", event).as_bytes())
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
                return;
            }
            let device_id = req["deviceId"].as_str().unwrap_or("");
            let result: Result<Value> = match cmd {
                "devices" => Ok(json!({
                    "ok": true,
                    "self": {
                        "deviceId": daemon.identity.device_id,
                        "deviceName": daemon.identity.device_name,
                    },
                    "devices": daemon.device_snapshot().await,
                })),
                "pair" => daemon.request_pair(device_id).await,
                "accept" => daemon.accept_pair(device_id).await,
                "reject" => daemon.reject_pair(device_id).await,
                "unpair" => daemon.unpair(device_id).await,
                "ping" => {
                    let msg = req["message"].as_str();
                    let sent = daemon
                        .send_packet(device_id, Packet::ping(msg))
                        .await;
                    if sent {
                        Ok(json!({"ok": true}))
                    } else {
                        Err(anyhow::anyhow!("device is not connected"))
                    }
                }
                "mount" => {
                    daemon.request_sftp(device_id).await;
                    Ok(json!({"ok": true}))
                }
                "unmount" => {
                    daemon.unmount_sftp(device_id).await;
                    Ok(json!({"ok": true}))
                }
                "ring" => {
                    let sent = daemon
                        .send_packet(
                            device_id,
                            Packet::new("kdeconnect.findmyphone.request", json!({})),
                        )
                        .await;
                    if sent {
                        Ok(json!({"ok": true}))
                    } else {
                        Err(anyhow::anyhow!("device is not connected"))
                    }
                }
                "phone_media" => match (req["player"].as_str(), req["action"].as_str()) {
                    (Some(player), Some(action)) => {
                        let sent = daemon
                            .send_packet(
                                device_id,
                                Packet::new(
                                    "kdeconnect.mpris.request",
                                    json!({ "player": player, "action": action }),
                                ),
                            )
                            .await;
                        Ok(json!({"ok": sent}))
                    }
                    _ => Err(anyhow::anyhow!("player and action required")),
                },
                "phone_volume" => match (req["player"].as_str(), req["volume"].as_i64()) {
                    (Some(player), Some(volume)) => {
                        let sent = daemon
                            .send_packet(
                                device_id,
                                Packet::new(
                                    "kdeconnect.mpris.request",
                                    json!({ "player": player, "setVolume": volume }),
                                ),
                            )
                            .await;
                        Ok(json!({"ok": sent}))
                    }
                    _ => Err(anyhow::anyhow!("player and volume required")),
                },
                "phone_seek" => match (req["player"].as_str(), req["position"].as_i64()) {
                    (Some(player), Some(position)) => {
                        let sent = daemon
                            .send_packet(
                                device_id,
                                Packet::new(
                                    "kdeconnect.mpris.request",
                                    json!({ "player": player, "SetPosition": position * 1000 }),
                                ),
                            )
                            .await;
                        Ok(json!({"ok": sent}))
                    }
                    _ => Err(anyhow::anyhow!("player and position required")),
                },
                "mousepad" => {
                    // Desktop -> phone remote input: forward the body as a
                    // mousepad packet to the phone.
                    let body = req.get("body").cloned().unwrap_or_else(|| json!({}));
                    let sent = daemon
                        .send_packet(
                            device_id,
                            Packet::new("kdeconnect.mousepad.request", body),
                        )
                        .await;
                    Ok(json!({"ok": sent}))
                }
                "send_clipboard" => {
                    let content = daemon
                        .clipboard
                        .as_ref()
                        .and_then(|h| h.current.lock().unwrap().clone());
                    match content {
                        Some(c) => {
                            *daemon.last_clipboard.lock().await = Some(c.clone());
                            let sent = daemon
                                .send_packet(
                                    device_id,
                                    Packet::new(
                                        "kdeconnect.clipboard",
                                        json!({ "content": c }),
                                    ),
                                )
                                .await;
                            Ok(json!({"ok": sent}))
                        }
                        None => Ok(json!({"ok": false})),
                    }
                }
                "run_command" => match req["key"].as_str() {
                    Some(key) => {
                        // No requesting device: output packets go nowhere,
                        // the command simply runs on this desktop.
                        daemon.run_remote_command("", key).await;
                        Ok(json!({"ok": true}))
                    }
                    None => Err(anyhow::anyhow!("key required")),
                },
                "get_commands" => Ok(json!({
                    "ok": true,
                    "commands": Value::Object(daemon.inner.lock().await.commands.clone()),
                })),
                "set_commands" => {
                    let mut resp = json!({"ok": true});
                    match req.get("commands").and_then(|v| v.as_object()) {
                        Some(map) => {
                            let mut clean = serde_json::Map::new();
                            for (k, v) in map.iter().take(64) {
                                let name =
                                    v.get("name").and_then(|x| x.as_str()).unwrap_or("");
                                let command =
                                    v.get("command").and_then(|x| x.as_str()).unwrap_or("");
                                if !name.trim().is_empty() {
                                    clean.insert(
                                        k.clone(),
                                        json!({"name": name, "command": command}),
                                    );
                                }
                            }
                            daemon.inner.lock().await.commands = clean.clone();
                            save_commands(&daemon.state, &clean);
                            let targets: Vec<String> = {
                                let inner = daemon.inner.lock().await;
                                inner
                                    .devices
                                    .values()
                                    .filter(|d| d.paired && d.connected)
                                    .map(|d| d.id.clone())
                                    .collect()
                            };
                            for id in targets {
                                daemon.send_command_list(&id).await;
                            }
                        }
                        None => {
                            resp = json!({"ok": false, "error": "commands must be an object"});
                        }
                    }
                    Ok(resp)
                }
                "settings" => {
                    let monitor = {
                        let inner = daemon.inner.lock().await;
                        inner.presenter_monitor.clone()
                    };
                    let disabled = daemon.disabled_set().await;
                    let plugins: serde_json::Map<String, Value> = PLUGIN_NAMES
                        .iter()
                        .map(|n| (n.to_string(), json!(!disabled.contains(*n))))
                        .collect();
                    Ok(json!({
                        "ok": true,
                        "presenterMonitor": monitor,
                        "monitors": hypr_monitor_names().await,
                        "plugins": plugins,
                    }))
                }
                "set_plugin" => {
                    let plugin = req["plugin"].as_str().unwrap_or("");
                    let enabled = req["enabled"].as_bool().unwrap_or(true);
                    if !PLUGIN_NAMES.contains(&plugin) {
                        Err(anyhow::anyhow!("unknown plugin"))
                    } else {
                        {
                            let mut inner = daemon.inner.lock().await;
                            if enabled {
                                inner.plugins_disabled.remove(plugin);
                            } else {
                                inner.plugins_disabled.insert(plugin.to_string());
                            }
                        }
                        save_plugins_disabled(
                            &daemon.state,
                            &daemon.disabled_set().await,
                        );
                        log(&format!(
                            "plugin {} {}",
                            plugin,
                            if enabled { "enabled" } else { "disabled" }
                        ));
                        if !enabled && plugin == "sftp" {
                            let ids: Vec<String> = {
                                let inner = daemon.inner.lock().await;
                                inner.sftp_mounts.keys().cloned().collect()
                            };
                            for id in ids {
                                daemon.unmount_sftp(&id).await;
                            }
                        }
                        if enabled {
                            let targets: Vec<String> = {
                                let inner = daemon.inner.lock().await;
                                inner
                                    .devices
                                    .values()
                                    .filter(|d| d.paired && d.connected)
                                    .map(|d| d.id.clone())
                                    .collect()
                            };
                            for id in targets {
                                daemon.plugin_kick(&id, plugin).await;
                            }
                        }
                        Ok(json!({"ok": true}))
                    }
                }
                "set_presenter_monitor" => {
                    let raw = req["monitor"].as_str().unwrap_or("").trim().to_string();
                    let value = if raw.is_empty() { None } else { Some(raw) };
                    {
                        let mut inner = daemon.inner.lock().await;
                        inner.presenter_monitor = value.clone();
                    }
                    save_presenter_monitor(&daemon.state, value.as_deref());
                    log(&format!(
                        "presenter monitor set to {}",
                        value.as_deref().unwrap_or("auto")
                    ));
                    Ok(json!({"ok": true, "presenterMonitor": value}))
                }
                "send_file" if !daemon.plugin_on("share").await => {
                    Err(anyhow::anyhow!("file sharing plugin is disabled"))
                }
                "mount" if !daemon.plugin_on("sftp").await => {
                    Err(anyhow::anyhow!("sftp plugin is disabled"))
                }
                "ring" if !daemon.plugin_on("findmyphone").await => {
                    Err(anyhow::anyhow!("find my phone plugin is disabled"))
                }
                "send_file" => match req["path"].as_str() {
                    Some(path) => daemon.send_file(device_id, path).await,
                    None => Err(anyhow::anyhow!("path required")),
                },
                _ => Err(anyhow::anyhow!("unknown command")),
            };
            let response = match result {
                Ok(v) => v,
                Err(e) => json!({"ok": false, "error": format!("{:#}", e)}),
            };
            let _ = write_half
                .write_all(format!("{}\n", response).as_bytes())
                .await;
        });
    }
}

// ---- daemon entry -------------------------------------------------------------

async fn run_daemon() -> Result<()> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let dir = state_dir();
    let identity = Arc::new(identity::load_or_create(&dir)?);
    let trust = TrustStore::load(&dir);

    // TCP listener on the first free port of the protocol range.
    let mut listener = None;
    let mut tcp_port = 0;
    for port in TCP_FIRST..=TCP_LAST {
        match TcpListener::bind(("0.0.0.0", port)).await {
            Ok(l) => {
                listener = Some(l);
                tcp_port = port;
                break;
            }
            Err(_) => continue,
        }
    }
    let listener = listener.context("no free TCP port in protocol range")?;

    let (clip_changed_tx, mut clip_changed_rx) =
        tokio::sync::mpsc::channel::<String>(16);
    let clipboard_handle = clipboard::spawn(clip_changed_tx, |msg| log(msg));

    let daemon = Arc::new(Daemon {
        identity: identity.clone(),
        state: dir.clone(),
        tcp_port,
        inner: Mutex::new(Inner {
            devices: HashMap::new(),
            channels: HashMap::new(),
            connecting: HashSet::new(),
            next_channel_gen: 0,
            trust,
            subscribers: Vec::new(),
            notif_ids: HashMap::new(),
            notif_routes: HashMap::new(),
            mpris_players: HashMap::new(),
            mpris_art_sent: HashMap::new(),
            sinks: Vec::new(),
            sink_pending: HashMap::new(),
            sink_applying: std::collections::HashSet::new(),
            sftp_mounts: HashMap::new(),
            presenter_monitor: load_presenter_monitor(&dir),
            phone_players: HashMap::new(),
            phone_art: HashMap::new(),
            phone_art_wanted: HashMap::new(),
            plugins_disabled: load_plugins_disabled(&dir),
            commands: load_commands(&dir),
            running_cmds: std::collections::HashMap::new(),
            next_cmd_id: 1,
            presenter: PresenterState::default(),
            mousepad_acc: (0.0, 0.0),
        }),
        clipboard: clipboard_handle,
        dot: dot::spawn(|msg| log(msg)),
        pointer: pointer::spawn(|msg| log(msg)),
        last_clipboard: Mutex::new(None),
        dbus: Mutex::new(None),
    });

    log(&format!(
        "device {} ({}) listening on TCP {}, state in {}",
        identity.device_name,
        identity.device_id,
        tcp_port,
        dir.display()
    ));

    daemon.sweep_stale_mounts().await;

    let udp = Arc::new(udp_socket()?);
    tokio::spawn(discovery_task(daemon.clone(), udp.clone()));
    tokio::spawn(announce_task(daemon.clone(), udp));
    tokio::spawn(sweeper_task(daemon.clone()));
    tokio::spawn(control_task(
        daemon.clone(),
        dir.join("control.sock"),
    ));
    tokio::spawn(daemon.clone().notif_signal_loop());
    tokio::spawn(daemon.clone().mpris_bridge_loop());
    tokio::spawn(daemon.clone().sink_watch_loop());
    tokio::spawn(daemon.clone().presenter_pointer_loop());
    tokio::spawn(daemon.clone().mousepad_flush_loop());
    {
        let d = daemon.clone();
        tokio::spawn(async move {
            while let Some(content) = clip_changed_rx.recv().await {
                d.on_local_clipboard_changed(content).await;
            }
        });
    }

    loop {
        let (tcp, remote) = listener.accept().await?;
        let d = daemon.clone();
        tokio::spawn(async move { handle_incoming(d, tcp, remote).await });
    }
}

// ---- CLI ------------------------------------------------------------------------

fn control_path() -> PathBuf {
    state_dir().join("control.sock")
}

async fn cli_command(req: Value) -> Result<()> {
    use tokio::net::UnixStream;
    let mut stream = UnixStream::connect(control_path())
        .await
        .context("cannot reach the daemon control socket; is hyprconnect running?")?;
    stream
        .write_all(format!("{}\n", req).as_bytes())
        .await?;
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line).await?;
    let value: Value = serde_json::from_str(line.trim())?;
    println!(
        "{}",
        serde_json::to_string_pretty(&value).unwrap_or(line.trim().to_string())
    );
    Ok(())
}

async fn cli_monitor() -> Result<()> {
    use tokio::net::UnixStream;
    let mut stream = UnixStream::connect(control_path()).await?;
    stream.write_all(b"{\"cmd\":\"monitor\"}\n").await?;
    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    loop {
        line.clear();
        if reader.read_line(&mut line).await? == 0 {
            break;
        }
        print!("{}", line);
        use std::io::Write;
        let _ = std::io::stdout().flush();
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(|s| s.as_str()).unwrap_or("run");
    match cmd {
        "run" => run_daemon().await,
        "devices" => cli_command(json!({"cmd": "devices"})).await,
        "commands" => cli_command(json!({"cmd": "get_commands"})).await,
        "monitor" => cli_monitor().await,
        "pair" | "accept" | "reject" | "unpair" | "mount" | "unmount" | "ring" => {
            let device = args.get(1).context("device id required")?;
            cli_command(json!({"cmd": cmd, "deviceId": device})).await
        }
        "ping" => {
            let device = args.get(1).context("device id required")?;
            let mut req = json!({"cmd": "ping", "deviceId": device});
            if let Some(msg) = args.get(2) {
                req["message"] = json!(msg);
            }
            cli_command(req).await
        }
        "send" => {
            let device = args.get(1).context("device id required")?;
            let path = args.get(2).context("file path required")?;
            cli_command(json!({"cmd": "send_file", "deviceId": device, "path": path})).await
        }
        other => {
            eprintln!("unknown command: {}", other);
            eprintln!("usage: hyprconnect [run|devices|monitor|pair|accept|reject|unpair|mount|unmount|ping|send] [deviceId] [path]");
            std::process::exit(2);
        }
    }
}

/// Destination for a received file: ~/Downloads with the peer's
/// file name reduced to its base name, deduplicated as "name (n)".
fn unique_download_path(filename: &str) -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    let dir = PathBuf::from(home).join("Downloads");
    let _ = std::fs::create_dir_all(&dir);
    let clean = std::path::Path::new(filename)
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .filter(|s| !s.is_empty() && s != "." && s != "..")
        .unwrap_or_else(|| "shared-file".to_string());
    let candidate = dir.join(&clean);
    if !candidate.exists() {
        return candidate;
    }
    let (stem, ext) = match clean.rsplit_once('.') {
        Some((s, e)) if !s.is_empty() => (s.to_string(), format!(".{}", e)),
        _ => (clean.clone(), String::new()),
    };
    for i in 1..1000 {
        let p = dir.join(format!("{} ({}){}", stem, i, ext));
        if !p.exists() {
            return p;
        }
    }
    candidate
}

#[zbus::proxy(
    interface = "org.freedesktop.Notifications",
    default_service = "org.freedesktop.Notifications",
    default_path = "/org/freedesktop/Notifications"
)]
trait Notifications {
    fn notify(
        &self,
        app_name: &str,
        replaces_id: u32,
        app_icon: &str,
        summary: &str,
        body: &str,
        actions: Vec<&str>,
        hints: HashMap<&str, zbus::zvariant::Value<'_>>,
        expire_timeout: i32,
    ) -> zbus::Result<u32>;
    fn close_notification(&self, id: u32) -> zbus::Result<()>;
    #[zbus(signal)]
    fn action_invoked(&self, id: u32, action_key: &str) -> zbus::Result<()>;
    #[zbus(signal)]
    fn notification_replied(&self, id: u32, text: &str) -> zbus::Result<()>;
    #[zbus(signal)]
    fn notification_closed(&self, id: u32, reason: u32) -> zbus::Result<()>;
}

fn ov_str(v: &zbus::zvariant::OwnedValue) -> String {
    use zbus::zvariant::Value;
    match &**v {
        Value::Str(s) => s.to_string(),
        Value::ObjectPath(p) => p.to_string(),
        _ => String::new(),
    }
}

fn ov_str_list(v: &zbus::zvariant::OwnedValue) -> String {
    use zbus::zvariant::Value;
    match &**v {
        Value::Str(s) => s.to_string(),
        Value::Array(a) => a
            .iter()
            .filter_map(|e| match e {
                Value::Str(s) => Some(s.to_string()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join(", "),
        _ => String::new(),
    }
}

fn ov_i64(v: &zbus::zvariant::OwnedValue) -> i64 {
    use zbus::zvariant::Value;
    match &**v {
        Value::I64(x) => *x,
        Value::U64(x) => *x as i64,
        Value::I32(x) => *x as i64,
        Value::U32(x) => *x as i64,
        _ => 0,
    }
}

fn mpris_state_packet(player: &MprisPlayer, pos_ms: i64) -> Packet {
    // Field set mirrors what the Android app itself sends for its own
    // players (captured live): albumArtUrl must be present for the
    // phone to claim the art payload, and nowPlaying, canFastForward
    // and canRewind complete the shape it parses.
    Packet::new(
        "kdeconnect.mpris",
        json!({
            "player": player.name,
            "title": player.title,
            "artist": player.artist,
            "album": player.album,
            "albumArtUrl": player.art_url,
            "supportAlbumArtPayload": true,
            "nowPlaying": player.title,
            "isPlaying": player.is_playing,
            "pos": pos_ms,
            "length": player.length_ms,
            "canPlay": player.can_play,
            "canPause": player.can_pause,
            "canGoNext": player.can_next,
            "canGoPrevious": player.can_prev,
            "canSeek": player.can_seek,
            "canFastForward": player.can_seek,
            "canRewind": player.can_seek,
            "volume": player.volume,
        }),
    )
}

fn sftp_mountpoint(device_name: &str, device_id: &str) -> PathBuf {
    let clean: String = device_name
        .trim()
        .chars()
        .map(|c| {
            if c == '/' || c.is_control() {
                '_'
            } else {
                c
            }
        })
        .collect();
    let clean = if clean.is_empty() {
        device_id.chars().take(8).collect()
    } else {
        clean
    };
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home).join("Devices").join(clean)
}

async fn mount_is_active(mountpoint: &std::path::Path) -> bool {
    let Ok(mounts) = tokio::fs::read_to_string("/proc/mounts").await else {
        return false;
    };
    let mp = mountpoint.to_string_lossy();
    mounts.lines().any(|l| {
        l.split_whitespace()
            .nth(1)
            .map(|t| {
                t.replace("\\040", " ")
                    .replace("\\011", "\t")
                    .replace("\\012", "\n")
                    .replace("\\134", "\\")
                    == mp.as_ref()
            })
            .unwrap_or(false)
    })
}

/// Whether a mountpoint actually serves entries right now. A dead
/// sshfs answers fast with ENOTCONN, a wedged one can hang, so the
/// probe is time-boxed.
async fn mount_serves(mountpoint: &std::path::Path) -> bool {
    let probe = async {
        match tokio::fs::read_dir(mountpoint).await {
            Ok(mut rd) => matches!(rd.next_entry().await, Ok(_)),
            Err(_) => false,
        }
    };
    tokio::time::timeout(std::time::Duration::from_secs(3), probe)
        .await
        .unwrap_or(false)
}

fn load_presenter_monitor(dir: &std::path::Path) -> Option<String> {
    let text = std::fs::read_to_string(dir.join("presenter.json")).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    v["monitor"]
        .as_str()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn save_presenter_monitor(dir: &std::path::Path, monitor: Option<&str>) {
    let v = json!({ "monitor": monitor });
    let _ = std::fs::write(
        dir.join("presenter.json"),
        format!("{}\n", serde_json::to_string_pretty(&v).unwrap_or_default()),
    );
}

/// Names of the connected monitors, for the presenter target picker.
/// The instance signature is discovered the same way the shell
/// scripts do it: the single entry under $XDG_RUNTIME_DIR/hypr.
async fn hypr_monitor_names() -> Vec<String> {
    let xdg = std::env::var("XDG_RUNTIME_DIR")
        .unwrap_or_else(|_| "/run/user/1000".to_string());
    let hypr_dir = PathBuf::from(&xdg).join("hypr");
    let signature = std::fs::read_dir(&hypr_dir).ok().and_then(|mut rd| {
        rd.next()
            .and_then(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().to_string())
    });
    let Some(signature) = signature else {
        return Vec::new();
    };
    let out = tokio::process::Command::new("hyprctl")
        .args(["monitors", "-j"])
        .env("XDG_RUNTIME_DIR", &xdg)
        .env("HYPRLAND_INSTANCE_SIGNATURE", &signature)
        .env(
            "WAYLAND_DISPLAY",
            std::env::var("WAYLAND_DISPLAY").unwrap_or_else(|_| "wayland-1".to_string()),
        )
        .output()
        .await;
    let Ok(out) = out else { return Vec::new() };
    let Ok(v) = serde_json::from_slice::<Value>(&out.stdout) else {
        return Vec::new();
    };
    v.as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|m| m["name"].as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default()
}

impl Daemon {
    /// Merge one kdeconnect.mpris packet from the phone into the
    /// stored per-player state, and ask for now-playing details of
    /// players we only know by name so far.
    async fn store_phone_player(self: &Arc<Self>, device_id: &str, packet: &Packet) {
        let body = &packet.body;
        // Album art answer: the phone replies to a pull request with
        // transferringAlbumArt and the image as the packet payload.
        if body["transferringAlbumArt"].as_bool() == Some(true) {
            if let (Some(info), Some(size)) =
                (&packet.payload_transfer_info, packet.payload_size)
            {
                if size > 0 && size <= 8_000_000 {
                    if let Some(port) = info.get("port").and_then(|p| p.as_u64()) {
                        match self
                            .download_payload(device_id, port as u16, size as usize)
                            .await
                        {
                            Ok(bytes) => {
                                let player =
                                    body["player"].as_str().unwrap_or("player").to_string();
                                let safe: String = player
                                    .chars()
                                    .map(|c| if c.is_alphanumeric() { c } else { '_' })
                                    .collect();
                                let ext = if bytes.starts_with(&[0xFF, 0xD8]) {
                                    "jpg"
                                } else if bytes.starts_with(&[0x89, b'P', b'N', b'G']) {
                                    "png"
                                } else if bytes.starts_with(b"RIFF") {
                                    "webp"
                                } else {
                                    "bin"
                                };
                                let dir = self.state.join("art");
                                let _ = tokio::fs::create_dir_all(&dir).await;
                                let path =
                                    dir.join(format!("{}-{}.{}", device_id, safe, ext));
                                if tokio::fs::write(&path, &bytes).await.is_ok() {
                                    let mut inner = self.inner.lock().await;
                                    inner
                                        .phone_art
                                        .entry(device_id.to_string())
                                        .or_default()
                                        .insert(
                                            player.clone(),
                                            path.to_string_lossy().to_string(),
                                        );
                                    log(&format!(
                                        "phone album art for {} saved ({} bytes)",
                                        player,
                                        bytes.len()
                                    ));
                                }
                            }
                            Err(e) => {
                                log(&format!("phone album art download failed: {:#}", e))
                            }
                        }
                    }
                }
            }
        }
        let mut want_details: Vec<String> = Vec::new();
        {
            let mut inner = self.inner.lock().await;
            let players = inner
                .phone_players
                .entry(device_id.to_string())
                .or_default();
            if let Some(list) = body["playerList"].as_array() {
                let names: Vec<String> = list
                    .iter()
                    .filter_map(|p| p.as_str().map(|s| s.to_string()))
                    .collect();
                players.retain(|name, _| names.contains(name));
                for name in &names {
                    if !players.contains_key(name) {
                        players.insert(name.clone(), json!({ "player": name }));
                        want_details.push(name.clone());
                    }
                }
            }
            if let Some(player) = body["player"].as_str() {
                let entry = players
                    .entry(player.to_string())
                    .or_insert_with(|| json!({ "player": player }));
                if let (Value::Object(dst), Value::Object(src)) =
                    (&mut *entry, body)
                {
                    for (k, v) in src {
                        dst.insert(k.clone(), v.clone());
                    }
                }
            }
        }
        for player in want_details {
            self.send_packet(
                device_id,
                Packet::new(
                    "kdeconnect.mpris.request",
                    json!({
                        "player": player,
                        "requestNowPlaying": true,
                        "requestVolume": true,
                    }),
                ),
            )
            .await;
        }
        // Album art is a pull protocol: when the now-playing state
        // names an art URL we have not fetched yet, ask for it.
        let want_art: Option<(String, String)> = {
            let mut inner = self.inner.lock().await;
            let mut out = None;
            if let Some(player) = body["player"].as_str() {
                if let Some(entry) = inner
                    .phone_players
                    .get(device_id)
                    .and_then(|ps| ps.get(player))
                {
                    let url = entry["albumArtUrl"].as_str().unwrap_or("").to_string();
                    // The phone does not advertise a support flag for
                    // its own players; it answers art pulls for the
                    // URL it published, so just ask.
                    if !url.is_empty() {
                        let wanted = inner
                            .phone_art_wanted
                            .entry(device_id.to_string())
                            .or_default();
                        if wanted.get(player).map(|u| u.as_str()) != Some(url.as_str()) {
                            wanted.insert(player.to_string(), url.clone());
                            out = Some((player.to_string(), url));
                        }
                    }
                }
            }
            out
        };
        if let Some((player, url)) = want_art {
            self.send_packet(
                device_id,
                Packet::new(
                    "kdeconnect.mpris.request",
                    json!({ "player": player, "albumArtUrl": url }),
                ),
            )
            .await;
        }
    }
}

fn load_commands(dir: &std::path::Path) -> serde_json::Map<String, Value> {
    let Ok(text) = std::fs::read_to_string(dir.join("commands.json")) else {
        return serde_json::Map::new();
    };
    serde_json::from_str::<Value>(&text)
        .ok()
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default()
}

fn save_commands(dir: &std::path::Path, commands: &serde_json::Map<String, Value>) {
    let text =
        serde_json::to_string_pretty(&Value::Object(commands.clone())).unwrap_or_default();
    let _ = std::fs::write(dir.join("commands.json"), text);
}

fn load_plugins_disabled(dir: &std::path::Path) -> std::collections::HashSet<String> {
    let Ok(text) = std::fs::read_to_string(dir.join("settings.json")) else {
        return std::collections::HashSet::new();
    };
    let Ok(v) = serde_json::from_str::<Value>(&text) else {
        return std::collections::HashSet::new();
    };
    v["pluginsDisabled"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default()
}

fn save_plugins_disabled(dir: &std::path::Path, disabled: &std::collections::HashSet<String>) {
    let v = json!({ "pluginsDisabled": disabled.iter().collect::<Vec<_>>() });
    let _ = std::fs::write(
        dir.join("settings.json"),
        format!("{}\n", serde_json::to_string_pretty(&v).unwrap_or_default()),
    );
}

impl Daemon {
    /// Fire a plugin's connect-time requests at one device, used
    /// when the plugin is switched back on while devices are live.
    /// Send this device our run-command list. Upstream sends it on connect,
    /// when the phone asks, and whenever the list changes. The list travels
    /// as a JSON string: an object of key -> {name, command}.
    async fn send_command_list(self: &Arc<Self>, device_id: &str) {
        let list = {
            let cmds = self.inner.lock().await.commands.clone();
            serde_json::to_string(&Value::Object(cmds)).unwrap_or_else(|_| "{}".into())
        };
        self.send_packet(
            device_id,
            Packet::new(
                "kdeconnect.runcommand",
                json!({ "commandList": list, "canAddCommand": true }),
            ),
        )
        .await;
    }

    /// Execute one predefined command for a paired phone and stream its
    /// output back, upstream-style: commandStarted, batched commandOutput
    /// line packets, then commandFinished with the exit code.
    async fn run_remote_command(self: &Arc<Self>, device_id: &str, key: &str) {
        let entry = self.inner.lock().await.commands.get(key).cloned();
        let Some(entry) = entry else {
            log(&format!("runcommand: unknown key {key} from {device_id}"));
            return;
        };
        let command = entry
            .get("command")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if command.trim().is_empty() {
            return;
        }
        let id = {
            let mut inner = self.inner.lock().await;
            let id = inner.next_cmd_id;
            inner.next_cmd_id = inner.next_cmd_id.wrapping_add(1).max(1);
            id
        };
        let mut cmd = tokio::process::Command::new("/bin/sh");
        cmd.arg("-c")
            .arg(&command)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .current_dir(std::env::var("HOME").unwrap_or_else(|_| "/".into()));
        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                log(&format!("runcommand: spawn failed: {e}"));
                return;
            }
        };
        if let Some(pid) = child.id() {
            self.inner.lock().await.running_cmds.insert(id, pid);
        }
        self.send_packet(
            device_id,
            Packet::new(
                "kdeconnect.runcommand.output",
                json!({ "commandStarted": true, "id": id, "command": command }),
            ),
        )
        .await;
        let stdout: std::pin::Pin<Box<dyn tokio::io::AsyncRead + Send>> =
            Box::pin(child.stdout.take().unwrap());
        let stderr: std::pin::Pin<Box<dyn tokio::io::AsyncRead + Send>> =
            Box::pin(child.stderr.take().unwrap());
        let daemon = self.clone();
        let dev = device_id.to_string();
        tokio::spawn(async move {
            let (tx, mut rx) = mpsc::channel::<(bool, String)>(64);
            for (is_err, stream) in [(false, stdout), (true, stderr)] {
                let tx = tx.clone();
                tokio::spawn(async move {
                    let mut lines = BufReader::new(stream).lines();
                    while let Ok(Some(line)) = lines.next_line().await {
                        if tx.send((is_err, line)).await.is_err() {
                            break;
                        }
                    }
                });
            }
            drop(tx);
            let mut out_lines: Vec<String> = Vec::new();
            let mut err_lines: Vec<String> = Vec::new();
            loop {
                let flush = tokio::select! {
                    msg = rx.recv() => match msg {
                        Some((is_err, line)) => {
                            if is_err {
                                err_lines.push(line);
                            } else {
                                out_lines.push(line);
                            }
                            out_lines.len() >= 5 || err_lines.len() >= 5
                        }
                        None => break,
                    },
                    _ = tokio::time::sleep(std::time::Duration::from_millis(100)) => {
                        !out_lines.is_empty() || !err_lines.is_empty()
                    }
                };
                if flush && (!out_lines.is_empty() || !err_lines.is_empty()) {
                    daemon
                        .send_packet(
                            &dev,
                            Packet::new(
                                "kdeconnect.runcommand.output",
                                json!({
                                    "commandOutput": true,
                                    "stdout": std::mem::take(&mut out_lines),
                                    "stderr": std::mem::take(&mut err_lines),
                                    "id": id,
                                }),
                            ),
                        )
                        .await;
                }
            }
            if !out_lines.is_empty() || !err_lines.is_empty() {
                daemon
                    .send_packet(
                        &dev,
                        Packet::new(
                            "kdeconnect.runcommand.output",
                            json!({
                                "commandOutput": true,
                                "stdout": out_lines,
                                "stderr": err_lines,
                                "id": id,
                            }),
                        ),
                    )
                    .await;
            }
            let (success, code) = match child.wait().await {
                Ok(st) => (st.success(), st.code().unwrap_or(1)),
                Err(_) => (false, 1),
            };
            daemon.inner.lock().await.running_cmds.remove(&id);
            daemon
                .send_packet(
                    &dev,
                    Packet::new(
                        "kdeconnect.runcommand.output",
                        json!({
                            "commandFinished": true,
                            "success": success,
                            "exitCode": code,
                            "id": id,
                        }),
                    ),
                )
                .await;
        });
    }

    /// Terminate every command a phone started (the phone's stop button).
    async fn stop_remote_commands(self: &Arc<Self>) {
        let pids: Vec<u32> = self
            .inner
            .lock()
            .await
            .running_cmds
            .values()
            .copied()
            .collect();
        for pid in pids {
            if pid > 0 {
                unsafe {
                    libc::kill(pid as i32, libc::SIGTERM);
                }
            }
        }
    }

    async fn plugin_kick(self: &Arc<Self>, device_id: &str, plugin: &str) {
        match plugin {
            "notification" => {
                self.send_packet(
                    device_id,
                    Packet::new(
                        "kdeconnect.notification.request",
                        json!({ "request": true }),
                    ),
                )
                .await;
            }
            "battery" => {
                self.send_packet(
                    device_id,
                    Packet::new(
                        "kdeconnect.battery.request",
                        json!({ "request": true }),
                    ),
                )
                .await;
            }
            "runcommand" => {
                self.send_command_list(device_id).await;
            }
            "mpris" => {
                self.mpris_send_all_to(device_id).await;
                self.send_packet(
                    device_id,
                    Packet::new(
                        "kdeconnect.mpris.request",
                        json!({ "requestPlayerList": true }),
                    ),
                )
                .await;
            }
            "systemvolume" => {
                self.send_sink_list(device_id).await;
            }
            "sftp" => {
                self.request_sftp(device_id).await;
            }
            "clipboard" => {
                if let Some(handle) = &self.clipboard {
                    let current = handle.current.lock().unwrap().clone();
                    if let Some(content) = current {
                        self.send_packet(
                            device_id,
                            Packet::new(
                                "kdeconnect.clipboard.connect",
                                json!({ "content": content }),
                            ),
                        )
                        .await;
                    }
                }
            }
            _ => {}
        }
    }
}

impl Daemon {
    /// Startup sweep for orphaned SFTP mounts. When a daemon dies,
    /// systemd takes its sshfs children with it, but the FUSE
    /// entries stay in the kernel as corpses that answer ENOTCONN
    /// ("Transport endpoint is not connected") and block the folder
    /// in every file manager. The new process tracks none of them,
    /// so before anything else it walks ~/Devices and lazily
    /// unmounts every sshfs mount that no longer serves.
    async fn sweep_stale_mounts(&self) {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        let root = PathBuf::from(home).join("Devices");
        let Ok(mut rd) = tokio::fs::read_dir(&root).await else {
            return;
        };
        let mut candidates: Vec<PathBuf> = Vec::new();
        while let Ok(Some(entry)) = rd.next_entry().await {
            candidates.push(entry.path());
        }
        if candidates.is_empty() {
            return;
        }
        let mounts_text = tokio::fs::read_to_string("/proc/mounts")
            .await
            .unwrap_or_default();
        let sshfs_mounts: Vec<String> = mounts_text
            .lines()
            .filter_map(|l| {
                let mut fields = l.split_whitespace();
                let _src = fields.next()?;
                let target = fields.next()?;
                let fstype = fields.next()?;
                if fstype == "fuse.sshfs" {
                    Some(
                        target
                            .replace("\\040", " ")
                            .replace("\\011", "\t")
                            .replace("\\012", "\n")
                            .replace("\\134", "\\"),
                    )
                } else {
                    None
                }
            })
            .collect();
        for path in candidates {
            let mp = path.to_string_lossy().to_string();
            if !sshfs_mounts.iter().any(|m| m == &mp) {
                continue;
            }
            if mount_serves(&path).await {
                continue;
            }
            let out = tokio::process::Command::new("fusermount3")
                .args(["-u", &mp])
                .output()
                .await;
            if !matches!(out, Ok(o) if o.status.success()) {
                let _ = tokio::process::Command::new("fusermount3")
                    .args(["-uz", &mp])
                    .output()
                    .await;
            }
            let _ = tokio::fs::remove_dir(&path).await;
            log(&format!("startup sweep: removed stale mount {}", mp));
        }
    }
}

/// One axis of HyprPresenter-style pointer easing: close half of
/// the remaining distance to the target per tick, snapping the
/// final sub-`snap` remainder so the dot settles exactly on the
/// target instead of creeping toward it forever.
fn ease_axis(current: f64, target: f64, snap: f64) -> f64 {
    let next = current + (target - current) * 0.5;
    if (target - next).abs() <= snap {
        target
    } else {
        next
    }
}

#[derive(Default)]
struct PresenterState {
    acc_x: f64,
    acc_y: f64,
    session: bool,
    /// Target dot position as fractions of the session monitor. The
    /// reference presenter accumulates the phone's raw gyro deltas
    /// exactly this way (y scaled by the screen ratio).
    fx: f64,
    fy: f64,
    /// Position actually shown on screen. The pointer loop eases
    /// this toward the target HyprPresenter-style (half the
    /// remaining distance per 20 ms tick) so bursty delta packets
    /// glide instead of teleporting the dot in chunks.
    out_x: f64,
    out_y: f64,
    /// Session monitor size in pixels; the easing snaps to the
    /// target once within half a pixel.
    mon_w: u32,
    mon_h: u32,
    /// Width over height of the session monitor.
    ratio: f64,
    last_packet: Option<std::time::Instant>,
}

struct Mon {
    name: String,
    x: i64,
    y: i64,
    w: i64,
    h: i64,
    focused: bool,
}

fn hyprctl_cmd() -> tokio::process::Command {
    let mut cmd = tokio::process::Command::new("hyprctl");
    let runtime = std::env::var("XDG_RUNTIME_DIR")
        .unwrap_or_else(|_| format!("/run/user/{}", unsafe { libc::getuid() }));
    cmd.env("XDG_RUNTIME_DIR", &runtime);
    if let Ok(rd) = std::fs::read_dir(format!("{}/hypr", runtime)) {
        for entry in rd.flatten() {
            cmd.env(
                "HYPRLAND_INSTANCE_SIGNATURE",
                entry.file_name().to_string_lossy().to_string(),
            );
            break;
        }
    }
    cmd
}

async fn hypr_dispatch(expr: &str) {
    let _ = hyprctl_cmd()
        .args(["dispatch", expr])
        .output()
        .await;
}

async fn hypr_monitors() -> Vec<Mon> {
    let Ok(out) = hyprctl_cmd().args(["monitors", "-j"]).output().await else {
        return Vec::new();
    };
    let Ok(v) = serde_json::from_slice::<Value>(&out.stdout) else {
        return Vec::new();
    };
    v.as_array()
        .map(|arr| {
            arr.iter()
                .filter_map(|m| {
                    let scale = m["scale"].as_f64().unwrap_or(1.0);
                    Some(Mon {
                        name: m["name"].as_str()?.to_string(),
                        x: m["x"].as_i64().unwrap_or(0),
                        y: m["y"].as_i64().unwrap_or(0),
                        w: (m["width"].as_f64()? / scale).round() as i64,
                        h: (m["height"].as_f64()? / scale).round() as i64,
                        focused: m["focused"].as_bool().unwrap_or(false),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

async fn send_key(code: u32) {
    let runtime = std::env::var("XDG_RUNTIME_DIR")
        .unwrap_or_else(|_| format!("/run/user/{}", unsafe { libc::getuid() }));
    let _ = tokio::process::Command::new("ydotool")
        .env("XDG_RUNTIME_DIR", &runtime)
        .args(["key", &format!("{}:1", code), &format!("{}:0", code)])
        .output()
        .await;
}


async fn ydotool_keys(args: &[String]) {
    let runtime = std::env::var("XDG_RUNTIME_DIR")
        .unwrap_or_else(|_| format!("/run/user/{}", unsafe { libc::getuid() }));
    let mut full: Vec<&str> = vec!["key"];
    full.extend(args.iter().map(|a| a.as_str()));
    let _ = tokio::process::Command::new("ydotool")
        .env("XDG_RUNTIME_DIR", &runtime)
        .args(&full)
        .output()
        .await;
}

/// Presses a key while holding modifier keycodes (and Shift when
/// the character needs it).
async fn send_key_combo(mods: &[u32], code: u32, shift: bool) {
    let mut held: Vec<u32> = mods.to_vec();
    if shift && !held.contains(&42) {
        held.push(42); // KEY_LEFTSHIFT
    }
    let mut args: Vec<String> =
        held.iter().map(|c| format!("{}:1", c)).collect();
    args.push(format!("{}:1", code));
    args.push(format!("{}:0", code));
    for c in held.iter().rev() {
        args.push(format!("{}:0", c));
    }
    ydotool_keys(&args).await;
}

/// Evdev keycodes for the mousepad protocol's specialKey table,
/// mirroring the reference desktop implementation (index 0 is
/// invalid; F1 to F12 occupy 21 to 32).
fn special_key_evdev(special: i64) -> Option<u32> {
    Some(match special {
        1 => 14,   // BACKSPACE
        2 => 15,   // TAB
        3 => 28,   // LINEFEED acts as ENTER
        4 => 105,  // LEFT
        5 => 103,  // UP
        6 => 106,  // RIGHT
        7 => 108,  // DOWN
        8 => 104,  // PAGEUP
        9 => 109,  // PAGEDOWN
        10 => 102, // HOME
        11 => 107, // END
        12 => 28,  // ENTER
        13 => 111, // DELETE
        14 => 1,   // ESC
        15 => 99,  // SYSRQ
        16 => 70,  // SCROLLLOCK
        17 => 29,  // LEFTCTRL
        18 => 56,  // LEFTALT
        19 => 42,  // LEFTSHIFT
        20 => 125, // LEFTMETA
        21..=32 => {
            [59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 87, 88]
                [(special - 21) as usize]
        }
        _ => return None,
    })
}

/// Evdev keycode and Shift need for a printable character on a US
/// layout, which is what ydotool assumes as well.
fn char_key(c: char) -> Option<(u32, bool)> {
    Some(match c {
        'a'..='z' => (
            match c {
                'a' => 30, 'b' => 48, 'c' => 46, 'd' => 32, 'e' => 18,
                'f' => 33, 'g' => 34, 'h' => 35, 'i' => 23, 'j' => 36,
                'k' => 37, 'l' => 38, 'm' => 50, 'n' => 49, 'o' => 24,
                'p' => 25, 'q' => 16, 'r' => 19, 's' => 31, 't' => 20,
                'u' => 22, 'v' => 47, 'w' => 17, 'x' => 45, 'y' => 21,
                _ => 44, // z
            },
            false,
        ),
        'A'..='Z' => (char_key(c.to_ascii_lowercase())?.0, true),
        '1'..='9' => (c as u32 - '1' as u32 + 2, false),
        '0' => (11, false),
        '!' => (2, true),
        '@' => (3, true),
        '#' => (4, true),
        '$' => (5, true),
        '%' => (6, true),
        '^' => (7, true),
        '&' => (8, true),
        '*' => (9, true),
        '(' => (10, true),
        ')' => (11, true),
        '-' => (12, false),
        '_' => (12, true),
        '=' => (21, false),
        '+' => (21, true),
        ' ' => (57, false),
        '.' => (52, false),
        ',' => (51, false),
        '/' => (53, false),
        '?' => (53, true),
        ';' => (39, false),
        ':' => (39, true),
        '\'' => (40, false),
        '"' => (40, true),
        '[' => (26, false),
        ']' => (27, false),
        '\\' => (43, false),
        '`' => (41, false),
        '~' => (41, true),
        _ => return None,
    })
}

impl Daemon {
    /// kdeconnect.mousepad.request, the remote input plugin.
    /// The phone's presentation remote also sends its slide
    /// controls through this packet type (next is specialKey 9,
    /// PageDown; previous is 8, PageUp; fullscreen 25, F5; exit
    /// 14, Esc; zoom is a ctrl-modified "+" or "-" key packet),
    /// with modifier booleans riding along ("super" is what the
    /// phone calls the meta modifier). Pointer motion, buttons
    /// and scroll go to the daemon's virtual pointer; keys keep
    /// using ydotool, since they arrive at typing speed.
    async fn handle_mousepad(self: &Arc<Self>, body: &Value) {
        let b = |k: &str| body[k].as_bool() == Some(true);
        if let Some(ptr) = &self.pointer {
            // Button codes are evdev: 272 left, 273 right, 274 middle.
            if b("singleclick") {
                ptr.click(272);
                return;
            }
            if b("doubleclick") {
                ptr.click(272);
                ptr.click(272);
                return;
            }
            if b("middleclick") {
                ptr.click(274);
                return;
            }
            if b("rightclick") {
                ptr.click(273);
                return;
            }
            if b("singlehold") {
                ptr.button(272, true);
                return;
            }
            if b("singlerelease") {
                ptr.button(272, false);
                return;
            }
            if b("scroll") {
                ptr.axis(
                    body["dx"].as_f64().unwrap_or(0.0),
                    body["dy"].as_f64().unwrap_or(0.0),
                );
                return;
            }
        }
        let mut mods: Vec<u32> = Vec::new();
        if b("ctrl") {
            mods.push(29);
        }
        if b("alt") {
            mods.push(56);
        }
        if b("super") || b("meta") {
            mods.push(125);
        }
        let shift = b("shift");
        if let Some(sk) = body["specialKey"].as_i64() {
            match special_key_evdev(sk) {
                Some(code) => {
                    if mods.is_empty() && !shift {
                        send_key(code).await;
                    } else {
                        send_key_combo(&mods, code, shift).await;
                    }
                }
                None => {
                    log(&format!("mousepad specialKey {} (unknown)", sk));
                }
            }
            return;
        }
        if let Some(key) = body["key"].as_str() {
            let mut chars = key.chars();
            if let (Some(c), None) = (chars.next(), chars.next()) {
                if let Some((code, needs_shift)) = char_key(c) {
                    send_key_combo(&mods, code, shift || needs_shift).await;
                    return;
                }
            }
            if mods.is_empty() && !key.is_empty() {
                let runtime = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| {
                    format!("/run/user/{}", unsafe { libc::getuid() })
                });
                let _ = tokio::process::Command::new("ydotool")
                    .env("XDG_RUNTIME_DIR", &runtime)
                    .args(["type", key])
                    .output()
                    .await;
            }
            return;
        }
        let (dx, dy) = (
            body["dx"].as_f64().unwrap_or(0.0),
            body["dy"].as_f64().unwrap_or(0.0),
        );
        if dx != 0.0 || dy != 0.0 {
            let mut inner = self.inner.lock().await;
            inner.mousepad_acc.0 += dx;
            inner.mousepad_acc.1 += dy;
            return;
        }
        if body.get("x").is_some() || body.get("y").is_some() {
            static ONCE: std::sync::Once = std::sync::Once::new();
            ONCE.call_once(|| {
                log("mousepad absolute motion packets are not supported");
            });
        }
    }

    /// Flushes accumulated touchpad deltas to the virtual pointer
    /// at ~120 Hz so a burst of packets becomes smooth motion.
    async fn mousepad_flush_loop(self: Arc<Self>) {
        loop {
            tokio::time::sleep(std::time::Duration::from_millis(8)).await;
            let step = {
                let mut inner = self.inner.lock().await;
                let acc = inner.mousepad_acc;
                inner.mousepad_acc = (0.0, 0.0);
                acc
            };
            if step != (0.0, 0.0) {
                if let Some(ptr) = &self.pointer {
                    ptr.move_by(step.0, step.1);
                }
            }
        }
    }

    /// kdeconnect.presenter, the presentation remote.
    ///
    /// Stock shapes (dx/dy pointer deltas, stop) are untouched. The
    /// monitor extension is additive: the phone may ask for the
    /// monitor list ("requestMonitorList": true) or pin the presenter
    /// pointer to one monitor ("setMonitor": "<name>", "" for
    /// automatic); the daemon answers with a kdeconnect.presenter
    /// packet carrying "monitors" and "presenterMonitor". Stock
    /// clients never send these fields and never receive the reply,
    /// so they are unaffected.
    /// Reply to one device with the current monitor list and the
    /// pinned presenter monitor (None = automatic). Best effort: a
    /// disconnected device or a disabled presenter plugin just drops it.
    async fn send_presenter_monitors(self: &Arc<Self>, device_id: &str) {
        let monitor = {
            let inner = self.inner.lock().await;
            inner.presenter_monitor.clone()
        };
        let monitors = hypr_monitor_names().await;
        self.send_packet(
            device_id,
            Packet::new(
                "kdeconnect.presenter",
                json!({
                    "monitors": monitors,
                    "presenterMonitor": monitor,
                }),
            ),
        )
        .await;
    }

    async fn handle_presenter(self: &Arc<Self>, device_id: &str, body: &Value) {
        if body["requestMonitorList"].as_bool() == Some(true) {
            self.send_presenter_monitors(device_id).await;
            return;
        }
        if let Some(name) = body["setMonitor"].as_str() {
            let trimmed = name.trim();
            let value = if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            };
            {
                let mut inner = self.inner.lock().await;
                inner.presenter_monitor = value.clone();
            }
            save_presenter_monitor(&self.state, value.as_deref());
            log(&format!(
                "presenter monitor set to {}",
                value.as_deref().unwrap_or("auto")
            ));
            self.send_presenter_monitors(device_id).await;
            return;
        }
        if body["stop"].as_bool() == Some(true) {
            let mut inner = self.inner.lock().await;
            if inner.presenter.session {
                inner.presenter.session = false;
                inner.presenter.acc_x = 0.0;
                inner.presenter.acc_y = 0.0;
                drop(inner);
                if let Some(dot) = &self.dot {
                    dot.hide();
                }
                log("presenter session stopped");
            }
            return;
        }
        let (Some(dx), Some(dy)) = (body["dx"].as_f64(), body["dy"].as_f64())
        else {
            log(&format!(
                "presenter packet (unhandled shape): {}",
                serde_json::to_string(body).unwrap_or_default()
            ));
            return;
        };
        let start = {
            let mut inner = self.inner.lock().await;
            inner.presenter.acc_x += dx;
            inner.presenter.acc_y += dy;
            inner.presenter.last_packet = Some(std::time::Instant::now());
            !inner.presenter.session
        };
        if start {
            self.presenter_begin_session().await;
        }
    }

    async fn presenter_begin_session(self: &Arc<Self>) {
        let monitors = hypr_monitors().await;
        if monitors.is_empty() {
            log("presenter: no monitors reported by hyprctl");
            return;
        }
        let wanted = {
            let inner = self.inner.lock().await;
            inner.presenter_monitor.clone()
        };
        let pick = wanted
            .as_ref()
            .and_then(|w| monitors.iter().find(|m| &m.name == w))
            .or_else(|| monitors.iter().find(|m| !m.name.starts_with("eDP")))
            .or_else(|| monitors.iter().find(|m| m.focused))
            .unwrap_or(&monitors[0]);
        {
            let mut inner = self.inner.lock().await;
            let p = &mut inner.presenter;
            p.session = true;
            p.fx = 0.5;
            p.fy = 0.5;
            p.out_x = 0.5;
            p.out_y = 0.5;
            p.mon_w = pick.w.max(0) as u32;
            p.mon_h = pick.h.max(0) as u32;
            p.ratio = if pick.h > 0 {
                pick.w as f64 / pick.h as f64
            } else {
                1.0
            };
        }
        if let Some(dot) = &self.dot {
            dot.show(&pick.name);
            dot.move_to(0.5, 0.5);
        }
        log(&format!("presenter session started on {}", pick.name));
    }

    /// Pointer loop at ~50 Hz, HyprPresenter-style: accumulated
    /// gyro deltas only move the TARGET; the shown position eases
    /// halfway toward it per tick, so packets arriving in bursts
    /// become a continuous glide and the newest target always wins
    /// (there is no backlog of stale positions to crawl through).
    async fn presenter_pointer_loop(self: Arc<Self>) {
        loop {
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            let mut timed_out = false;
            let step = {
                let mut inner = self.inner.lock().await;
                let p = &mut inner.presenter;
                if p.session
                    && p.last_packet
                        .map(|t| t.elapsed() > std::time::Duration::from_secs(3))
                        .unwrap_or(false)
                {
                    p.session = false;
                    p.acc_x = 0.0;
                    p.acc_y = 0.0;
                    timed_out = true;
                }
                if !p.session {
                    None
                } else {
                    let (dx, dy) = (p.acc_x, p.acc_y);
                    p.acc_x = 0.0;
                    p.acc_y = 0.0;
                    p.fx = (p.fx + dx).clamp(0.0, 1.0);
                    p.fy = (p.fy + dy * p.ratio).clamp(0.0, 1.0);
                    let snap_x = if p.mon_w > 0 {
                        0.5 / p.mon_w as f64
                    } else {
                        0.5 / 1920.0
                    };
                    let snap_y = if p.mon_h > 0 {
                        0.5 / p.mon_h as f64
                    } else {
                        0.5 / 1080.0
                    };
                    let nx = ease_axis(p.out_x, p.fx, snap_x);
                    let ny = ease_axis(p.out_y, p.fy, snap_y);
                    if nx != p.out_x || ny != p.out_y {
                        p.out_x = nx;
                        p.out_y = ny;
                        Some((nx, ny))
                    } else {
                        None
                    }
                }
            };
            if timed_out {
                if let Some(dot) = &self.dot {
                    dot.hide();
                }
                log("presenter session timed out");
            }
            if let Some((fx, fy)) = step {
                if let Some(dot) = &self.dot {
                    dot.move_to(fx, fy);
                }
            }
        }
    }
}

#[cfg(test)]
mod presenter_ease_tests {
    use super::ease_axis;

    #[test]
    fn halves_the_remaining_gap_each_tick() {
        assert_eq!(ease_axis(0.0, 1.0, 0.0), 0.5);
        assert_eq!(ease_axis(0.5, 1.0, 0.0), 0.75);
        assert_eq!(ease_axis(1.0, 0.0, 0.0), 0.5);
    }

    #[test]
    fn snaps_the_final_subpixel_step() {
        // next would be 0.95, remaining 0.05 <= snap 0.2 -> exact target.
        assert_eq!(ease_axis(0.9, 1.0, 0.2), 1.0);
        // Already on target: stays exactly, so the loop stops emitting.
        assert_eq!(ease_axis(0.5, 0.5, 0.001), 0.5);
    }

    #[test]
    fn a_burst_target_becomes_a_glide_with_shrinking_steps() {
        // One burst moves the target 0.2 -> 0.8 at once (what a packet
        // burst did to the shown position before easing). The shown
        // position must now approach monotonically, never overshoot,
        // with strictly shrinking steps, and settle exactly on target.
        let snap = 0.5 / 1920.0;
        let mut pos = 0.2;
        let mut prev_step = f64::INFINITY;
        let mut steps = 0;
        while pos != 0.8 {
            let next = ease_axis(pos, 0.8, snap);
            assert!(next > pos && next <= 0.8, "monotonic, no overshoot");
            let step = next - pos;
            assert!(step < prev_step, "steps shrink as it glides");
            prev_step = step;
            pos = next;
            steps += 1;
            assert!(steps < 40, "settles quickly");
        }
        assert!(steps >= 8, "a burst spreads over many ticks, got {steps}");
    }
}
