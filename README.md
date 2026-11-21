# HyprConnect

Compact KDE Connect-compatible companion for Hyprland, written in Rust.

HyprConnect implements a subset of the KDE Connect protocol in a single
lightweight daemon, paired with a GTK 4 desktop app. It pairs with the
official KDE Connect Android app and deliberately leaves out everything
that is not needed day to day, without pulling in any KDE or Qt stack.

## Status

Early development. The feature set and architecture are settled; the
implementation is being built in phases, starting with discovery, TLS
transport, and pairing.

## Planned features

- Presentation remote, carried over from HyprPresenter
- File sharing, send and receive
- Clipboard sharing between phone and desktop
- Notification sharing from phone to desktop
- MPRIS sharing, control desktop players from the phone and the other way round
- SFTP mount of the phone storage for any file manager

## Not planned

SMS, telephony, remote command execution, and full remote input are out
of scope by design.

## Tech

- Rust daemon: tokio, rustls, zbus (D-Bus), Wayland clipboard protocols
- GTK 4 desktop app
- KDE Connect protocol subset: UDP discovery, TLS with per-device
  certificates, JSON packets

## License

To be decided before the first public release.
