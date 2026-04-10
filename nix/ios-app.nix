# iOS simulator app — stages Xcode project with pre-built Haskell library.
#
# Output: $out/share/ios/ containing project.yml, Swift sources, and
# libHaskellMobile.a ready for xcodebuild.
{ sources ? import ../npins }:
let
  haskellMobileSrc = sources.haskell-mobile;
  lib = import "${haskellMobileSrc}/nix/lib.nix" { inherit sources; };
  iosLib = import ./ios.nix { inherit sources; simulator = true; };
in
lib.mkSimulatorApp {
  inherit iosLib;
  iosSrc = "${haskellMobileSrc}/ios";
  name = "prrrrrrrrr-ios-simulator";
}
