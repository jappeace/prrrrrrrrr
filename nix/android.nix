# Android shared library — uses haskell-mobile's lib.nix.
{ sources ? import ../npins
, mainModule ? ../app/MobileMain.hs
}:
let
  haskellMobileSrc = sources.haskell-mobile;
  lib = import "${haskellMobileSrc}/nix/lib.nix" { inherit sources; };
in
lib.mkAndroidLib {
  inherit haskellMobileSrc mainModule;
  pname = "prrrrrrrrr-android";
  soName = "libprrrrrrrrr.so";
  extraNdkCompile = ndkCc: sysroot: ''
    ${ndkCc} -c -fPIC -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION \
      -I${sysroot}/usr/include -o sqlite3.o ${../cbits/sqlite3.c}
    ${ndkCc} -c -fPIC -I${sysroot}/usr/include \
      -o storage_helper.o ${../cbits/storage_helper.c}
  '';
  extraModuleCopy = ''
    mkdir -p GymTracker
    cp ${../src/HaskellMobile/App.hs} HaskellMobile/App.hs
    cp ${../src/GymTracker/Model.hs} GymTracker/Model.hs
    cp ${../src/GymTracker/Storage.hs} GymTracker/Storage.hs
    cp ${../src/GymTracker/Views.hs} GymTracker/Views.hs
  '';
  extraLinkObjects = [ "$(pwd)/sqlite3.o" "$(pwd)/storage_helper.o" ];
  extraGhcIncludeDirs = [ ../cbits ];
}
