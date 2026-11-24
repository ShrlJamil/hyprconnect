//! Self-update from GitHub Releases, shared by the daemon CLI
//! (`hyprconnect update`) and the desktop app. A release carries
//! the two desktop binaries next to the Android APK; installing
//! one replaces both binaries beside the running executable
//! after their SHA-256 sums verify, and the caller then restarts
//! the daemon service (and itself, for the app).
//!
//! While the repository is private the release API answers 404
//! to anonymous callers and checks simply fail; setting
//! HC_UPDATE_TOKEN to a GitHub token makes checks work against
//! the private repository too.

use std::collections::HashMap;
use std::io::Read;
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use sha2::{Digest, Sha256};

pub const RELEASE_REPO: &str = "ShrlJamil/hyprconnect";
const DAEMON_ASSET: &str = "hyprconnect-linux-x86_64";
const APP_ASSET: &str = "hyprconnect-app-linux-x86_64";
const SUMS_ASSET: &str = "SHA256SUMS";

/// Release asset name paired with the installed file name.
const BINARIES: [(&str, &str); 2] = [
    (DAEMON_ASSET, "hyprconnect"),
    (APP_ASSET, "hyprconnect-app"),
];

/// The release tag this build belongs to, e.g. "v1.0.0+4".
/// Release builds set HC_RELEASE_TAG at compile time; plain
/// cargo builds fall back to the crate version with build 0.
pub fn current_tag() -> String {
    match option_env!("HC_RELEASE_TAG") {
        Some(tag) if !tag.is_empty() => tag.to_string(),
        _ => format!("v{}+0", env!("CARGO_PKG_VERSION")),
    }
}

#[derive(Clone)]
pub struct ReleaseInfo {
    pub tag: String,
    pub notes: String,
    /// Asset name -> (download URL, size in bytes).
    pub assets: HashMap<String, (String, u64)>,
}

impl ReleaseInfo {
    /// The tag without its leading "v": "1.0.0+4".
    pub fn version(&self) -> &str {
        self.tag.strip_prefix('v').unwrap_or(&self.tag)
    }

    /// Whether this release can update a desktop install.
    pub fn has_desktop_assets(&self) -> bool {
        self.assets.contains_key(SUMS_ASSET)
            && BINARIES
                .iter()
                .all(|(asset, _)| self.assets.contains_key(*asset))
    }
}

/// Parse "v1.0.0+4" into ([1, 0, 0], 4).
fn parse_version(raw: &str) -> Option<(Vec<u64>, u64)> {
    let trimmed = raw.trim();
    let s = trimmed.strip_prefix('v').unwrap_or(trimmed);
    let (core, build) = match s.split_once('+') {
        Some((core, build)) => (core, build.parse().ok()?),
        None => (s, 0),
    };
    let mut parts: Vec<u64> = Vec::new();
    for piece in core.split('.') {
        parts.push(piece.parse().ok()?);
    }
    while parts.len() < 3 {
        parts.push(0);
    }
    Some((parts, build))
}

/// Whether [latest] names a strictly newer release than
/// [current]; unparsable input is never newer.
pub fn is_newer(latest: &str, current: &str) -> bool {
    match (parse_version(latest), parse_version(current)) {
        (Some(l), Some(c)) => (l.0, l.1) > (c.0, c.1),
        _ => false,
    }
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(10))
        .timeout_read(Duration::from_secs(180))
        .build()
}

fn get(url: &str) -> Result<ureq::Response> {
    let mut request = agent()
        .get(url)
        .set("User-Agent", "HyprConnect-Desktop")
        .set("Accept", "application/vnd.github+json");
    if let Ok(token) = std::env::var("HC_UPDATE_TOKEN") {
        if !token.is_empty() {
            request = request.set("Authorization", &format!("Bearer {token}"));
        }
    }
    request
        .call()
        .map_err(|e| anyhow::anyhow!("update request failed: {e}"))
}

fn download_bytes(url: &str) -> Result<Vec<u8>> {
    let response = get(url)?;
    let mut buf = Vec::new();
    response.into_reader().read_to_end(&mut buf)?;
    Ok(buf)
}

/// The latest published release. Errors when the check cannot
/// complete (offline, or the release is not visible to us).
pub fn fetch_latest() -> Result<ReleaseInfo> {
    let response = get(&format!(
        "https://api.github.com/repos/{RELEASE_REPO}/releases/latest"
    ))?;
    let mut body = String::new();
    response.into_reader().read_to_string(&mut body)?;
    let json: serde_json::Value = serde_json::from_str(&body)?;
    let tag = json["tag_name"]
        .as_str()
        .context("the release has no tag")?
        .to_string();
    let notes = json["body"].as_str().unwrap_or("").to_string();
    let mut assets = HashMap::new();
    if let Some(list) = json["assets"].as_array() {
        for asset in list {
            let (Some(name), Some(url)) = (
                asset["name"].as_str(),
                asset["browser_download_url"].as_str(),
            ) else {
                continue;
            };
            let size = asset["size"].as_u64().unwrap_or(0);
            assets.insert(name.to_string(), (url.to_string(), size));
        }
    }
    Ok(ReleaseInfo { tag, notes, assets })
}

fn parse_sums(text: &str) -> HashMap<String, String> {
    let mut map = HashMap::new();
    for line in text.lines() {
        let mut parts = line.split_whitespace();
        if let (Some(hash), Some(name)) = (parts.next(), parts.next()) {
            map.insert(
                name.trim_start_matches('*').to_string(),
                hash.to_lowercase(),
            );
        }
    }
    map
}

/// Download both desktop binaries of [info], verify their
/// SHA-256 sums, and atomically replace the binaries beside the
/// running executable. Returns the install directory.
pub fn install_release(info: &ReleaseInfo) -> Result<PathBuf> {
    let exe = std::env::current_exe().context("cannot locate the running executable")?;
    let dir = exe
        .parent()
        .context("the executable has no parent directory")?
        .to_path_buf();
    let (sums_url, _) = info
        .assets
        .get(SUMS_ASSET)
        .context("the release carries no SHA256SUMS")?;
    let sums = parse_sums(&String::from_utf8_lossy(&download_bytes(sums_url)?));
    for (asset, target) in BINARIES {
        let (url, _) = info
            .assets
            .get(asset)
            .with_context(|| format!("the release carries no {asset}"))?;
        let expected = sums
            .get(asset)
            .with_context(|| format!("SHA256SUMS has no entry for {asset}"))?;
        let bytes = download_bytes(url)?;
        let actual = format!("{:x}", Sha256::digest(&bytes));
        if actual != *expected {
            bail!("checksum mismatch for {asset}");
        }
        let tmp = dir.join(format!(".{target}.new"));
        std::fs::write(&tmp, &bytes)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755))?;
        }
        std::fs::rename(&tmp, dir.join(target))?;
    }
    Ok(dir)
}

/// Restart the daemon service so it runs the freshly installed
/// binary.
pub fn restart_daemon() -> Result<()> {
    let status = std::process::Command::new("systemctl")
        .args(["--user", "restart", "hyprconnect.service"])
        .status()
        .context("failed to run systemctl")?;
    if !status.success() {
        bail!("systemctl restart hyprconnect.service failed");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn newer_tags_win() {
        assert!(is_newer("v1.0.0+4", "v1.0.0+3"));
        assert!(is_newer("v1.0.1+1", "v1.0.0+9"));
        assert!(is_newer("v2.0.0+1", "v1.9.9+9"));
        assert!(!is_newer("v1.0.0+3", "v1.0.0+4"));
        assert!(!is_newer("v1.0.0+4", "v1.0.0+4"));
        assert!(!is_newer("nonsense", "v1.0.0+1"));
    }

    #[test]
    fn sums_parse() {
        let sums = parse_sums("abc123  hyprconnect-linux-x86_64\nDEF456 *app-release.apk\n");
        assert_eq!(sums["hyprconnect-linux-x86_64"], "abc123");
        assert_eq!(sums["app-release.apk"], "def456");
    }
}
