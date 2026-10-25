# ponytail: nixpkgs' niri with the spicy fork's source swapped in; deps/features/install
# layout stay nixpkgs'. Hashes live here, revs in pins.json.
{
  lib,
  niri,
  applyPatches,
  fetchFromGitHub,
  rustPlatform,
  shaderc,
  removeReferencesTo,
  pins,
}: let
  # The fork's Cargo.toml patches smithay with `path = "../smithay"`, which has no
  # sibling in the nix store — point it at the fetched, patched smithay instead.
  smithay = applyPatches {
    name = "smithay-spicy-source";
    src = fetchFromGitHub {
      owner = "losnoco";
      repo = "smithay";
      rev = pins.smithay.rev;
      hash = pins.smithay.hash;
    };
    patches = [./patches/smithay/0002-fix-multirenderer-offscreen-routing.patch];
  };
in
  niri.overrideAttrs (finalAttrs: prev: {
    version = "26.04";

    # ponytail: applyPatches, not fetchFromGitHub's postFetch — a FOD can't reference ${smithay}
    src = applyPatches {
      name = "niri-spicy-source";
      src = fetchFromGitHub {
        owner = "losnoco";
        repo = "niri";
        rev = pins.niri.rev;
        hash = pins.niri.hash;
      };
      postPatch = ''
        substituteInPlace Cargo.toml --replace-fail '../smithay' "${smithay}"
      '';
    };

    # ponytail: nixpkgs builds cargoDeps from the *original* cargoHash arg, so overriding
    # cargoHash is silently ignored — override cargoDeps. On a pin bump: lib.fakeHash.
    cargoDeps = rustPlatform.fetchCargoVendor {
      inherit (finalAttrs) src;
      hash = pins.niri.cargoHash;
    };

    # ponytail: fork-only dep (absent from upstream's flake). Without SHADERC_LIB_DIR,
    # shaderc-sys falls back to a from-source build that wants cmake.
    buildInputs = prev.buildInputs ++ [shaderc];

    # ponytail: rustc embeds ${smithay}/src paths (panic locations, debuginfo); the binary
    # doesn't read them, but reference scanning would keep the source tree in niri's closure.
    nativeBuildInputs = prev.nativeBuildInputs ++ [removeReferencesTo];
    postFixup =
      (prev.postFixup or "")
      + ''
        remove-references-to -t ${smithay} $out/bin/niri
      '';

    env =
      (prev.env or {})
      // {
        # No git repo here, so niri's version string needs the commit spelled out.
        NIRI_BUILD_COMMIT = "spicy ${pins.niri.rev} (smithay ${pins.smithay.rev})";
        SHADERC_LIB_DIR = "${lib.getLib shaderc}/lib";
      };

    meta = prev.meta // {changelog = "https://github.com/losnoco/niri/commit/${pins.niri.rev}";};
  })
