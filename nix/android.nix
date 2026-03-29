# Android shared library build for prrrrrrrrr.
# Adapts haskell-mobile's android.nix, adding SQLite and storage_helper.
{ sources ? import ../npins }:
let
  haskellMobileSrc = sources.haskell-mobile;

  pkgs = import sources.nixpkgs {
    config.allowUnfree = true;
    config.android_sdk.accept_license = true;
  };

  androidPkgs = pkgs.pkgsCross.aarch64-android-prebuilt;
  ghc = androidPkgs.haskellPackages.ghc;
  ghcCmd = "${ghc}/bin/${ghc.targetPrefix}ghc";
  ghcPkgDir = "${ghc}/lib/${ghc.targetPrefix}ghc-${ghc.version}/lib/aarch64-linux-ghc-${ghc.version}";

  androidComposition = pkgs.androidenv.composeAndroidPackages {
    includeNDK = true;
  };
  ndk = "${androidComposition.ndk-bundle}/libexec/android-sdk/ndk/${androidComposition.ndk-bundle.version}";
  ndkCc = "${ndk}/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android26-clang";
  sysroot = "${ndk}/toolchains/llvm/prebuilt/linux-x86_64/sysroot";

in pkgs.stdenv.mkDerivation {
  pname = "prrrrrrrrr-android";
  version = "0.1.0.0";

  src = ../src;

  nativeBuildInputs = [ ghc ];
  buildInputs = [ androidPkgs.libffi androidPkgs.gmp ];

  buildPhase = ''
    GHC_LIBDIR=$(${ghcCmd} --print-libdir)
    RTS_INCLUDE=$(dirname $(find $GHC_LIBDIR -name "HsFFI.h" | head -1))

    echo "=== Compile JNI bridge + Android UI bridge ==="
    ${ndkCc} -c -fPIC \
      -I${sysroot}/usr/include \
      -I$RTS_INCLUDE \
      -I${haskellMobileSrc}/include \
      -o jni_bridge.o \
      ${haskellMobileSrc}/cbits/jni_bridge.c

    ${ndkCc} -c -fPIC \
      -I${sysroot}/usr/include \
      -I$RTS_INCLUDE \
      -I${haskellMobileSrc}/include \
      -o ui_bridge_android.o \
      ${haskellMobileSrc}/cbits/ui_bridge_android.c

    echo "=== Compile SQLite amalgamation ==="
    ${ndkCc} -c -fPIC \
      -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION \
      -I${sysroot}/usr/include \
      -o sqlite3.o \
      ${../cbits/sqlite3.c}

    echo "=== Compile storage helper ==="
    ${ndkCc} -c -fPIC \
      -I${sysroot}/usr/include \
      -o storage_helper.o \
      ${../cbits/storage_helper.c}

    echo "=== Copy source modules ==="
    mkdir -p HaskellMobile GymTracker
    cp ${haskellMobileSrc}/src/HaskellMobile/Types.hs HaskellMobile/
    cp ${haskellMobileSrc}/src-lifecycle/HaskellMobile/Lifecycle.hs HaskellMobile/
    cp ${haskellMobileSrc}/src-ui/HaskellMobile/Widget.hs HaskellMobile/
    cp ${haskellMobileSrc}/src-ui/HaskellMobile/UIBridge.hs HaskellMobile/
    cp ${haskellMobileSrc}/src-ui/HaskellMobile/Render.hs HaskellMobile/
    cp ${haskellMobileSrc}/src/HaskellMobile.hs .
    cp ${../src/HaskellMobile/App.hs} HaskellMobile/
    cp ${../src/GymTracker/Model.hs} GymTracker/
    cp ${../src/GymTracker/Storage.hs} GymTracker/
    cp ${../src/GymTracker/Views.hs} GymTracker/

    echo "=== Compile Haskell shared library ==="
    GHC_PKG_DIR="${ghcPkgDir}"
    CONTAINERS_LIB=$(find $GHC_PKG_DIR -name "libHScontainers-*.a" | head -1)

    ${ghcCmd} -shared -O2 \
      -o libprrrrrrrrr.so \
      -DHASKELL_MOBILE_PLATFORM \
      -I${haskellMobileSrc}/include \
      -I${../cbits} \
      HaskellMobile.hs \
      ${haskellMobileSrc}/cbits/android_stubs.c \
      ${haskellMobileSrc}/cbits/platform_log.c \
      ${haskellMobileSrc}/cbits/numa_stubs.c \
      ${haskellMobileSrc}/cbits/ui_bridge.c \
      -optl-L${androidPkgs.gmp}/lib \
      -optl-L${androidPkgs.libffi}/lib \
      -optl-lffi \
      -optl-llog \
      -optl-Wl,-z,max-page-size=16384 \
      -optl$(pwd)/jni_bridge.o \
      -optl$(pwd)/ui_bridge_android.o \
      -optl$(pwd)/sqlite3.o \
      -optl$(pwd)/storage_helper.o \
      -optl-Wl,-u,haskellInit \
      -optl-Wl,-u,haskellGreet \
      -optl-Wl,-u,haskellOnLifecycle \
      -optl-Wl,-u,haskellCreateContext \
      -optl-Wl,-u,haskellRenderUI \
      -optl-Wl,-u,haskellOnUIEvent \
      -optl-Wl,-u,haskellOnUITextChange \
      -optl-Wl,--whole-archive \
      -optl$GHC_PKG_DIR/rts-1.0.2/libHSrts-1.0.2.a \
      -optl$GHC_PKG_DIR/ghc-prim-0.12.0-b5b0/libHSghc-prim-0.12.0-b5b0.a \
      -optl$GHC_PKG_DIR/ghc-bignum-1.3-3be2/libHSghc-bignum-1.3-3be2.a \
      -optl$GHC_PKG_DIR/ghc-internal-9.1003.0-04f5/libHSghc-internal-9.1003.0-04f5.a \
      -optl$GHC_PKG_DIR/base-4.20.2.0-ecb4/libHSbase-4.20.2.0-ecb4.a \
      -optl$GHC_PKG_DIR/integer-gmp-1.1-e5a1/libHSinteger-gmp-1.1-e5a1.a \
      -optl$GHC_PKG_DIR/text-2.1.3-8cdf/libHStext-2.1.3-8cdf.a \
      -optl$GHC_PKG_DIR/array-0.5.8.0-39be/libHSarray-0.5.8.0-39be.a \
      -optl$GHC_PKG_DIR/deepseq-1.5.0.0-dd79/libHSdeepseq-1.5.0.0-dd79.a \
      -optl$CONTAINERS_LIB \
      -optl-Wl,--no-whole-archive
  '';

  installPhase = ''
    mkdir -p $out/lib/arm64-v8a
    cp libprrrrrrrrr.so $out/lib/arm64-v8a/
    cp ${androidPkgs.gmp}/lib/libgmp.so $out/lib/arm64-v8a/
    cp ${androidPkgs.libffi}/lib/libffi.so $out/lib/arm64-v8a/
  '';
}
