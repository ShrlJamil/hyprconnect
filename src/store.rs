//! Trusted devices: devices the user paired with. Their certificates are
//! stored so reconnections are authenticated and automatic. Lives in the
//! state directory, never in the repo.

use anyhow::Result;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrustedDevice {
    pub device_id: String,
    pub name: String,
    pub device_type: String,
    /// Peer certificate, hex encoded DER.
    pub cert_hex: String,
}

pub struct TrustStore {
    path: PathBuf,
    pub devices: HashMap<String, TrustedDevice>,
}

pub fn hex_encode(data: &[u8]) -> String {
    data.iter().map(|b| format!("{:02x}", b)).collect()
}

pub fn hex_decode(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok())
        .collect()
}

impl TrustStore {
    pub fn load(state_dir: &std::path::Path) -> Self {
        let path = state_dir.join("trusted.json");
        let devices = std::fs::read_to_string(&path)
            .ok()
            .and_then(|s| serde_json::from_str::<Vec<TrustedDevice>>(&s).ok())
            .map(|list| {
                list.into_iter()
                    .map(|d| (d.device_id.clone(), d))
                    .collect()
            })
            .unwrap_or_default();
        TrustStore { path, devices }
    }

    pub fn is_trusted(&self, device_id: &str) -> bool {
        self.devices.contains_key(device_id)
    }

    pub fn cert_matches(&self, device_id: &str, cert_der: &[u8]) -> bool {
        match self.devices.get(device_id) {
            Some(d) => hex_decode(&d.cert_hex).map(|c| c == cert_der).unwrap_or(false),
            None => false,
        }
    }

    pub fn add(&mut self, device: TrustedDevice) -> Result<()> {
        self.devices.insert(device.device_id.clone(), device);
        self.save()
    }

    pub fn remove(&mut self, device_id: &str) -> Result<()> {
        self.devices.remove(device_id);
        self.save()
    }

    fn save(&self) -> Result<()> {
        let list: Vec<&TrustedDevice> = self.devices.values().collect();
        let tmp = self.path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_string_pretty(&list)?)?;
        std::fs::rename(&tmp, &self.path)?;
        Ok(())
    }
}
