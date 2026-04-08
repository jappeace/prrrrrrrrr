# APK packaging — uses haskell-mobile's lib.nix.
{ sources ? import ../npins, androidArch ? "aarch64" }:
let
  haskellMobileSrc = sources.haskell-mobile;
  abiDir = { aarch64 = "arm64-v8a"; armv7a = "armeabi-v7a"; }.${androidArch};
  lib = import "${haskellMobileSrc}/nix/lib.nix" { inherit sources androidArch; };
  sharedLib = import ./android.nix { inherit sources androidArch; };
in
lib.mkApk {
  sharedLibs = [{ lib = sharedLib; inherit abiDir; }];
  androidSrc = ../android;
  baseJavaSrc = "${haskellMobileSrc}/android/java";
  apkName = "prrrrrrrrr.apk";
  name = "prrrrrrrrr-apk";
}
