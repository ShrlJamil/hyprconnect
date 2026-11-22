//! Wire packets: newline-delimited JSON objects, KDE Connect style.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Packet {
    pub id: i64,
    #[serde(rename = "type")]
    pub ptype: String,
    #[serde(default)]
    pub body: Value,
    /// Byte size of the out-of-band payload (file transfers).
    #[serde(rename = "payloadSize", skip_serializing_if = "Option::is_none")]
    pub payload_size: Option<i64>,
    /// Where the payload can be fetched: { "port": N }.
    #[serde(
        rename = "payloadTransferInfo",
        skip_serializing_if = "Option::is_none"
    )]
    pub payload_transfer_info: Option<Value>,
}

/// Capabilities this implementation speaks, advertised in the
/// identity packet. Peers gate their plugins on these lists, so a
/// feature only exists once it is named here.
pub const INCOMING_CAPABILITIES: &[&str] = &[
    "kdeconnect.ping",
    "kdeconnect.clipboard",
    "kdeconnect.clipboard.connect",
    "kdeconnect.share.request",
    "kdeconnect.notification",
    "kdeconnect.mpris",
    "kdeconnect.mpris.request",
    "kdeconnect.systemvolume.request",
    "kdeconnect.sftp",
    "kdeconnect.presenter",
    "kdeconnect.mousepad.request",
    "kdeconnect.runcommand.request",
    "kdeconnect.battery",
];
pub const OUTGOING_CAPABILITIES: &[&str] = &[
    "kdeconnect.ping",
    "kdeconnect.clipboard",
    "kdeconnect.clipboard.connect",
    "kdeconnect.share.request",
    "kdeconnect.notification.request",
    "kdeconnect.notification.reply",
    "kdeconnect.notification.action",
    "kdeconnect.mpris",
    "kdeconnect.mpris.request",
    "kdeconnect.systemvolume",
    "kdeconnect.sftp.request",
    "kdeconnect.battery.request",
    "kdeconnect.findmyphone.request",
    "kdeconnect.runcommand",
    "kdeconnect.runcommand.output",
    "kdeconnect.mousepad.request",
    "kdeconnect.presenter",
];

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

impl Packet {
    pub fn new(ptype: &str, body: Value) -> Self {
        Packet {
            id: now_ms(),
            ptype: ptype.to_string(),
            body,
            payload_size: None,
            payload_transfer_info: None,
        }
    }

    pub fn identity(
        identity: &crate::identity::LocalIdentity,
        tcp_port: u16,
        disabled_plugins: &HashSet<String>,
    ) -> Self {
        let (incoming, outgoing) = capabilities(disabled_plugins);
        Packet::new(
            "kdeconnect.identity",
            json!({
                "deviceId": identity.device_id,
                "deviceName": identity.device_name,
                "deviceType": "desktop",
                "incomingCapabilities": incoming,
                "outgoingCapabilities": outgoing,
                "protocolVersion": 7,
                "tcpPort": tcp_port,
            }),
        )
    }

    pub fn pair(pair: bool) -> Self {
        Packet::new("kdeconnect.pair", json!({ "pair": pair }))
    }

    pub fn ping(message: Option<&str>) -> Self {
        let body = match message {
            Some(m) => json!({ "message": m }),
            None => json!({}),
        };
        Packet::new("kdeconnect.ping", body)
    }

    pub fn to_line(&self) -> String {
        let mut s = serde_json::to_string(self).unwrap_or_default();
        s.push('\n');
        s
    }
}

/// User-facing plugins, in the order the app's plugin page shows.
pub const PLUGIN_NAMES: &[&str] = &[
    "clipboard",
    "share",
    "notification",
    "mpris",
    "systemvolume",
    "sftp",
    "presenter",
    "remoteinput",
    "battery",
    "findmyphone",
    "runcommand",
];

/// Which plugin a packet type belongs to (None = core traffic that
/// is never gated: identity, pairing, ping).
pub fn plugin_for_packet(ptype: &str) -> Option<&'static str> {
    Some(match ptype {
        "kdeconnect.clipboard" | "kdeconnect.clipboard.connect" => "clipboard",
        "kdeconnect.share.request" => "share",
        "kdeconnect.notification"
        | "kdeconnect.notification.request"
        | "kdeconnect.notification.action"
        | "kdeconnect.notification.reply" => "notification",
        "kdeconnect.mpris" | "kdeconnect.mpris.request" => "mpris",
        "kdeconnect.systemvolume" | "kdeconnect.systemvolume.request" => {
            "systemvolume"
        }
        "kdeconnect.sftp" | "kdeconnect.sftp.request" => "sftp",
        "kdeconnect.presenter" => "presenter",
        "kdeconnect.mousepad.request" => "remoteinput",
        "kdeconnect.battery" | "kdeconnect.battery.request" => "battery",
        "kdeconnect.findmyphone.request" => "findmyphone",
        _ => return None,
    })
}

/// The capability lists with disabled plugins filtered out.
pub fn capabilities(
    disabled_plugins: &HashSet<String>,
) -> (Vec<&'static str>, Vec<&'static str>) {
    let filt = |list: &[&'static str]| -> Vec<&'static str> {
        list.iter()
            .copied()
            .filter(|t| {
                plugin_for_packet(t)
                    .map_or(true, |pl| !disabled_plugins.contains(pl))
            })
            .collect()
    };
    (
        filt(INCOMING_CAPABILITIES),
        filt(OUTGOING_CAPABILITIES),
    )
}
