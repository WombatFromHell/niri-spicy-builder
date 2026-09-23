#!/usr/bin/env bash
set -euo pipefail

source /usr/local/bin/container-lib.sh

cd /workspace/niri

setup

echo "--> Restoring Cargo.toml from upstream..."
git checkout Cargo.toml

echo "--> Building release binary..."
cargo build --release --locked
strip --strip-all "target/release/niri"

echo "--> Injecting RPM packaging metadata into Cargo.toml..."
strip_rpm_metadata

# Write a clean, complete RPM metadata table
cat <<EOF >>Cargo.toml

[package.metadata.generate-rpm]
name = "niri"
version = "26.04.git+${SHORT}"
release = "1.fc44"
summary = "Scrollable-tiling Wayland compositor (spicy build)"
license = "GPL-3.0-or-later"
assets = [
  { source = "target/release/niri", dest = "/usr/bin/", mode = "755" },
  { source = "resources/niri-session", dest = "/usr/bin/", mode = "755" },
  { source = "resources/niri.desktop", dest = "/usr/share/wayland-sessions/", mode = "644" },
  { source = "resources/niri-portals.conf", dest = "/usr/share/xdg-desktop-portal/", mode = "644" },
  { source = "resources/niri.service", dest = "/usr/lib/systemd/user/", mode = "644" },
  { source = "resources/niri-shutdown.target", dest = "/usr/lib/systemd/user/", mode = "644" },
  { source = "resources/default-config.kdl", dest = "/usr/share/doc/niri/", mode = "644" }
]
[package.metadata.generate-rpm.recommends]
alacritty = "*"
fuzzel = "*"
xwayland-satellite = "*"
EOF

package_rpm
