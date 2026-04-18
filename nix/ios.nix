# iOS static library — uses haskell-mobile's lib.nix.
#
# Builds with native macOS GHC, then patches Mach-O with mac2ios.
# No cross-compiler needed — mac2ios handles the platform tag rewrite.
{ sources ? import ../npins
, simulator ? false
, mainModule ? ../app/MobileMain.hs
}:
let
  hatterSrc = sources.haskell-mobile;
  prSyncApiSrc = sources.pr-sync-api;
  lib = import "${hatterSrc}/nix/lib.nix" { inherit sources; };

  # Inline cabal2nix function — only library deps, no test deps.
  # haskell-mobile is compiled separately by mkIOSLib.
  consumerCabal2Nix =
    { mkDerivation, base, containers, lib, sqlite-simple, text
    , beam-core, beam-sqlite
    , pr-sync-api
    , servant, servant-client-core
    , http-types, http-media, case-insensitive, mtl, bytestring, time
    , random, async
    }:
    mkDerivation {
      pname = "prrrrrrrrr";
      version = "0.1.0.0";
      libraryHaskellDepends = [
        base containers sqlite-simple text
        beam-core beam-sqlite
        pr-sync-api
        servant servant-client-core
        http-types http-media case-insensitive mtl bytestring time
        random async
      ];
      license = lib.licenses.mit;
    };

  iosDeps = import "${hatterSrc}/nix/ios-deps.nix" {
    inherit sources consumerCabal2Nix;
    hpkgs = self: _super: {
      pr-sync-api = self.callCabal2nix "pr-sync-api" prSyncApiSrc {};
    };
  };

in
lib.mkIOSLib {
  inherit hatterSrc mainModule simulator;
  pname = "prrrrrrrrr-ios";
  crossDeps = iosDeps;
  extraModuleCopy = ''
    mkdir -p GymTracker
    cp ${../src/GymTracker/App.hs} GymTracker/App.hs
    cp ${../src/GymTracker/AppState.hs} GymTracker/AppState.hs
    cp ${../src/GymTracker/Config.hs} GymTracker/Config.hs
    cp ${../src/GymTracker/Model.hs} GymTracker/Model.hs
    cp ${../src/GymTracker/ServantNative.hs} GymTracker/ServantNative.hs
    cp ${../src/GymTracker/Storage.hs} GymTracker/Storage.hs
    cp ${../src/GymTracker/Sync.hs} GymTracker/Sync.hs
    cp ${../src/GymTracker/Views.hs} GymTracker/Views.hs
  '';
}
