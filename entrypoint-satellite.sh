#!/usr/bin/env bash
set -euo pipefail

cd /workspace

# Point CARGO_HOME to the mounted volume cache directory
export CARGO_HOME="/workspace/.cargo"

# Apply remap flags matching the PKGBUILD strategy
export CARGO_ENCODED_RUSTFLAGS="--remap-path-prefix=/workspace=/"

echo "--> Using hermetic cargo cache at: ${CARGO_HOME}"
echo "--> Fetching dependencies..."
cargo fetch --locked

# ponytail: derive short hash from actual checkout (covers branch→hash), fallback to SATELLITE_REF when .git absent
SHORT="$(git rev-parse --short=7 HEAD 2>/dev/null || printf '%s' "${SATELLITE_REF:-unknown}" | grep -Eo '[0-9a-f]{7,40}' | head -c7)"
SHORT="${SHORT:-unknown}"

# ponytail: base version read from Cargo.toml [package] (first `version =` after [package])
BASEVER="$(awk '/^\[package\]/{f=1;next} f&&/^version = "/{gsub(/version = "|"/,"");print;exit}' Cargo.toml)"
BASEVER="${BASEVER:-unknown}"

echo "--> Building release binary (features: systemd)..."
cargo build --release --locked -F systemd
strip --strip-all "target/release/xwayland-satellite"

# Stage assets under the names/paths the RPM expects
# ponytail: man source is .man; RPM needs .1. Service ExecStart is /usr/local/bin; we install to /usr/bin.
cp -v xwayland-satellite.man target/release/xwayland-satellite.1
sed -e 's|/usr/local/bin|/usr/bin|g' resources/xwayland-satellite.service >target/release/xwayland-satellite.service

echo "--> Injecting RPM packaging metadata into Cargo.toml..."
# Safely strip any existing generate-rpm section
sed -i '/\[package.metadata.generate-rpm\]/,$d' Cargo.toml

# Write a clean, complete RPM metadata table
cat <<EOF >>Cargo.toml

[package.metadata.generate-rpm]
name = "xwayland-satellite"
version = "${BASEVER}.git+${SHORT}"
release = "1.fc44"
summary = "Rootless Xwayland for Wayland compositors (spicy build)"
license = "MPL-2.0"
assets = [
  { source = "target/release/xwayland-satellite", dest = "/usr/bin/", mode = "755" },
  { source = "target/release/xwayland-satellite.1", dest = "/usr/share/man/man1/", mode = "644" },
  { source = "target/release/xwayland-satellite.service", dest = "/usr/lib/systemd/user/", mode = "644" }
]
EOF

echo "--> Generating RPM package..."
rm -rf target/generate-rpm
cargo-generate-rpm

echo "--> Copying completed RPM to output directory..."
cp -v target/generate-rpm/*.rpm /output/
