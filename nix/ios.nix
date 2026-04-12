# iOS static library — uses haskell-mobile's lib.nix.
#
# Builds with native macOS GHC, then patches Mach-O with mac2ios.
# No cross-compiler needed — mac2ios handles the platform tag rewrite.
{ sources ? import ../npins
, simulator ? false
, mainModule ? ../app/MobileMain.hs
}:
let
  haskellMobileSrc = sources.haskell-mobile;
  prSyncApiSrc = sources.pr-sync-api;
  lib = import "${haskellMobileSrc}/nix/lib.nix" { inherit sources; };

  # Inline cabal2nix function — only library deps, no test deps.
  # haskell-mobile is compiled separately by mkIOSLib.
  consumerCabal2Nix =
    { mkDerivation, base, containers, lib, persistent, persistent-sqlite, text
    , pr-sync-api
    , servant, servant-client-core
    , http-types, http-media, case-insensitive, mtl, bytestring, time
    }:
    mkDerivation {
      pname = "prrrrrrrrr";
      version = "0.1.0.0";
      libraryHaskellDepends = [
        base containers persistent persistent-sqlite text
        pr-sync-api
        servant servant-client-core
        http-types http-media case-insensitive mtl bytestring time
      ];
      license = lib.licenses.mit;
    };

  iosDeps = import "${haskellMobileSrc}/nix/ios-deps.nix" {
    inherit sources consumerCabal2Nix;
    hpkgs = self: super: {
      pr-sync-api = self.callCabal2nix "pr-sync-api" prSyncApiSrc {};
    };
  };

in
lib.mkIOSLib {
  inherit haskellMobileSrc mainModule simulator;
  pname = "prrrrrrrrr-ios";
  crossDeps = iosDeps;
  extraModuleCopy = ''
    mkdir -p GymTracker
    cp ${../src/HaskellMobile/App.hs} HaskellMobile/App.hs
    cp ${../src/GymTracker/AppState.hs} GymTracker/AppState.hs
    cp ${../src/GymTracker/Config.hs} GymTracker/Config.hs
    cp ${../src/GymTracker/Model.hs} GymTracker/Model.hs
    cp ${../src/GymTracker/Schema.hs} GymTracker/Schema.hs
    cp ${../src/GymTracker/ServantNative.hs} GymTracker/ServantNative.hs
    cp ${../src/GymTracker/Storage.hs} GymTracker/Storage.hs
    cp ${../src/GymTracker/Sync.hs} GymTracker/Sync.hs
    cp ${../src/GymTracker/Views.hs} GymTracker/Views.hs
  '';
}
