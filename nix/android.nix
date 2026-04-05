# Android shared library — uses haskell-mobile's lib.nix.
{ sources ? import ../npins
, androidArch ? "aarch64"
, mainModule ? ../app/MobileMain.hs
}:
let
  haskellMobileSrc = sources.haskell-mobile;
  lib = import "${haskellMobileSrc}/nix/lib.nix" { inherit sources androidArch; };
in
lib.mkAndroidLib {
  inherit haskellMobileSrc mainModule;
  pname = "prrrrrrrrr-android";
  soName = "libprrrrrrrrr.so";
  javaPackageName = "me.jappie.prrrrrrrrr";
  extraJniBridge = [ ../cbits/jni_extras.c ];
  extraNdkCompile = ndkCc: sysroot: ''
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
  # direct-sqlite bundles its own sqlite3 amalgamation via cabal c-sources;
  # the Android linker picks up -lsqlite from the system image automatically.
  extraLinkObjects = [ "$(pwd)/storage_helper.o" ];
  extraGhcIncludeDirs = [ ../cbits ];
}
