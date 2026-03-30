# APK packaging — uses haskell-mobile's lib.nix.
{ sources ? import ../npins }:
let
  haskellMobileSrc = sources.haskell-mobile;
  lib = import "${haskellMobileSrc}/nix/lib.nix" { inherit sources; };
  sharedLib = import ./android.nix { inherit sources; };
in
lib.mkApk {
  inherit sharedLib;
  androidSrc = ../android;
  apkName = "prrrrrrrrr.apk";
  name = "prrrrrrrrr-apk";
}
