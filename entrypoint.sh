#!/usr/bin/env bash
set -euo pipefail

cd /workspace/niri

# Point CARGO_HOME to the mounted volume cache directory
export CARGO_HOME="/workspace/.cargo"

# Apply remap flags matching the PKGBUILD strategy
export CARGO_ENCODED_RUSTFLAGS="--remap-path-prefix=/workspace=/"

echo "--> Using hermetic cargo cache at: ${CARGO_HOME}"
echo "--> Fetching dependencies..."
cargo fetch --locked

# ponytail: derive short hash from actual checkout (covers branch→hash), fallback to NIRI_REF when .git absent
SHORT="$(git rev-parse --short=7 HEAD 2>/dev/null || printf '%s' "${NIRI_REF:-unknown}" | grep -Eo '[0-9a-f]{7,40}' | head -c7)"
SHORT="${SHORT:-unknown}"

echo "--> Restoring Cargo.toml from upstream..."
git checkout Cargo.toml

echo "--> Building release binary..."
cargo build --release --locked
strip --strip-all "target/release/niri"

echo "--> Injecting RPM packaging metadata into Cargo.toml..."
# Safely strip any existing generate-rpm section
sed -i '/\[package.metadata.generate-rpm\]/,$d' Cargo.toml

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
EOF

echo "--> Generating RPM package..."
rm -rf target/generate-rpm
cargo-generate-rpm

echo "--> Copying completed RPM to output directory..."
cp -v target/generate-rpm/*.rpm /output/
