{
  pkgs,
  craneLib,
}:

{
  pname,
  version,
  src,
  frontend,
  binaryName ? pname,
  cargoExtraArgs ? "",
  cargoArtifacts ? null,
  extraBuildInputs ? [ ],
  extraNativeBuildInputs ? [ ],
  extraTauriConfig ? { },
  ...
}@origArgs:

let
  inherit (pkgs) lib;

  cleanedArgs = builtins.removeAttrs origArgs [
    "frontend"
    "binaryName"
    "cargoExtraArgs"
    "cargoArtifacts"
    "extraBuildInputs"
    "extraNativeBuildInputs"
    "extraTauriConfig"
  ];

  tauriSrc = src + "/src-tauri";

  cargoSrc = lib.fileset.toSource {
    root = tauriSrc;
    fileset = lib.fileset.unions [
      (craneLib.fileset.commonCargoSources tauriSrc)
      (tauriSrc + "/tauri.conf.json")
      (tauriSrc + "/icons")
      (lib.fileset.maybeMissing (tauriSrc + "/capabilities"))
    ];
  };

  tauriBuildInputs =
    with pkgs;
    [
      openssl
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [
      webkitgtk_4_1
      libsoup_3
      gtk3
      glib
      cairo
      pango
      gdk-pixbuf
      atk
      librsvg
      libayatana-appindicator
    ]
    ++ lib.optionals stdenv.isDarwin [
      libiconv
    ];

  commonArgs = cleanedArgs // {
    inherit pname version;
    src = cargoSrc;
    strictDeps = true;
    cargoExtraArgs = "--features tauri/custom-protocol ${cargoExtraArgs}";
    nativeBuildInputs = [ pkgs.pkg-config ] ++ extraNativeBuildInputs;
    buildInputs = tauriBuildInputs ++ extraBuildInputs;
  };

  resolvedCargoArtifacts =
    if cargoArtifacts != null then cargoArtifacts else craneLib.buildDepsOnly commonArgs;

  tauriConfig = builtins.toJSON (
    lib.recursiveUpdate {
      build = {
        frontendDist = "${frontend}";
        beforeBuildCommand = "";
      };
    } extraTauriConfig
  );

  app = craneLib.mkCargoDerivation (
    commonArgs
    // {
      cargoArtifacts = resolvedCargoArtifacts;
      TAURI_CONFIG = tauriConfig;

      nativeBuildInputs = commonArgs.nativeBuildInputs ++ [ pkgs.cargo-tauri ];

      buildPhaseCargoCommand = ''
        cargo tauri build --no-bundle \
          --config '${tauriConfig}'
      '';

      installPhaseCommand = ''
        mkdir -p $out/bin
        cp target/release/${lib.escapeShellArg binaryName} $out/bin/
      '';

      doInstallCargoArtifacts = false;
    }
  );
in
{
  inherit
    app
    frontend
    commonArgs
    tauriConfig
    ;
  cargoArtifacts = resolvedCargoArtifacts;
}
