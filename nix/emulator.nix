# Android emulator lifecycle test — uses haskell-mobile's lib.nix.
{ sources ? import ../npins }:
let
  haskellMobileSrc = sources.haskell-mobile;
  lib = import "${haskellMobileSrc}/nix/lib.nix" { inherit sources; };
  apk = import ./apk.nix { inherit sources; };
in
lib.mkEmulatorTest {
  inherit apk;
  apkFileName = "prrrrrrrrr.apk";
  packageName = "me.jappie.prrrrrrrrr";
  name = "prrrrrrrrr-emulator-test";
}
