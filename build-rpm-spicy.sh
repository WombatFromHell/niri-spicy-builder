#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/build-lib.sh"

# ponytail: shallow fetch covers branch tip + pinned commit if on tip; falls back to full fetch for deep history
NIRI_REF="${NIRI_REF:-641335ff77d31f0d410d589f8a35654fc5fe31a0}"

# Ensure cache and distribution output directories exist
rm -rf "$RPM_OUTPUT_DIR"
ensure_dirs

ensure_image

echo "==> Syncing niri and smithay source trees..."
sync_repo "https://github.com/losnoco/niri" "${NIRI_REF}" "${SRC_DIR}/niri"
sync_repo "https://github.com/losnoco/smithay" "spicy-master" "${SRC_DIR}/smithay"

echo "==> Compiling and packaging RPM via Podman..."
# Volume Mount Layout:
# - ${SRC_DIR}: Source tree mounted to /workspace
# - ${CARGO_CACHE_DIR}: Hermetic Cargo dependencies mounted to /workspace/.cargo
# - ${TARGET_CACHE_DIR}: Incremental compilation cache mounted to /workspace/niri/target
# - ${RPM_OUTPUT_DIR}: Artifact distribution directory mounted to /output
podman run --rm \
  --userns=keep-id \
  -e NIRI_REF="${NIRI_REF}" \
  -v "${SRC_DIR}:/workspace:z" \
  -v "${CARGO_CACHE_DIR}:/workspace/.cargo:z" \
  -v "${TARGET_CACHE_DIR}:/workspace/niri/target:z" \
  -v "${RPM_OUTPUT_DIR}:/output:Z" \
  "${IMAGE_NAME}"

echo "==> Success! RPM file placed in: ${RPM_OUTPUT_DIR}"
