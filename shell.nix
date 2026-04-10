{ sources ? import ./npins
, pkgs ? import sources.nixpkgs {}
}:
let
  haskellMobileSrc = sources.haskell-mobile;
  hp = pkgs.haskellPackages;
in
pkgs.mkShell {
  buildInputs = [
    (hp.ghcWithPackages (ps: [
      ps.text
      ps.containers
      ps.tasty
      ps.tasty-hunit
      ps.sqlite-simple
      ps.toml-parser
      ps.servant-client-core
      ps.http-types
      ps.http-media
      ps.case-insensitive
      ps.mtl
      ps.bytestring
    ]))
    pkgs.cabal-install
  ];

  # Tell cabal where to find haskell-mobile source
  shellHook = ''
    if [ ! -e haskell-mobile-src ]; then
      ln -sf ${haskellMobileSrc} haskell-mobile-src
    fi
  '';
}
