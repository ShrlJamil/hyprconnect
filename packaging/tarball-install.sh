#!/bin/sh
# HyprConnect release installer: copies the prebuilt `hyprconnect`
# daemon and `hyprconnect-app` desktop app from this tarball into
# ~/.local/bin, installs the systemd user unit, the desktop entry
# and the icon, then enables and restarts the daemon. No build,
# no dependencies, no root.
#
#   ./install.sh
#
# Re-running is safe: files are simply replaced and the daemon is
# restarted, so this also works as the upgrade path.
set -eu

cd "$(dirname "$0")"

BIN_DIR="$HOME/.local/bin"
UNIT_DIR="$HOME/.config/systemd/user"
APP_DIR="$HOME/.local/share/applications"
ICON_DIR="$HOME/.local/share/icons/hicolor/scalable/apps"

mkdir -p "$BIN_DIR" "$UNIT_DIR" "$APP_DIR" "$ICON_DIR"

# `install` replaces the destination instead of writing through it,
# so replacing the binaries works even while the daemon is running.
install -m 755 ./hyprconnect "$BIN_DIR/hyprconnect"
install -m 755 ./hyprconnect-app "$BIN_DIR/hyprconnect-app"
echo "Installed: $BIN_DIR/hyprconnect"
echo "Installed: $BIN_DIR/hyprconnect-app"

install -m 644 ./hyprconnect.service "$UNIT_DIR/hyprconnect.service"
install -m 644 ./io.github.ShrlJamil.hyprconnect.desktop "$APP_DIR/io.github.ShrlJamil.hyprconnect.desktop"
install -m 644 ./io.github.ShrlJamil.hyprconnect.svg "$ICON_DIR/io.github.ShrlJamil.hyprconnect.svg"
echo "Installed: systemd user unit, desktop entry, icon"

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload
  systemctl --user enable hyprconnect.service
  systemctl --user restart hyprconnect.service
  echo "Daemon enabled and running: systemctl --user status hyprconnect"
else
  echo "Note: systemctl not found. Start the daemon manually with:"
  echo "  hyprconnect run"
fi

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo "Note: $BIN_DIR is not on your PATH yet. Add it to your shell profile:"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    ;;
esac

echo "Done. Pair a phone with: hyprconnect devices"
