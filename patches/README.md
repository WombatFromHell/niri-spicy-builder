# niri-spicy patches

Custom patches applied by `build-rpm-spicy.sh` after the source trees are
synced to their pinned refs:

- `niri/*.patch` — applied to `${SRC_DIR}/niri`
- `smithay/*.patch` — applied to `${SRC_DIR}/smithay`

Applied in sorted filename order with `git apply` (use a `NNNN-` prefix to
control ordering). The source trees are hard-reset to the pinned ref on every
build, so patches are always applied to a clean tree; a patch that no longer
applies fails the build.
