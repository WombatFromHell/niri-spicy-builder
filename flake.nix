{
  description = ''
    RPM builders for the spicy niri fork and xwayland-satellite, plus a nixpkgs
    overlay exposing both as native packages. Consumers on NixOS/Nix use it from
    this GitHub repo:

      inputs.niri-spicy-builder.url = "github:WombatFromHell/niri-spicy-builder";

      nixpkgs.overlays = [ niri-spicy-builder.overlays.default ];
  '';

  inputs.nixpkgs.url = "https://flakehub.com/f/DeterminateSystems/nixpkgs-26.05-chilled/0.1";

  # ponytail: only honored when this flake is run directly (nix build/develop here, or
  # `nix build github:WombatFromHell/niri-spicy-builder#niri`); Nix ignores nixConfig on
  # flakes used as *inputs*, so downstream consumers repeat it (see description).
  nixConfig = {
    extra-substituters = ["https://wombatfromhell.cachix.org"];
    extra-trusted-public-keys = ["wombatfromhell.cachix.org-1:pyIVJJkoLxkjH/MKK1ylrrdJKPpm+aXLeD2zAqVk9lA="];
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    inherit (nixpkgs) lib;

    # ponytail: x86_64 only; add a system here if that changes
    systems = ["x86_64-linux"];
    forSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

    # ponytail: pins.json is shared with build-lib.sh (jq) — the only place revs and hashes
    # live. The RPM scripts only read the revs; the hashes are nix-only.
    pins = builtins.fromJSON (builtins.readFile ./pins.json);

    # ponytail: callPackage hands each file nixpkgs' own niri / xwayland-satellite plus
    # their deps — everything comes from this flake's nixpkgs, never the Containerfile.
    build = pkgs: {
      niri = pkgs.callPackage ./_niri_pkg.nix {inherit pins;};
      xwayland-satellite = pkgs.callPackage ./_xwayland-satellite_pkg.nix {inherit pins;};
    };
  in {
    packages = forSystems (
      pkgs: let
        p = build pkgs;
      in
        p // {default = p.niri;}
    );

    # ponytail: a view onto packages, so consumers get the flake-pinned build deps (and
    # binary-cache hits). `inputs.niri-spicy-builder.inputs.nixpkgs.follows = "nixpkgs"`
    # trades those hits for a smaller closure.
    overlays.default = final: prev: {
      inherit (self.packages.${prev.stdenv.hostPlatform.system}) niri xwayland-satellite;
    };

    devShells = forSystems (
      pkgs: let
        built = build pkgs;
      in {
        default = pkgs.mkShell {
          # ponytail: toolchain, native/build deps and setup hooks come from the same
          # derivations the packages use; inputsFrom doesn't force src/cargoDeps.
          inputsFrom = [built.niri built.xwayland-satellite];

          # git/jq: the RPM scripts (jq reads pins.json)
          packages = [pkgs.git pkgs.jq];

          # ponytail: mkShell merges inputs, not env — these mirror _niri_pkg.nix and
          # nixpkgs' niri (EGL / wayland-client are only dlopen()ed). Re-check on a bump.
          env = {
            RUSTFLAGS = toString (
              map (a: "-C link-arg=" + a) [
                "-Wl,--push-state,--no-as-needed"
                "-lEGL"
                "-lwayland-client"
                "-Wl,--pop-state"
              ]
            );
            SHADERC_LIB_DIR = "${lib.getLib pkgs.shaderc}/lib";
          };
          # lets a locally built binary find the libs it dlopen()s
          LD_LIBRARY_PATH = lib.makeLibraryPath built.niri.buildInputs;
        };
      }
    );
  };
}
