{
  pkgs,
  craneLib,
}:

# Build arguments are a module: a plain attrset (`{ pname = ...; ... }`) is the
# common form, but a function (`{ config, ... }: { ... }`) or a list of modules
# also works. Arguments are type-checked and unknown attributes are rejected;
# arbitrary crane / mkDerivation args go through `craneArgs`.
args:

let
  inherit (pkgs) lib;
  inherit (lib) types mkOption;

  optionsModule =
    { config, ... }:
    {
      options = {
        pname = mkOption {
          type = types.str;
          description = "Nix package name (and default binaryName).";
        };
        version = mkOption {
          type = types.str;
          description = "Package version.";
        };
        src = mkOption {
          type = types.path;
          description = "Repo root containing src-tauri/ (a path or store derivation).";
        };
        frontend = mkOption {
          type = types.package;
          description = "Built frontend assets derivation, embedded into the app.";
        };
        binaryName = mkOption {
          type = types.str;
          default = config.pname;
          defaultText = lib.literalExpression "pname";
          description = ''
            Cargo binary name to install from target/release. Defaults to pname,
            but the on-disk binary is named by cargo ([package].name in
            src-tauri/Cargo.toml); set this when they differ, or the install
            phase fails late with "failed to locate built binary".
          '';
        };
        cargoExtraArgs = mkOption {
          type = types.str;
          default = "";
          description = "Extra args appended to cargo invocations.";
        };
        cargoArtifacts = mkOption {
          type = types.nullOr types.package;
          default = null;
          description = "Prebuilt crane deps cache to reuse instead of building one.";
        };
        cargoLock = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = "Explicit Cargo.lock for crane vendoring (wins over auto-detection).";
        };
        extraBuildInputs = mkOption {
          type = types.listOf types.package;
          default = [ ];
          description = "Extra buildInputs, appended to the Tauri system libraries.";
        };
        extraNativeBuildInputs = mkOption {
          type = types.listOf types.package;
          default = [ ];
          description = "Extra nativeBuildInputs, appended to pkg-config.";
        };
        tauriFeatures = mkOption {
          type = types.listOf types.str;
          default = [ "tauri/custom-protocol" ];
          description = ''
            Cargo features passed via --features. Defaults to the custom-protocol
            feature Tauri v2 release builds require; set to [ ] to omit the flag
            entirely (e.g. when features are driven from Cargo.toml).
          '';
        };
        extraTauriConfig = mkOption {
          type = types.attrs;
          default = { };
          description = ''
            Extra tauri.conf.json keys, deep-merged with the managed config. The
            managed build.frontendDist (the `frontend` derivation) and
            build.beforeBuildCommand WIN over values set here, so the embedded
            assets always track `frontend`; all other keys are caller-controlled.
          '';
        };
        cargoRoot = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            Closest common ancestor of src-tauri/ and any sibling path-dep crates.
            Defaults to src-tauri/. Must share the same on-disk root as src.
          '';
        };
        extraFileset = mkOption {
          # filesets are an opaque lib value; `raw` stores it without inspection.
          type = types.nullOr types.raw;
          default = null;
          description = ''
            Extra app-only sources the app needs at compile time (SQL migrations,
            JSON fixtures). Must be non-.rs and non-.toml: crane already keeps all
            .toml in both sources, so a .toml here is redundant and still busts
            the deps cache on edit.
          '';
        };
        craneArgs = mkOption {
          type = types.attrsOf types.anything;
          default = { };
          description = ''
            Escape hatch for arbitrary crane / mkDerivation args (doCheck, env
            vars, hooks, ...). Use this rather than passing such args at the top
            level, which the module checker rejects as unknown options.
            Phase/install-shaping keys are stripped before the deps build and
            from commonArgs — customise the deps build via cargoArtifactsArgs.
          '';
        };
        cargoArtifactsArgs = mkOption {
          type = types.attrsOf types.anything;
          default = { };
          description = ''
            crane / mkDerivation args applied to the cargoArtifacts (deps)
            derivation only, merged after the app-phase keys are stripped. The
            explicit channel for customising the dependency build — crane
            honors e.g. buildPhaseCargoCommand there.
          '';
        };
      };
    };

  # _module.check defaults to true: an unknown top-level attribute (e.g. a typo
  # like `pnmae`) is rejected with a clear error, and a wrong type (e.g.
  # `version = 1`) fails with the option path and expected type.
  cfg =
    (lib.evalModules {
      modules = [ optionsModule ] ++ lib.toList args;
    }).config;

  inherit (cfg)
    pname
    version
    src
    frontend
    binaryName
    cargoExtraArgs
    cargoArtifacts
    cargoArtifactsArgs
    extraBuildInputs
    extraNativeBuildInputs
    tauriFeatures
    extraTauriConfig
    cargoRoot
    extraFileset
    ;

  tauriSrc = src + "/src-tauri";
  actualCargoRoot = if cargoRoot != null then cargoRoot else tauriSrc;
  isMonorepo = toString actualCargoRoot != toString tauriSrc;

  # Path of the tauri crate relative to cargoRoot. Throws if cargoRoot isn't an
  # ancestor of ${src}/src-tauri — otherwise lib.removePrefix would silently
  # return the full absolute path and the build would fail confusingly. The
  # compared strings are toString-evaluated absolute paths, so src and cargoRoot
  # must share the same on-disk root (both local or both from the same store
  # derivation).
  tauriSubdir =
    if !isMonorepo then
      "."
    else if lib.hasPrefix (toString actualCargoRoot + "/") (toString tauriSrc) then
      lib.removePrefix (toString actualCargoRoot + "/") (toString tauriSrc)
    else
      throw ''
        buildTauriApp: ${toString tauriSrc} is not under cargoRoot (${toString actualCargoRoot}).
        Set cargoRoot to a directory that contains src-tauri/. If src and
        cargoRoot come from different roots (e.g. one is a store path and
        the other is a local path), derive cargoRoot from src instead
        (e.g. `cargoRoot = src;`).'';

  cargoSources = craneLib.fileset.commonCargoSources actualCargoRoot;

  tauriExtraFiles = lib.fileset.unions [
    (tauriSrc + "/tauri.conf.json")
    (tauriSrc + "/icons")
    (lib.fileset.maybeMissing (tauriSrc + "/capabilities"))
  ];

  appFileset = lib.fileset.unions (
    [
      cargoSources
      tauriExtraFiles
    ]
    ++ lib.optional (extraFileset != null) extraFileset
  );

  appSrc = lib.fileset.toSource {
    root = actualCargoRoot;
    fileset = appFileset;
  };

  depsSrc = lib.fileset.toSource {
    root = actualCargoRoot;
    fileset = lib.fileset.difference cargoSources (
      lib.fileset.fileFilter (file: lib.hasSuffix ".rs" file.name) actualCargoRoot
    );
  };

  tauriBuildInputs = [
    pkgs.openssl
  ]
  ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
    pkgs.webkitgtk_4_1
    pkgs.libsoup_3
    pkgs.gtk3
    pkgs.glib
    pkgs.cairo
    pkgs.pango
    pkgs.gdk-pixbuf
    pkgs.atk
    pkgs.librsvg
    pkgs.libayatana-appindicator
  ]
  ++ lib.optionals pkgs.stdenv.hostPlatform.isDarwin [
    pkgs.libiconv
  ];

  relocateCachedTauriPaths = ''
    derivationName="''${name:-${pname}}"
    relocationFiles=0
    relocationMatches=0
    relocationRewrites=0

    log_relocation() {
      printf '%s %s\n' 'tauri-relocate:' "$*" >&2
    }

    while IFS= read -r -d "" file; do
      relocationFiles=$((relocationFiles + 1))
      while IFS= read -r oldPath; do
        if [ -z "$oldPath" ]; then
          continue
        fi

        oldSourceRoot="''${oldPath%/target/*}"

        if [ -z "$oldSourceRoot" ]; then
          continue
        fi

        relocationMatches=$((relocationMatches + 1))

        if [ -n "$oldSourceRoot" ] && [ "$oldSourceRoot" != "$PWD" ] && grep -Fq "$oldSourceRoot" "$file"; then
          substituteInPlace "$file" --replace-fail "$oldSourceRoot" "$PWD"
          relocationRewrites=$((relocationRewrites + 1))
          log_relocation "derivation=$derivationName file=$file old_root=$oldSourceRoot new_root=$PWD"
        fi
      done < <(grep -aoE "/[^[:space:]'\"]+/source/target/[^[:space:]'\"]+" "$file" | sort -u || true)
    done < <(
      find target/release/build -type f \( -name output -o -name '*-permission-files' \) -print0 2>/dev/null || true
    )

    log_relocation "derivation=$derivationName summary files=$relocationFiles matches=$relocationMatches rewrites=$relocationRewrites"
  '';

  # `cargo tauri build` rejects --manifest-path (it discovers src-tauri/ from
  # CWD), but every other cargo command run from cargoRoot in monorepo mode needs
  # it. So we carry two flavors of extra args. If the caller already supplied
  # --manifest-path via cargoExtraArgs we skip injection.
  callerSetManifestPath = lib.hasInfix "--manifest-path" cargoExtraArgs;

  # escapeShellArg the path so a space/metachar in an intermediate directory
  # survives crane's unquoted interpolation. It is a no-op for an ordinary
  # src-tauri/Cargo.toml, so the emitted string is unchanged for the common case.
  manifestPathArg = lib.optionalString (
    isMonorepo && !callerSetManifestPath
  ) "--manifest-path ${lib.escapeShellArg "${tauriSubdir}/Cargo.toml"}";

  tauriFeaturesArg = lib.optionalString (
    tauriFeatures != [ ]
  ) "--features ${lib.concatStringsSep "," tauriFeatures}";

  joinArgs = parts: lib.concatStringsSep " " (lib.filter (s: s != "") parts);

  # The two flavors differ only by the injected --manifest-path.
  baseCargoExtraArgs = [
    tauriFeaturesArg
    cargoExtraArgs
  ];

  tauriBuildCargoExtraArgs = joinArgs baseCargoExtraArgs;

  sharedCargoExtraArgs = joinArgs (baseCargoExtraArgs ++ [ manifestPathArg ]);

  # Pin crane's vendoring to the tauri crate's own Cargo.lock when one exists
  # there (the "loose path-deps" layout). In a true cargo workspace only the
  # workspace root has a Cargo.lock, so we leave crane on its default. A
  # caller-supplied cargoLock always wins — see sharedArgs.
  monorepoCargoLock = lib.optionalAttrs (
    isMonorepo && builtins.pathExists (tauriSrc + "/Cargo.lock")
  ) { cargoLock = tauriSrc + "/Cargo.lock"; };

  # `cargo tauri build` chdirs into ${tauriSubdir}, so a relative
  # CARGO_TARGET_DIR would resolve differently in the deps build (CWD =
  # cargoRoot) and the app build, breaking every cached fingerprint. Pin an
  # absolute target dir so both builds share one target/ tree.
  exportAbsoluteCargoTargetDir = lib.optionalString isMonorepo ''
    export CARGO_TARGET_DIR="$PWD/target"
  '';

  sharedArgs =
    monorepoCargoLock
    // cfg.craneArgs
    # The dedicated cargoLock option wins over any cargoLock buried in craneArgs.
    // lib.optionalAttrs (cfg.cargoLock != null) { cargoLock = cfg.cargoLock; }
    // {
      inherit pname version;
      strictDeps = true;
      cargoExtraArgs = sharedCargoExtraArgs;
      nativeBuildInputs = [
        pkgs.pkg-config
      ]
      ++ (cfg.craneArgs.nativeBuildInputs or [ ])
      ++ extraNativeBuildInputs;
      buildInputs = tauriBuildInputs ++ (cfg.craneArgs.buildInputs or [ ]) ++ extraBuildInputs;
      preConfigure = lib.concatStringsSep "\n" [
        exportAbsoluteCargoTargetDir
        (cfg.craneArgs.preConfigure or "")
        relocateCachedTauriPaths
      ];
    };

  # Keys that describe how to build and install the *app*. They must not reach
  # buildDepsOnly: crane honors a caller-supplied buildPhaseCargoCommand /
  # installPhaseCommand there, and mkCargoDerivation honors buildPhase /
  # installPhase ahead of either. Left in sharedArgs they replace the dependency
  # build with the app's commands, so the deps derivation succeeds having
  # compiled nothing and the cache it publishes is empty.
  # buildCommand, buildCommandPath and phases are the stdenv-level equivalents:
  # genericBuild sources/evals the first two and returns before the phase list is
  # ever built, and phases can simply omit buildPhase. The dont* flags have the
  # same effect per phase — genericBuild's phase loop skips any phase whose
  # dont* flag is set — and buildDepsOnly force-sets doInstallCargoArtifacts, so
  # an empty target dir is still published. cargoBuildCommand / cargoCheckCommand
  # are crane's command slots: buildDepsOnly's default buildPhaseCargoCommand
  # interpolates them, so a non-building value empties the cache the same way.
  appOnlyCraneKeys = [
    "buildCommand"
    "buildCommandPath"
    "buildPhase"
    "buildPhaseCargoCommand"
    "cargoBuildCommand"
    "cargoCheckCommand"
    "cargoTestCommand"
    "checkPhase"
    "checkPhaseCargoCommand"
    "doInstallCargoArtifacts"
    "dontBuild"
    "dontCheck"
    "dontConfigure"
    "dontDist"
    "dontFixup"
    "dontInstall"
    "dontPatch"
    "dontUnpack"
    "fixupPhase"
    "installPhase"
    "installPhaseCommand"
    "meta"
    "outputs"
    "phases"
    "postInstall"
    "preFixup"
  ];

  appArgs = sharedArgs // {
    src = appSrc;
  };

  # The public attrset consumers derive their checks from (the README's clippy
  # recipe). Stripped of the same keys: a checks derivation honors buildCommand /
  # phases / buildPhase exactly like buildDepsOnly does, so a composed check
  # could pass having compiled nothing.
  commonArgs = builtins.removeAttrs appArgs appOnlyCraneKeys;

  resolvedCargoArtifacts =
    if cargoArtifacts != null then
      cargoArtifacts
    else
      craneLib.buildDepsOnly (
        (builtins.removeAttrs sharedArgs appOnlyCraneKeys)
        // {
          src = depsSrc;
        }
        // cfg.cargoArtifactsArgs
      );

  tauriConfig = builtins.toJSON (
    lib.recursiveUpdate extraTauriConfig {
      build = {
        frontendDist = "${frontend}";
        beforeBuildCommand = "";
      };
    }
  );

  app = craneLib.mkCargoDerivation (
    appArgs
    // {
      cargoArtifacts = resolvedCargoArtifacts;
      TAURI_CONFIG = tauriConfig;

      nativeBuildInputs = appArgs.nativeBuildInputs ++ [ pkgs.cargo-tauri ];

      buildPhaseCargoCommand = ''
        cargo tauri build --no-bundle \
          ${tauriBuildCargoExtraArgs} \
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
    # Path of the tauri crate relative to cargoRoot ("." outside monorepo mode).
    # Exposed so consumers can target the tauri crate from cargoRoot. cargo-deny
    # runs as `cargo deny check` and finds the manifest from CWD, so it wants
    # cargoExtraArgs = "" (the top-level `cargo` rejects --features/--manifest-path).
    tauriSubdir
    ;
  cargoArtifacts = resolvedCargoArtifacts;
}
