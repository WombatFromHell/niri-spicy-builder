#!/usr/bin/env bash
# ponytail: source-only lib, shebang exists for shellcheck
# container-lib.sh — shared scaffolding for the builder entrypoints, the host's
# --name-only prediction, and the release workflow's verify step (source, don't execute)

# ponytail: one name/version template for packaging *and* prediction — drift here
# would let a stale predicted name skip a build whose real name differs
NIRI_VERSION_BASE="26.04"
FEDORA_RELEASE="1.fc44"
RPM_ARCH="${RPM_ARCH:-$(uname -m)}"

# ponytail: cargo-generate-rpm names files {name}-{version}-{release}.{arch}.rpm
niri_rpm_name() {
  echo "niri-${NIRI_VERSION_BASE}.git+$1-${FEDORA_RELEASE}.${RPM_ARCH}.rpm"
}

satellite_rpm_name() {
  echo "xwayland-satellite-$1.git+$2-${FEDORA_RELEASE}.${RPM_ARCH}.rpm"
}

# ponytail: base version read from Cargo.toml [package] (first version = after [package])
cargo_basever() {
  awk '/^\[package\]/{f=1;next} f&&/^version = "/{gsub(/version = "|"/,"");print;exit}' "$1/Cargo.toml"
}

setup() {
  # Point CARGO_HOME to the mounted volume cache directory
  export CARGO_HOME="/workspace/.cargo"

  # Apply remap flags matching the PKGBUILD strategy
  export CARGO_ENCODED_RUSTFLAGS="--remap-path-prefix=/workspace=/"

  echo "--> Using hermetic cargo cache at: ${CARGO_HOME}"
  echo "--> Fetching dependencies..."
  cargo fetch --locked

  # ponytail: host derives GIT_SHORT from the synced checkout; fallback to the checkout here if unset
  SHORT="${GIT_SHORT:-$(git rev-parse --short=7 HEAD 2>/dev/null || true)}"
  SHORT="${SHORT:-unknown}"
}

strip_rpm_metadata() {
  # Safely strip any existing generate-rpm section
  sed -i '/\[package.metadata.generate-rpm\]/,$d' Cargo.toml
}

package_rpm() {
  echo "--> Generating RPM package..."
  rm -rf target/generate-rpm
  cargo-generate-rpm

  echo "--> Copying completed RPM to output directory..."
  cp -v target/generate-rpm/*.rpm /output/
}

# verify_rpm_names <predicted-names-file> [dist-dir]
# ponytail: the release workflow sources this before tagging — only names predicted
# pre-build may ship, so a stale or drifted RPM can't sneak into a release
verify_rpm_names() {
  local list="$1" dir="${2:-dist}" f name bad=0
  [[ -f "$list" ]] || { echo "missing predicted-names file: $list" >&2; return 1; }
  for f in "$dir"/*.rpm; do
    [[ -e "$f" ]] || { echo "no RPMs in ${dir}/" >&2; return 1; }
    name="${f##*/}"
    if grep -Fxq "$name" "$list"; then
      echo "--> verified ${name}"
    else
      echo "unexpected RPM (not in ${list}): ${name}" >&2
      bad=1
    fi
  done
  return "$bad"
}
