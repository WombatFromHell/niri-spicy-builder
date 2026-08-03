#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="niri-spicy-builder:f44"
PROJECT_ROOT="$(pwd)"

# Define dedicated directories for build cache vs output artifacts
HOST_CACHE_DIR="${PROJECT_ROOT}/.builder-cache"
RPM_OUTPUT_DIR="${PROJECT_ROOT}/dist"

SRC_DIR="${HOST_CACHE_DIR}/src"
CARGO_CACHE_DIR="${HOST_CACHE_DIR}/cargo"
TARGET_CACHE_DIR="${HOST_CACHE_DIR}/target"

# Ensure cache and distribution output directories exist
rm -rf "$RPM_OUTPUT_DIR"
mkdir -p "${SRC_DIR}" "${CARGO_CACHE_DIR}" "${TARGET_CACHE_DIR}" "${RPM_OUTPUT_DIR}"

sync_repo() {
  local repo_url="$1"
  local branch="$2"
  local dest_dir="$3"

  if [ -d "${dest_dir}/.git" ]; then
    echo "==> Pulling latest changes into ${dest_dir} (${branch})..."
    git -C "${dest_dir}" fetch origin "${branch}"
    git -C "${dest_dir}" reset --hard "origin/${branch}"
    git -C "${dest_dir}" clean -fd
  else
    echo "==> Cloning ${repo_url} (${branch}) into ${dest_dir}..."
    git clone --depth 1 -b "${branch}" "${repo_url}" "${dest_dir}"
  fi
}

echo "==> Building container image '${IMAGE_NAME}'..."
podman build -t "${IMAGE_NAME}" -f Containerfile .

echo "==> Syncing niri and smithay source trees..."
sync_repo "https://github.com/losnoco/niri" "spicy-main" "${SRC_DIR}/niri"
sync_repo "https://github.com/losnoco/smithay" "spicy-master" "${SRC_DIR}/smithay"

echo "==> Compiling and packaging RPM via Podman..."
# Volume Mount Layout:
# - ${SRC_DIR}: Source tree mounted to /workspace
# - ${CARGO_CACHE_DIR}: Hermetic Cargo dependencies mounted to /workspace/.cargo
# - ${TARGET_CACHE_DIR}: Incremental compilation cache mounted to /workspace/niri/target
# - ${RPM_OUTPUT_DIR}: Artifact distribution directory mounted to /output
podman run --rm \
  --userns=keep-id \
  -v "${SRC_DIR}:/workspace:z" \
  -v "${CARGO_CACHE_DIR}:/workspace/.cargo:z" \
  -v "${TARGET_CACHE_DIR}:/workspace/niri/target:z" \
  -v "${RPM_OUTPUT_DIR}:/output:Z" \
  "${IMAGE_NAME}"

echo "==> Success! RPM file placed in: ${RPM_OUTPUT_DIR}"
