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
      ps.http-client
      ps.http-client-tls
      ps.http-types
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
'';
}
