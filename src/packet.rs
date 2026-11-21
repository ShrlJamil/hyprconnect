//! Wire packets: newline-delimited JSON objects, KDE Connect style.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Packet {
    pub id: i64,
    #[serde(rename = "type")]
    pub ptype: String,
    #[serde(default)]
    pub body: Value,
}

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
        }
    }

    pub fn identity(identity: &crate::identity::LocalIdentity, tcp_port: u16) -> Self {
        Packet::new(
            "kdeconnect.identity",
            json!({
                "deviceId": identity.device_id,
                "deviceName": identity.device_name,
                "deviceType": "desktop",
                "incomingCapabilities": ["kdeconnect.ping"],
                "outgoingCapabilities": ["kdeconnect.ping"],
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
