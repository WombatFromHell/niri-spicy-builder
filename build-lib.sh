#!/usr/bin/env bash
# ponytail: source-only lib, shebang exists for shellcheck
# build-lib.sh — shared scaffolding for build-rpm-*.sh (source, don't execute)

IMAGE_NAME="niri-spicy-builder:f44"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Define dedicated directories for build cache vs output artifacts
HOST_CACHE_DIR="${PROJECT_ROOT}/.builder-cache"
RPM_OUTPUT_DIR="${PROJECT_ROOT}/dist"

SRC_DIR="${HOST_CACHE_DIR}/src"
CARGO_CACHE_DIR="${HOST_CACHE_DIR}/cargo"
TARGET_CACHE_DIR="${HOST_CACHE_DIR}/target"

ensure_dirs() {
  mkdir -p "${SRC_DIR}" "${CARGO_CACHE_DIR}" "${TARGET_CACHE_DIR}" "${RPM_OUTPUT_DIR}"
}

ensure_image() {
  echo "==> Building container image '${IMAGE_NAME}'..."
  podman build -t "${IMAGE_NAME}" -f Containerfile "${PROJECT_ROOT}"
}

sync_repo() {
  local repo_url="$1"
  local ref="$2"
  local dest_dir="$3"

  if [ ! -d "${dest_dir}/.git" ]; then
    echo "==> Cloning ${repo_url} into ${dest_dir}..."
    git clone --depth 1 "${repo_url}" "${dest_dir}"
  fi
  echo "==> Syncing ${dest_dir} to ${ref}..."
  git -C "${dest_dir}" fetch --depth 1 origin "${ref}" 2>/dev/null || git -C "${dest_dir}" fetch origin "${ref}"
  git -C "${dest_dir}" reset --hard FETCH_HEAD
  # ponytail: -fd (not -fdx) so gitignored target/ build cache survives
  git -C "${dest_dir}" clean -fd
}

short_hash() {
  git -C "$1" rev-parse --short=7 HEAD
}

# ponytail: sync_repo resets the tree every build, so patches are always freshly
# applied to the pinned ref — a patch that no longer applies fails the build
apply_patches() {
  local tree="$1"
  local dir="${PROJECT_ROOT}/patches/${tree}"
  [ -d "${dir}" ] || return 0
  while IFS= read -r -d '' patch; do
    echo "==> Applying ${tree} patch: ${patch##*/}"
    git -C "${SRC_DIR}/${tree}" apply "${patch}"
  done < <(find "${dir}" -type f -name '*.patch' -print0 | sort -z)
}
