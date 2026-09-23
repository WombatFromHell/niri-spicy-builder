#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/build-lib.sh"

parse_args "$@"

# ponytail: shallow fetch covers branch tip + pinned commit if on tip; falls back to full fetch for deep history
NIRI_REF="${NIRI_REF:-641335ff77d31f0d410d589f8a35654fc5fe31a0}"
SMITHAY_REF="${SMITHAY_REF:-ffaab7cb397f44f3c143dfe4807269abf9c769eb}"

# Ensure cache and distribution output directories exist
rm -rf "$RPM_OUTPUT_DIR"
ensure_dirs

ensure_image

echo "==> Syncing niri and smithay source trees..."
sync_repo "https://github.com/losnoco/niri" "${NIRI_REF}" "${SRC_DIR}/niri"
sync_repo "https://github.com/losnoco/smithay" "${SMITHAY_REF}" "${SRC_DIR}/smithay"

# ponytail: local patches on top of the pinned refs (sorted *.patch per tree)
apply_patches niri
apply_patches smithay

# ponytail: hash comes from the synced checkout, not the ref string — top-most pin (niri) names the RPM; smithay is log-only
GIT_SHORT="$(short_hash "${SRC_DIR}/niri")"
echo "==> niri @ ${GIT_SHORT} (smithay @ $(short_hash "${SRC_DIR}/smithay"))"

echo "==> Compiling and packaging RPM via Podman..."
# ponytail: -it so Ctrl+C forwards SIGINT into the container (no host-side `podman rm -f`)
podman run -it --rm \
  --userns=keep-id \
  -e GIT_SHORT="${GIT_SHORT}" \
  -v "${SRC_DIR}:/workspace:z" \
  -v "${CARGO_CACHE_DIR}:/workspace/.cargo:z" \
  -v "${TARGET_CACHE_DIR}:/workspace/niri/target:z" \
  -v "${RPM_OUTPUT_DIR}:/output:Z" \
  "${IMAGE_NAME}"

echo "==> Success! RPM file placed in: ${RPM_OUTPUT_DIR}"
