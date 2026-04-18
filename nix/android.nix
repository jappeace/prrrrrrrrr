# Android shared library — uses haskell-mobile's lib.nix.
#
# No TH cross-compilation needed — sqlite-simple has no Template Haskell.
{ sources ? import ../npins
, androidArch ? "aarch64"
, mainModule ? ../app/MobileMain.hs
}:
let
  pkgs = import sources.nixpkgs {};
  hatterSrc = sources.haskell-mobile;
  prSyncApiSrc = sources.pr-sync-api;
  lib = import "${hatterSrc}/nix/lib.nix" { inherit sources androidArch; };

  # Inline cabal2nix function — only library deps, no test deps.
  # haskell-mobile is compiled separately by mkAndroidLib.
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

  crossDeps = import "${hatterSrc}/nix/cross-deps.nix" {
    inherit sources androidArch consumerCabal2Nix hatterSrc;
    hpkgs = self: _super: {
      pr-sync-api = self.callCabal2nix "pr-sync-api" prSyncApiSrc {};
    };
  };

in
lib.mkAndroidLib {
  inherit hatterSrc mainModule crossDeps;
  pname = "prrrrrrrrr-android";
  javaPackageName = "me.jappie.prrrrrrrrr";
  # The new lib.nix (keyframe-animation) compiles Main.hs with -c (one-shot),
  # which looks for .hi files for imports — consumer source modules only have
  # .hs files.  Override to --make so GHC compiles consumer sources transitively.
  # Remove hatter source files first to avoid ambiguity with the package DB.
  extraGhcFlags = ["--make" "-no-link"];
  extraModuleCopy = ''
    # Remove hatter source files — hatter is pre-compiled in the package DB.
    # Leaving them would cause "ambiguous module" errors with --make.
    rm -f Hatter.hs
    rm -rf Hatter/

    mkdir -p GymTracker Hatter
    cp ${../src/Hatter/App.hs} Hatter/App.hs
    cp ${../src/GymTracker/AppState.hs} GymTracker/AppState.hs
    cp ${../src/GymTracker/Config.hs} GymTracker/Config.hs
    cp ${../src/GymTracker/Model.hs} GymTracker/Model.hs
    cp ${../src/GymTracker/ServantNative.hs} GymTracker/ServantNative.hs
    cp ${../src/GymTracker/Storage.hs} GymTracker/Storage.hs
    cp ${../src/GymTracker/Sync.hs} GymTracker/Sync.hs
    cp ${../src/GymTracker/Views.hs} GymTracker/Views.hs
  '';
  # --make produces .o files for each consumer module; the link step needs them.
  extraLinkObjects = [
    "$(pwd)/Hatter/App.o"
    "$(pwd)/GymTracker/AppState.o"
    "$(pwd)/GymTracker/Config.o"
    "$(pwd)/GymTracker/Model.o"
    "$(pwd)/GymTracker/ServantNative.o"
    "$(pwd)/GymTracker/Storage.o"
    "$(pwd)/GymTracker/Sync.o"
    "$(pwd)/GymTracker/Views.o"
  ];
}
