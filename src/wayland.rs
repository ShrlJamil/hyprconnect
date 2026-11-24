//! Shared Wayland connection helper for the daemon's desktop-side
//! modules (presenter dot, remote-input pointer, clipboard).
//!
//! The daemon is a systemd user service and can easily win the race
//! against the compositor at login: it starts before Hyprland has
//! created its socket, and its process environment never gains the
//! WAYLAND_DISPLAY value the graphical session later exports. A
//! one-shot Connection::connect_to_env() at startup therefore used
//! to disable all three modules until the daemon was restarted.
//!
//! connect() instead waits for a compositor: it tries the process
//! environment first, then the conventional numeric sockets in the
//! runtime directory (wayland-0, wayland-1, ...), retrying once a
//! second. Only the calling module's thread blocks; the daemon's
//! network side keeps running.

use std::env;
use std::fs;
use std::os::unix::fs::FileTypeExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;

use wayland_client::Connection;

pub fn connect(module: &str, log: &dyn Fn(&str)) -> Connection {
    let mut announced_wait = false;
    loop {
        if let Ok(conn) = Connection::connect_to_env() {
            return conn;
        }
        for path in candidate_sockets() {
            if let Ok(stream) = UnixStream::connect(&path) {
                if let Ok(conn) = Connection::from_socket(stream) {
                    log(&format!(
                        "{}: connected to Wayland via {}",
                        module,
                        path.display()
                    ));
                    return conn;
                }
            }
        }
        if !announced_wait {
            log(&format!("{}: waiting for Wayland compositor", module));
            announced_wait = true;
        }
        thread::sleep(Duration::from_secs(1));
    }
}

fn runtime_dir() -> Option<PathBuf> {
    if let Some(value) = env::var_os("XDG_RUNTIME_DIR") {
        let path = PathBuf::from(value);
        if path.is_absolute() {
            return Some(path);
        }
    }
    let uid = unsafe { libc::getuid() };
    Some(PathBuf::from(format!("/run/user/{}", uid)))
}

fn candidate_sockets() -> Vec<PathBuf> {
    let Some(dir) = runtime_dir() else {
        return Vec::new();
    };
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut paths: Vec<PathBuf> = entries
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|path| is_wayland_socket(path))
        .collect();
    paths.sort();
    paths
}

fn is_wayland_socket(path: &Path) -> bool {
    let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
        return false;
    };
    is_wayland_socket_name(name)
        && path
            .metadata()
            .map(|meta| meta.file_type().is_socket())
            .unwrap_or(false)
}

fn is_wayland_socket_name(name: &str) -> bool {
    let Some(suffix) = name.strip_prefix("wayland-") else {
        return false;
    };
    !suffix.is_empty() && suffix.bytes().all(|byte| byte.is_ascii_digit())
}

#[cfg(test)]
mod tests {
    use super::is_wayland_socket_name;

    #[test]
    fn accepts_numeric_compositor_sockets() {
        assert!(is_wayland_socket_name("wayland-0"));
        assert!(is_wayland_socket_name("wayland-1"));
        assert!(is_wayland_socket_name("wayland-12"));
    }

    #[test]
    fn rejects_lock_files_and_sidecar_sockets() {
        assert!(!is_wayland_socket_name("wayland-1.lock"));
        assert!(!is_wayland_socket_name("wayland-1-awww-daemon.sock"));
        assert!(!is_wayland_socket_name("wayland-"));
        assert!(!is_wayland_socket_name("wayland-foo"));
    }
}
