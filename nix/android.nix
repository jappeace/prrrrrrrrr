# Android shared library — uses haskell-mobile's lib.nix.
#
# TH cross-compilation support (static iserv-proxy, native libdl,
# mmap wrapper, QEMU overlay, package DB patching) is provided by
# haskell-mobile's cross-deps.nix — no consumer-side setup needed.
{ sources ? import ../npins
, androidArch ? "aarch64"
, mainModule ? ../app/MobileMain.hs
}:
let
  pkgs = import sources.nixpkgs {};
  haskellMobileSrc = sources.haskell-mobile;
  prSyncApiSrc = sources.pr-sync-api;
  lib = import "${haskellMobileSrc}/nix/lib.nix" { inherit sources androidArch; };

  # Inline cabal2nix function — only library deps, no test deps.
  # haskell-mobile is compiled separately by mkAndroidLib.
  # Schema package — built as a cross-dep so its Template Haskell
  # runs with iserv-proxy / -fexternal-interpreter.
  schemaSrc = ../schema;

  consumerCabal2Nix =
    { mkDerivation, base, containers, lib, persistent, persistent-sqlite, text
    , prrrrrrrrr-schema
    , pr-sync-api
    , servant, servant-client-core
    , http-types, http-media, case-insensitive, mtl, bytestring, time
    }:
    mkDerivation {
      pname = "prrrrrrrrr";
      version = "0.1.0.0";
      libraryHaskellDepends = [
        base containers persistent persistent-sqlite text
        prrrrrrrrr-schema
        pr-sync-api
        servant servant-client-core
        http-types http-media case-insensitive mtl bytestring time
      ];
      license = lib.licenses.mit;
    };

  crossDeps = import "${haskellMobileSrc}/nix/cross-deps.nix" {
    inherit sources androidArch consumerCabal2Nix;
    hpkgs = self: super: {
      prrrrrrrrr-schema = self.callCabal2nix "prrrrrrrrr-schema" schemaSrc {};
      pr-sync-api = self.callCabal2nix "pr-sync-api" prSyncApiSrc {};
      # nixpkgs enables -fsystemlib which links against the system sqlite C
      # library.  That pulls in tcl → tzdata which fails to cross-compile for
      # Android.  Disable it so persistent-sqlite uses its bundled amalgamation.
      #
      # The bundled path has extra-libraries: pthread, but Android's bionic
      # has no separate libpthread (it's built into libc).  We create a stub
      # archive so the cabal configure check passes; actual pthread symbols
      # are resolved from libc at link time.
      persistent-sqlite =
        let
          # Empty archive — the configure check only verifies the file
          # exists.  Actual pthread symbols come from bionic's libc.
          stubPthread = pkgs.runCommand "stub-libpthread" {} ''
            mkdir -p $out/lib
            ${pkgs.binutils}/bin/ar crs $out/lib/libpthread.a
          '';
          withoutFlag = pkgs.haskell.lib.compose.disableCabalFlag "systemlib" super.persistent-sqlite;
          withoutSqlite = withoutFlag.overrideAttrs (old: {
            buildInputs = builtins.filter
              (d: builtins.match "sqlite-.*" (d.name or "") == null)
              (old.buildInputs or []);
          });
        in pkgs.haskell.lib.compose.appendConfigureFlags
          [ "--extra-lib-dirs=${stubPthread}/lib" ] withoutSqlite;
    };
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
    cp ${../src/GymTracker/AppState.hs} GymTracker/AppState.hs
    cp ${../src/GymTracker/Config.hs} GymTracker/Config.hs
    cp ${../src/GymTracker/ServantNative.hs} GymTracker/ServantNative.hs
    cp ${../src/GymTracker/Storage.hs} GymTracker/Storage.hs
    cp ${../src/GymTracker/Sync.hs} GymTracker/Sync.hs
    cp ${../src/GymTracker/Views.hs} GymTracker/Views.hs
  '';
  extraLinkObjects = [ "$(pwd)/storage_helper.o" ];
  extraGhcIncludeDirs = [ ../cbits ];
}
