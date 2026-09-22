#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/build-lib.sh"

# ponytail: shallow fetch covers branch tip + pinned commit if on tip; falls back to full fetch for deep history
NIRI_REF="${NIRI_REF:-15c93f62b4a2963b0b3fe8f1732c3ea73f9396f5}"
SMITHAY_REF="${SMITHAY_REF:-ce13557df3f29525f195816c112bbfebd4e5a822}"

# Ensure cache and distribution output directories exist
rm -rf "$RPM_OUTPUT_DIR"
ensure_dirs

ensure_image

echo "==> Syncing niri and smithay source trees..."
sync_repo "https://github.com/losnoco/niri" "${NIRI_REF}" "${SRC_DIR}/niri"
sync_repo "https://github.com/losnoco/smithay" "${SMITHAY_REF}" "${SRC_DIR}/smithay"

# ponytail: hash comes from the synced checkout, not the ref string — top-most pin (niri) names the RPM; smithay is log-only
GIT_SHORT="$(short_hash "${SRC_DIR}/niri")"
echo "==> niri @ ${GIT_SHORT} (smithay @ $(short_hash "${SRC_DIR}/smithay"))"

echo "==> Compiling and packaging RPM via Podman..."
# Volume Mount Layout:
# - ${SRC_DIR}: Source tree mounted to /workspace
# - ${CARGO_CACHE_DIR}: Hermetic Cargo dependencies mounted to /workspace/.cargo
# - ${TARGET_CACHE_DIR}: Incremental compilation cache mounted to /workspace/niri/target
# - ${RPM_OUTPUT_DIR}: Artifact distribution directory mounted to /output
podman run --rm \
  --userns=keep-id \
  -e NIRI_REF="${NIRI_REF}" \
  -e GIT_SHORT="${GIT_SHORT}" \
  -v "${SRC_DIR}:/workspace:z" \
  -v "${CARGO_CACHE_DIR}:/workspace/.cargo:z" \
  -v "${TARGET_CACHE_DIR}:/workspace/niri/target:z" \
  -v "${RPM_OUTPUT_DIR}:/output:Z" \
  "${IMAGE_NAME}"

echo "==> Success! RPM file placed in: ${RPM_OUTPUT_DIR}"
