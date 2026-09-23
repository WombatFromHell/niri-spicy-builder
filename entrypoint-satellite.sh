#!/usr/bin/env bash
set -euo pipefail

source /usr/local/bin/container-lib.sh

cd /workspace

setup

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
strip_rpm_metadata

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

package_rpm
