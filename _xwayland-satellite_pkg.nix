# ponytail: nixpkgs' xwayland-satellite pinned to a rev; deps and features are unchanged
# (checked against upstream's flake). Hashes live here, revs in pins.json.
{
  xwayland-satellite,
  fetchFromGitHub,
  rustPlatform,
  pins,
}:
xwayland-satellite.overrideAttrs (finalAttrs: prev: {
  version = pins.satellite.version; # upstream tag the pin sits on

  src = fetchFromGitHub {
    owner = "Supreeeme";
    repo = "xwayland-satellite";
    rev = pins.satellite.rev;
    hash = pins.satellite.hash;
  };

  cargoDeps = rustPlatform.fetchCargoVendor {
    inherit (finalAttrs) src;
    hash = pins.satellite.cargoHash;
  };

  meta = prev.meta // {changelog = "https://github.com/Supreeeme/xwayland-satellite/commit/${pins.satellite.rev}";};
})
