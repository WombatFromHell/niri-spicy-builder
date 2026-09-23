#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "$0")" && pwd)/build-lib.sh"

parse_args "$@"

# ponytail: default to upstream default branch; override to pin a commit/branch
SATELLITE_REF="${SATELLITE_REF:-add2795134593faafce60e404a0a75df68e9ee0c}"

# ponytail: don't wipe dist/ here — spicy runs first and wipes; satellite appends
ensure_dirs
mkdir -p "${HOST_CACHE_DIR}/satellite-cargo" "${HOST_CACHE_DIR}/satellite-target"

ensure_image

echo "==> Syncing xwayland-satellite source tree..."
sync_repo "https://github.com/Supreeeme/xwayland-satellite" "${SATELLITE_REF}" "${SRC_DIR}/xwayland-satellite"

# ponytail: hash comes from the synced checkout, not the ref string
GIT_SHORT="$(short_hash "${SRC_DIR}/xwayland-satellite")"
echo "==> xwayland-satellite @ ${GIT_SHORT}"

echo "==> Compiling and packaging RPM via Podman..."
# ponytail: -it so Ctrl+C forwards SIGINT into the container (no host-side `podman rm -f`)
podman run -it --rm \
  --userns=keep-id \
  -e GIT_SHORT="${GIT_SHORT}" \
  -v "${SRC_DIR}/xwayland-satellite:/workspace:z" \
  -v "${HOST_CACHE_DIR}/satellite-cargo:/workspace/.cargo:z" \
  -v "${HOST_CACHE_DIR}/satellite-target:/workspace/target:z" \
  -v "${RPM_OUTPUT_DIR}:/output:Z" \
  --entrypoint /usr/local/bin/entrypoint-satellite.sh \
  "${IMAGE_NAME}"

echo "==> Success! RPM file placed in: ${RPM_OUTPUT_DIR}"
