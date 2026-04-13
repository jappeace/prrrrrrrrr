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
    , pr-sync-api
    , servant, servant-client-core
    , http-types, http-media, case-insensitive, mtl, bytestring, time
    }:
    mkDerivation {
      pname = "prrrrrrrrr";
      version = "0.1.0.0";
      libraryHaskellDepends = [
        base containers sqlite-simple text
        pr-sync-api
        servant servant-client-core
        http-types http-media case-insensitive mtl bytestring time
      ];
      license = lib.licenses.mit;
    };

  crossDeps = import "${hatterSrc}/nix/cross-deps.nix" {
    inherit sources androidArch consumerCabal2Nix;
    hpkgs = self: _super: {
      pr-sync-api = self.callCabal2nix "pr-sync-api" prSyncApiSrc {};
    };
  };

in
lib.mkAndroidLib {
  inherit hatterSrc mainModule crossDeps;
  pname = "prrrrrrrrr-android";
  soName = "libhaskellmobile.so";
  javaPackageName = "me.jappie.prrrrrrrrr";
  extraJniBridge = [ ../cbits/jni_extras.c ];
  extraNdkCompile = ndkCc: sysroot: ''
    ${ndkCc} -c -fPIC -I${sysroot}/usr/include \
      -o storage_helper.o ${../cbits/storage_helper.c}
  '';
  extraModuleCopy = ''
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
  extraLinkObjects = [ "$(pwd)/storage_helper.o" ];
  extraGhcIncludeDirs = [ ../cbits ];
}
