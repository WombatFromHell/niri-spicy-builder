# container-lib.sh — shared scaffolding for the builder entrypoints (source, don't execute)

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
