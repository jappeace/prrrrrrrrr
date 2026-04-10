{ sources ? import ./npins
, pkgs ? import sources.nixpkgs {}
}:
let
  haskellMobileSrc = sources.haskell-mobile;
  prSyncApiSrc = sources.pr-sync-api;
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
      ps.servant
      ps.servant-client-core
      ps.http-types
      ps.http-media
      ps.case-insensitive
      ps.mtl
      ps.bytestring
      ps.time
      ps.aeson
    ]))
    pkgs.cabal-install
  ];

  # Tell cabal where to find haskell-mobile and pr-sync-api source
  shellHook = ''
    if [ ! -e haskell-mobile-src ]; then
      ln -sf ${haskellMobileSrc} haskell-mobile-src
    fi
    if [ ! -e pr-sync-api-src ]; then
      ln -sf ${prSyncApiSrc} pr-sync-api-src
    fi
  '';
}
