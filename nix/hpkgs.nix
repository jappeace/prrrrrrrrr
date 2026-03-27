{ pkgs ? import ./pkgs.nix { }
, sources ? import ../npins
}:
let
  haskellMobileSrc = sources.haskell-mobile;
in
pkgs.haskellPackages.override {
  overrides = hnew: hold: {
    haskell-mobile = hnew.callCabal2nix "haskell-mobile" haskellMobileSrc { };
    prrrrrrrrr-project = hnew.callCabal2nix "prrrrrrrrr" ../. { };
  };
}
