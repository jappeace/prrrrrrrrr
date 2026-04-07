# Android shared library — uses haskell-mobile's lib.nix.
{ sources ? import ../npins
, androidArch ? "aarch64"
, mainModule ? ../app/MobileMain.hs
}:
let
  haskellMobileSrc = sources.haskell-mobile;
  lib = import "${haskellMobileSrc}/nix/lib.nix" { inherit sources androidArch; };

  # --- Cross-compiled dependencies (inlined from cross-deps.nix) ---
  #
  # We inline instead of calling cross-deps.nix because we need
  # --allow-newer=Only:deepseq (Only-0.1 has deepseq < 1.5 but
  # GHC 9.10's boot deepseq is 1.5.0.0), and cross-deps.nix doesn't
  # expose extraCabalBuildFlags.

  nixpkgsSrc = import "${haskellMobileSrc}/nix/patched-nixpkgs.nix" {
    nixpkgsSrc = sources.nixpkgs;
    inherit androidArch;
  };

  pkgs = import nixpkgsSrc {
    config.allowUnfree = true;
    config.android_sdk.accept_license = true;
  };

  archConfig = {
    aarch64 = { crossAttr = "aarch64-android-prebuilt"; };
    armv7a  = { crossAttr = "armv7a-android-prebuilt"; };
  }.${androidArch};

  androidPkgs = pkgs.pkgsCross.${archConfig.crossAttr};
  ghc = if androidArch == "armv7a"
    then androidPkgs.haskellPackages.ghc.override { enableProfiledLibs = false; }
    else androidPkgs.haskellPackages.ghc;
  ghcBin = "${ghc}/bin";
  ghcPrefix = ghc.targetPrefix;
  ghcCmd = "${ghcBin}/${ghcPrefix}ghc";
  ghcPkgCmd = "${ghcBin}/${ghcPrefix}ghc-pkg";
  hsc2hsCmd = "${ghcBin}/${ghcPrefix}hsc2hs";

  # Inline cabal2nix function without haskell-mobile — it's a local package
  # compiled separately by mkAndroidLib, not a Hackage dependency.
  # This avoids IFD and the haskell-mobile-not-in-haskellPkgs issue.
  # Only library deps — test deps (tasty etc.) would pull in boot packages
  # (stm, mtl, process) that mkAndroidLib doesn't statically link.
  consumerCabal2Nix =
    { mkDerivation, base, containers, lib, sqlite-simple, text }:
    mkDerivation {
      pname = "prrrrrrrrr";
      version = "0.1.0.0";
      libraryHaskellDepends = [ base containers sqlite-simple text ];
      license = lib.licenses.mit;
    };

  resolvedDeps = import "${haskellMobileSrc}/nix/resolve-deps.nix" {
    inherit pkgs consumerCabal2Nix;
  };

  crossDepsRaw = import "${haskellMobileSrc}/nix/mk-deps.nix" {
    inherit sources pkgs ghc ghcCmd ghcPkgCmd hsc2hsCmd;
    packages = resolvedDeps;
    extraBuildInputs = [ androidPkgs.libffi androidPkgs.gmp ];
    extraCabalBuildFlags = [
      "--extra-lib-dirs=${androidPkgs.gmp}/lib"
      "--extra-lib-dirs=${androidPkgs.libffi}/lib"
      # Hackage source tarballs have overly strict upper bounds on boot
      # packages (deepseq, ghc-prim, etc.) but these versions are proven
      # compatible — nixpkgs builds them natively with GHC 9.10.
      "--allow-newer=all"
    ];
    derivationName = "haskell-mobile-cross-deps";
    perPackageFlags = { direct-sqlite = "-systemlib"; };
  };

  # Work around mk-deps.nix bugs:
  # 1. `find | head -20` triggers SIGPIPE under pipefail.
  # 2. All sibling packages listed as deps of every package, creating cycles.
  #    Strip -inplace sibling IDs from .conf files, then recache.
  # 3. Sub-library .a files (e.g. attoparsec-internal) not collected —
  #    mk-deps.nix only looks at PKG_DIR/build/, not PKG_DIR/l/*/build/.
  crossDeps = crossDepsRaw.overrideAttrs (old: {
    installPhase = (builtins.replaceStrings
      [ "find $out/hi -name '*.hi' | head -20" ]
      [ "find $out/hi -name '*.hi' | head -20 || true" ]
      old.installPhase) + ''

      echo "=== Collecting missed .a files (sub-libraries etc.) ==="
      find $TMPDIR/project/dist-newstyle -name 'libHS*.a' | while read aFile; do
        aName=$(basename "$aFile")
        if [ ! -f "$out/lib/$aName" ]; then
          echo "  extra: $aName"
          cp "$aFile" "$out/lib/"
        fi
      done

      echo "=== Copying boot libraries needed by transitive deps ==="
      # mkAndroidLib only whole-archives a fixed set of boot libs (rts, base,
      # text, etc.) but cross-deps packages may need more (stm, mtl, process,
      # exceptions, os-string, etc.). Copy ALL remaining boot libs from the
      # cross-GHC, excluding those already linked by mkAndroidLib to avoid
      # duplicate symbols.
      EXCLUDE="rts ghc-prim ghc-bignum ghc-internal base integer-gmp text array deepseq containers transformers time"
      find ${ghc}/lib -name 'libHS*.a' ! -name '*_p.a' ! -name '*_thr*' ! -name '*-ghc*' | while read A; do
        NAME=$(basename "$A")
        SKIP=0
        for EXCL in $EXCLUDE; do
          case $NAME in "libHS$EXCL-"*) SKIP=1; break;; esac
        done
        [ "$SKIP" = "1" ] && continue
        [ -f "$out/lib/$NAME" ] && continue
        echo "  boot: $NAME"
        cp "$A" "$out/lib/"
      done

      echo "=== Fixing cyclic sibling deps in package configs ==="
      for CONF in $out/pkgdb/*.conf; do
        sed -i '/^id:/b; /^key:/b; s/ [^ ]*-inplace//g' "$CONF"
      done
      ${ghcPkgCmd} --package-db=$out/pkgdb recache
    '';
  });

in
lib.mkAndroidLib {
  inherit haskellMobileSrc mainModule crossDeps;
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
  extraLinkObjects = [ "$(pwd)/storage_helper.o" ];
  extraGhcIncludeDirs = [ ../cbits ];
}
