//! HyprConnect daemon and CLI.
//!
//! Phase 0: discovery, TLS transport, KDE Connect-style pairing with
//! persistent trust and automatic reconnection. The daemon exposes a
//! JSON-lines control socket in its state directory; the CLI (and later
//! the GTK app) talk to it there.

use anyhow::{Context, Result};
use hyprconnect::clipboard;
use hyprconnect::identity::{self, LocalIdentity};
use hyprconnect::packet::Packet;
use hyprconnect::store::{hex_encode, TrustStore, TrustedDevice};
use hyprconnect::{tls, identity::state_dir};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream, UdpSocket, UnixListener};
use tokio::sync::{mpsc, Mutex};

const UDP_PORT: u16 = 1716;
const TCP_FIRST: u16 = 1714;
const TCP_LAST: u16 = 1764;
const PAIR_TIMEOUT: Duration = Duration::from_secs(30);

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
    peer_spki: Vec<u8>,
    peer_cert: Vec<u8>,
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
            peer_spki: Vec::new(),
            peer_cert: Vec::new(),
        }
    }

    fn to_json(&self, local_spki: &[u8]) -> Value {
        let mut v = json!({
            "deviceId": self.id,
            "name": self.name,
            "type": self.dtype,
            "connected": self.connected,
            "paired": self.paired,
            "pendingIn": self.pending_in,
            "pendingOut": self.pending_out,
        });
        if (self.pending_in || self.pending_out) && !self.peer_spki.is_empty() {
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
    trust: TrustStore,
    subscribers: Vec<mpsc::Sender<String>>,
}

struct Daemon {
    identity: Arc<LocalIdentity>,
    state: PathBuf,
    tcp_port: u16,
    inner: Mutex<Inner>,
    clipboard: Option<clipboard::ClipboardHandle>,
    last_clipboard: Mutex<Option<String>>,
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
        match inner.channels.get(device_id) {
            Some(tx) => tx.send(packet).await.is_ok(),
            None => false,
        }
    }

    async fn device_snapshot(&self) -> Vec<Value> {
        let inner = self.inner.lock().await;
        inner
            .devices
            .values()
            .map(|d| d.to_json(&self.identity.spki_der))
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

    async fn handle_packet(&self, device_id: &str, packet: Packet) {
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

    // ---- connection lifecycle ----------------------------------------------

    async fn register_channel(
        self: &Arc<Self>,
        info: DeviceInfo,
        stream: impl tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send + 'static,
    ) {
        let device_id = info.id.clone();
        let (tx, mut rx) = mpsc::channel::<Packet>(32);
        {
            let mut inner = self.inner.lock().await;
            if inner
                .devices
                .get(&device_id)
                .map(|d| d.connected)
                .unwrap_or(false)
            {
                log(&format!("duplicate connection to {}, dropping new one", device_id));
                return;
            }
            let paired = inner.trust.is_trusted(&device_id);
            let mut dev = info;
            dev.connected = true;
            dev.paired = paired;
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
            if let Some(dev) = inner.devices.get_mut(&read_id) {
                dev.connected = false;
                dev.pending_in = false;
                dev.pending_out = false;
                dev.pair_deadline = None;
            }
            inner.channels.remove(&read_id);
            drop(inner);
            log(&format!("disconnected from {}", read_id));
            daemon
                .emit(json!({"event": "disconnected", "deviceId": read_id}))
                .await;
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
    let packet = Packet::identity(&daemon.identity, daemon.tcp_port);
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

async fn connect_to(daemon: Arc<Daemon>, device_id: String, ip: IpAddr, port: u16) {
    let result = async {
        let mut tcp = TcpStream::connect((ip, port))
            .await
            .context("TCP connect")?;
        // We opened the TCP connection: send our identity in plaintext
        // first, then act as the TLS server.
        send_plaintext_identity(&daemon, &mut tcp).await?;
        let (stream, peer_cert) =
            tls::handshake_as_server(tcp, &daemon.identity).await?;
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
    if let Err(e) = result {
        log(&format!("connect to {} failed: {:#}", device_id, e));
    }
    daemon.inner.lock().await.connecting.remove(&device_id);
}

async fn maybe_connect(daemon: &Arc<Daemon>, device_id: &str) {
    let target = {
        let mut inner = daemon.inner.lock().await;
        let trusted = inner.trust.is_trusted(device_id);
        let dev = inner.devices.get(device_id);
        let ready = trusted
            && dev.map(|d| !d.connected).unwrap_or(false)
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
        let mut info = read_plaintext_identity(&mut tcp, remote.ip()).await?;
        let (stream, peer_cert) =
            tls::handshake_as_client(tcp, &daemon.identity, &info.id.clone()).await?;
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
        let packet = Packet::identity(&daemon.identity, daemon.tcp_port);
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
                    && dev
                        .last_seen
                        .map(|t| t.elapsed() < Duration::from_secs(60))
                        .unwrap_or(false)
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
            trust,
            subscribers: Vec::new(),
        }),
        clipboard: clipboard_handle,
        last_clipboard: Mutex::new(None),
    });

    log(&format!(
        "device {} ({}) listening on TCP {}, state in {}",
        identity.device_name,
        identity.device_id,
        tcp_port,
        dir.display()
    ));

    let udp = Arc::new(udp_socket()?);
    tokio::spawn(discovery_task(daemon.clone(), udp.clone()));
    tokio::spawn(announce_task(daemon.clone(), udp));
    tokio::spawn(sweeper_task(daemon.clone()));
    tokio::spawn(control_task(
        daemon.clone(),
        dir.join("control.sock"),
    ));
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
        "monitor" => cli_monitor().await,
        "pair" | "accept" | "reject" | "unpair" => {
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
        other => {
            eprintln!("unknown command: {}", other);
            eprintln!("usage: hyprconnect [run|devices|monitor|pair|accept|reject|unpair|ping] [deviceId]");
            std::process::exit(2);
        }
    }
}
