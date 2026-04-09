# Android shared library — uses haskell-mobile's lib.nix.
{ sources ? import ../npins
, androidArch ? "aarch64"
, mainModule ? ../app/MobileMain.hs
}:
let
  haskellMobileSrc = sources.haskell-mobile;
  lib = import "${haskellMobileSrc}/nix/lib.nix" { inherit sources androidArch; };

  # Inline cabal2nix function — only library deps, no test deps.
  # haskell-mobile is compiled separately by mkAndroidLib.
  consumerCabal2Nix =
    { mkDerivation, base, containers, lib, sqlite-simple, text
    , aeson, http-client, http-client-tls, http-types, time
    }:
    mkDerivation {
      pname = "prrrrrrrrr";
      version = "0.1.0.0";
      libraryHaskellDepends = [
        base containers sqlite-simple text
        aeson http-client http-client-tls http-types time
      ];
      license = lib.licenses.mit;
    };

  crossDeps = import "${haskellMobileSrc}/nix/cross-deps.nix" {
    inherit sources androidArch consumerCabal2Nix;
  };

in
lib.mkAndroidLib {
  inherit haskellMobileSrc mainModule crossDeps;
  pname = "prrrrrrrrr-android";
  soName = "libhaskellmobile.so";
  javaPackageName = "me.jappie.prrrrrrrrr";
  extraJniBridge = [ ../cbits/jni_extras.c ];
  extraNdkCompile = ndkCc: sysroot: ''
    ${ndkCc} -c -fPIC -I${sysroot}/usr/include \
      -o storage_helper.o ${../cbits/storage_helper.c}
  '';
  extraModuleCopy = ''
    mkdir -p GymTracker
    cp ${../src/HaskellMobile/App.hs} HaskellMobile/App.hs
    cp ${../src/GymTracker/Config.hs} GymTracker/Config.hs
    cp ${../src/GymTracker/Model.hs} GymTracker/Model.hs
    cp ${../src/GymTracker/Storage.hs} GymTracker/Storage.hs
    cp ${../src/GymTracker/Sync.hs} GymTracker/Sync.hs
    cp ${../src/GymTracker/Views.hs} GymTracker/Views.hs
  '';
  extraLinkObjects = [ "$(pwd)/storage_helper.o" ];
  extraGhcIncludeDirs = [ ../cbits ];
}
