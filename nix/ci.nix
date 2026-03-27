{ sources ? import ../npins }:
let
  hpkgs = import ./hpkgs.nix { inherit sources; pkgs = import sources.nixpkgs {}; };
in {
  native = hpkgs."prrrrrrrrr-project";
}
