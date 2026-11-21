//! Local device identity: a stable device id plus a self-signed ECDSA
//! certificate whose common name is the device id (KDE Connect model).
//! Everything here lives in the state directory, never in the repo.

use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

pub struct LocalIdentity {
    pub device_id: String,
    pub device_name: String,
    pub cert_der: Vec<u8>,
    pub cert_pem: String,
    pub key_pem: String,
    pub spki_der: Vec<u8>,
}

fn random_hex(bytes: usize) -> String {
    let mut buf = vec![0u8; bytes];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| {
            use std::io::Read;
            f.read_exact(&mut buf)
        })
        .expect("read /dev/urandom");
    buf.iter().map(|b| format!("{:02x}", b)).collect()
}

fn default_device_name() -> String {
    std::fs::read_to_string("/etc/hostname")
        .map(|s| s.trim().to_string())
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "hyprconnect".to_string())
}

pub fn state_dir() -> PathBuf {
    if let Ok(d) = std::env::var("HYPRCONNECT_STATE_DIR") {
        return PathBuf::from(d);
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home).join(".local/state/hyprconnect")
}

fn spki_of(cert_der: &[u8]) -> Result<Vec<u8>> {
    let (_, parsed) = x509_parser::parse_x509_certificate(cert_der)
        .map_err(|e| anyhow::anyhow!("parse own certificate: {}", e))?;
    Ok(parsed.tbs_certificate.subject_pki.raw.to_vec())
}

pub fn load_or_create(dir: &Path) -> Result<LocalIdentity> {
    std::fs::create_dir_all(dir).context("create state dir")?;
    let id_file = dir.join("device.json");
    let cert_file = dir.join("cert.pem");
    let key_file = dir.join("key.pem");

    if id_file.exists() && cert_file.exists() && key_file.exists() {
        let meta: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&id_file)?)?;
        let device_id = meta["deviceId"].as_str().context("deviceId")?.to_string();
        let device_name = std::env::var("HYPRCONNECT_DEVICE_NAME")
            .ok()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| {
                meta["deviceName"]
                    .as_str()
                    .unwrap_or("hyprconnect")
                    .to_string()
            });
        let cert_pem = std::fs::read_to_string(&cert_file)?;
        let key_pem = std::fs::read_to_string(&key_file)?;
        let cert_der = pem_to_der(&cert_pem)?;
        let spki_der = spki_of(&cert_der)?;
        return Ok(LocalIdentity {
            device_id,
            device_name,
            cert_der,
            cert_pem,
            key_pem,
            spki_der,
        });
    }

    let device_id = random_hex(16); // 32 hex chars, matches the protocol id pattern
    let device_name = std::env::var("HYPRCONNECT_DEVICE_NAME")
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(default_device_name);

    let key_pair = rcgen::KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256)?;
    let mut params = rcgen::CertificateParams::new(vec![device_id.clone()])?;
    params
        .distinguished_name
        .push(rcgen::DnType::CommonName, device_id.clone());
    let cert = params.self_signed(&key_pair)?;
    let cert_pem = cert.pem();
    let key_pem = key_pair.serialize_pem();
    let cert_der = cert.der().to_vec();
    let spki_der = spki_of(&cert_der)?;

    std::fs::write(
        &id_file,
        serde_json::to_string_pretty(&serde_json::json!({
            "deviceId": device_id,
            "deviceName": device_name,
        }))?,
    )?;
    write_secret(&cert_file, &cert_pem)?;
    write_secret(&key_file, &key_pem)?;

    Ok(LocalIdentity {
        device_id,
        device_name,
        cert_der,
        cert_pem,
        key_pem,
        spki_der,
    })
}

fn write_secret(path: &Path, content: &str) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::write(path, content)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(())
}

pub fn pem_to_der(pem: &str) -> Result<Vec<u8>> {
    let mut reader = std::io::BufReader::new(pem.as_bytes());
    let item = rustls_pemfile::read_one(&mut reader)?
        .context("no PEM item")?;
    match item {
        rustls_pemfile::Item::X509Certificate(der) => Ok(der.to_vec()),
        _ => anyhow::bail!("PEM item is not a certificate"),
    }
}

/// Extract (common name, SPKI DER) from a peer certificate DER.
pub fn cert_info(cert_der: &[u8]) -> Result<(String, Vec<u8>)> {
    let (_, parsed) = x509_parser::parse_x509_certificate(cert_der)
        .map_err(|e| anyhow::anyhow!("parse peer certificate: {}", e))?;
    let cn = parsed
        .tbs_certificate
        .subject
        .iter_common_name()
        .next()
        .and_then(|cn| cn.as_str().ok())
        .context("peer certificate has no common name")?
        .to_string();
    Ok((cn, parsed.tbs_certificate.subject_pki.raw.to_vec()))
}

/// KDE Connect verification key: SHA-256 over both devices' public keys
/// (SPKI DER), larger byte string first; first 8 hex chars, upper case.
/// Matches what the KDE Connect Android app and GSConnect display.
pub fn verification_key(local_spki: &[u8], peer_spki: &[u8]) -> String {
    use sha2::Digest;
    let (a, b) = if local_spki < peer_spki {
        (peer_spki, local_spki)
    } else {
        (local_spki, peer_spki)
    };
    let mut hasher = sha2::Sha256::new();
    hasher.update(a);
    hasher.update(b);
    let digest = hasher.finalize();
    let hex: String = digest.iter().map(|b| format!("{:02x}", b)).collect();
    hex[..8].to_uppercase()
}

pub fn valid_device_id(id: &str) -> bool {
    (32..=38).contains(&id.len())
        && id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}
