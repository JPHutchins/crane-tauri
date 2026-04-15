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

  cargoSources = craneLib.fileset.commonCargoSources tauriSrc;

  tauriExtraFiles = lib.fileset.unions [
    (tauriSrc + "/tauri.conf.json")
    (tauriSrc + "/icons")
    (lib.fileset.maybeMissing (tauriSrc + "/capabilities"))
  ];

  appSrc = lib.fileset.toSource {
    root = tauriSrc;
    fileset = lib.fileset.unions [
      cargoSources
      tauriExtraFiles
    ];
  };

  depsSrc = lib.fileset.toSource {
    root = tauriSrc;
    fileset = lib.fileset.difference cargoSources (
      lib.fileset.fileFilter (file: lib.hasSuffix ".rs" file.name) tauriSrc
    );
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
    ++ lib.optionals stdenv.hostPlatform.isDarwin [
      libiconv
    ];

  relocateCachedTauriPaths = ''
    while IFS= read -r -d "" buildDir; do
      while IFS= read -r -d "" file; do
        while IFS= read -r oldPath; do
          oldSourceRoot=''
          if [ -n "$oldPath" ]; then
            oldSourceRoot="''${oldPath%/target/*}"
          fi

          if [ -n "$oldSourceRoot" ] && [ "$oldSourceRoot" != "$PWD" ]; then
            substituteInPlace "$file" --replace-fail "$oldSourceRoot" "$PWD"
          fi
        done < <(grep -aoE "/[^[:space:]'\"]+/source/target/[^[:space:]'\"]+" "$file" | sort -u || true)
      done < <(grep -rIlZ "/source/target/" "$buildDir" || true)
    done < <(find target -type d -path "*/release/build" -print0 2>/dev/null)
  '';

  sharedArgs = cleanedArgs // {
    inherit pname version;
    strictDeps = true;
    cargoExtraArgs = "--features tauri/custom-protocol ${cargoExtraArgs}";
    nativeBuildInputs = [ pkgs.pkg-config ] ++ extraNativeBuildInputs;
    buildInputs = tauriBuildInputs ++ extraBuildInputs;
    postPatch = (cleanedArgs.postPatch or "") + relocateCachedTauriPaths;
  };

  commonArgs = sharedArgs // {
    src = appSrc;
  };

  resolvedCargoArtifacts =
    if cargoArtifacts != null then
      cargoArtifacts
    else
      craneLib.buildDepsOnly (sharedArgs // { src = depsSrc; });

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
          ${commonArgs.cargoExtraArgs} \
          --config "$TAURI_CONFIG"
      '';

      installPhaseCommand = ''
        binaryPath=$(find target -type f -path ${lib.escapeShellArg "*/release/${binaryName}"} -print -quit)

        if [ -z "$binaryPath" ]; then
          echo "failed to locate built binary ${binaryName}" >&2
          exit 1
        fi

        mkdir -p $out/bin
        cp "$binaryPath" $out/bin/
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
