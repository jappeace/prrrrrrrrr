{ sources ? import ../npins }:
let
  pkgs = import sources.nixpkgs {
    config.allowUnfree = true;
    config.android_sdk.accept_license = true;
  };
  haskellMobileSrc = sources.haskell-mobile;
  prSyncApiSrc = sources.pr-sync-api;
  hp = pkgs.haskellPackages;

  # Both packages built together so cabal can resolve the dependency
  # from prrrrrrrrr to haskell-mobile (IORef-based app registration).
  combined = pkgs.stdenv.mkDerivation {
    name = "prrrrrrrrr-project";
    src = ../.;
    nativeBuildInputs = [
      (hp.ghcWithPackages (ps: [
        ps.text
        ps.containers
        ps.tasty
        ps.tasty-hunit
        ps.persistent
        ps.persistent-sqlite
        ps.toml-parser
        ps.servant
        ps.servant-client-core
        ps.http-types
        ps.http-media
        ps.case-insensitive
        ps.mtl
        ps.bytestring
        ps.time
        ps.aeson
      ]))
      pkgs.cabal-install
    ];

    buildPhase = ''
      export HOME=$TMPDIR

      # Pre-create cabal config to prevent Hackage index fetch attempt.
      # In the nix sandbox there is no network.
      mkdir -p $HOME/.config/cabal
      cat > $HOME/.config/cabal/config <<'CABALEOF'
      CABALEOF

      # Symlink haskell-mobile and pr-sync-api source for cabal.project
      rm -rf haskell-mobile-src
      ln -s ${haskellMobileSrc} haskell-mobile-src
      rm -rf pr-sync-api-src
      ln -s ${prSyncApiSrc} pr-sync-api-src

      # GHC already has all deps via ghcWithPackages.
      cabal build all --enable-tests --offline
      cabal test unit --offline
    '';

    installPhase = ''
      mkdir -p $out
      touch $out/ci-passed
    '';
  };

  runTest = name: testDrv: scriptName:
    pkgs.runCommand "run-${name}" {
      __noChroot = true;
      nativeBuildInputs = [ pkgs.jdk17_headless ];
    } ''
      ${testDrv}/bin/${scriptName}
      touch $out
    '';
in {
  native = combined;
  android = import ./android.nix { inherit sources; };
  apk = import ./apk.nix { inherit sources; };
  apkArm7a = import ./apk.nix { inherit sources; androidArch="armv7a";};

  # Android tests (Linux, needs KVM)
  emulator-test = runTest "emulator-test"
    (import ./emulator.nix { inherit sources; }) "test-lifecycle";
  emulator-ui-test = runTest "emulator-ui-test"
    (import ./emulator-ui.nix { inherit sources; }) "test-ui";
} // (if pkgs.stdenv.isDarwin then {
  # iOS builds require macOS (native GHC + mac2ios Mach-O patching)
  ios = import ./ios.nix { inherit sources; };
  ios-simulator = import ./ios.nix { inherit sources; simulator = true; };
  ios-app = import ./ios-app.nix { inherit sources; };
} else {})
