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

echo "--> Building release binary..."
cargo build --release --locked

echo "--> Injecting RPM packaging metadata into Cargo.toml..."
# Remove any existing [package.metadata.generate-rpm] section if present
sed -i '/\[package.metadata.generate-rpm\]/,$d' Cargo.toml

# Append the full asset manifest required for wayland desktop integration
cat <<'EOF' >>Cargo.toml

[package.metadata.generate-rpm]
assets = [
  { source = "target/release/niri", dest = "/usr/bin/niri", mode = "755" },
  { source = "resources/niri-session", dest = "/usr/bin/niri-session", mode = "755" },
  { source = "resources/niri.desktop", dest = "/usr/share/wayland-sessions/niri.desktop", mode = "644" },
  { source = "resources/niri-portals.conf", dest = "/usr/share/xdg-desktop-portal/niri-portals.conf", mode = "644" },
  { source = "resources/niri.service", dest = "/usr/lib/systemd/user/niri.service", mode = "644" },
  { source = "resources/niri-shutdown.target", dest = "/usr/lib/systemd/user/niri-shutdown.target", mode = "644" },
  { source = "resources/default-config.kdl", dest = "/usr/share/doc/niri/default-config.kdl", mode = "644" }
]
EOF

echo "--> Generating RPM package..."
cargo-generate-rpm

echo "--> Copying completed RPM to output directory..."
cp -v target/generate-rpm/*.rpm /output/
