{
  pkgs,
  craneLib,
}:

{
  pname,
  version,
  src,
  frontend,
  # Name of the compiled binary to install from target/release. Defaults to
  # pname, but pname is the *Nix* package name while the on-disk binary is named
  # by cargo (`[package].name` / `[[bin]]` in src-tauri/Cargo.toml). Set this
  # explicitly whenever pname differs from the cargo bin name, otherwise the
  # install phase fails late with "failed to locate built binary".
  binaryName ? pname,
  cargoExtraArgs ? "",
  cargoArtifacts ? null,
  extraBuildInputs ? [ ],
  extraNativeBuildInputs ? [ ],
  # Extra tauri.conf.json keys, deep-merged OVER the managed config (caller
  # wins). The lib manages `build.frontendDist` (set to the `frontend`
  # derivation) and `build.beforeBuildCommand` (cleared); setting either of those
  # here overrides them and decouples the embedded assets from `frontend`, so
  # don't.
  extraTauriConfig ? { },
  # Closest common ancestor of `${src}/src-tauri` and any sibling crates the
  # tauri project depends on via `{ path = "..." }`. Defaults to
  # `${src}/src-tauri`. Pick the tightest ancestor that covers the path deps —
  # widening to the whole repo pulls every Cargo.toml/*.rs in the tree into
  # the build inputs and inflates the deps cache. Must share the same on-disk
  # root as `src` (i.e. derive from `src` or from the same source tree); a
  # mix of a store-path `src` and a local-path `cargoRoot` (or vice versa)
  # will be rejected because the two paths can't be safely related.
  cargoRoot ? null,
  # Additional fileset entries unioned into the app source only, not the deps
  # source. Use for non-manifest, non-`.toml` inputs the app needs at compile
  # time (SQL migrations, JSON fixtures); keeping them out of depsSrc preserves
  # the deps cache across content-only edits. NOTE: `.toml` files anywhere under
  # cargoRoot are always in BOTH sources (crane's commonCargoSources keeps every
  # `.toml` for cargo tooling), so editing one still busts the deps cache and
  # passing one here has no effect.
  extraFileset ? null,
  ...
}@origArgs:

let
  inherit (pkgs) lib;

  # The attrs this lib consumes or overrides itself, stripped so they don't leak
  # into crane's derivations: the named formals above (minus pname/version/src,
  # which crane needs and we forward) plus the build-input and phase-hook attrs
  # set in `sharedArgs`. nativeBuildInputs and buildInputs are removed here and
  # merged back in so a caller value is appended to ours instead of silently
  # overriding it; the phase hooks are lib-owned (the app sets them explicitly),
  # and stripping them keeps a caller value from taking effect in only the deps
  # build.
  cleanedArgs = builtins.removeAttrs origArgs [
    "frontend"
    "binaryName"
    "cargoExtraArgs"
    "cargoArtifacts"
    "extraBuildInputs"
    "extraNativeBuildInputs"
    "extraTauriConfig"
    "cargoRoot"
    "extraFileset"
    "nativeBuildInputs"
    "buildInputs"
    "buildPhaseCargoCommand"
    "installPhaseCommand"
    "doInstallCargoArtifacts"
  ];

  tauriSrc = src + "/src-tauri";
  actualCargoRoot = if cargoRoot != null then cargoRoot else tauriSrc;
  isMonorepo = toString actualCargoRoot != toString tauriSrc;

  # Path of the tauri crate relative to cargoRoot. Used to construct
  # `--manifest-path` for non-tauri cargo commands run from cargoRoot. Throws
  # if a caller sets cargoRoot to something that isn't an ancestor of
  # ${src}/src-tauri — otherwise `lib.removePrefix` would silently return the
  # full absolute path and the build would fail confusingly downstream.
  # The compared strings are `toString`-evaluated absolute paths, so `src`
  # and `cargoRoot` must share the same on-disk root (both local paths or
  # both from the same store derivation). Mixing a store-path `src` with a
  # local `cargoRoot` (or vice versa) will hit this branch.
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

  # `cargo tauri build` rejects --manifest-path — it does its own src-tauri/
  # discovery from CWD — but every other cargo command run from cargoRoot in
  # monorepo mode needs --manifest-path to find the tauri Cargo.toml. So we
  # carry two flavors of extra args. Consumers composing `commonArgs` with a
  # tool that also rejects --manifest-path (e.g. cargo-deny) should compose
  # their own args using the returned `tauriSubdir`.
  #
  # If the caller already supplied --manifest-path via `cargoExtraArgs` we
  # skip injection — otherwise cargo would see two flags and silently use the
  # last one (ours), overriding the caller's choice.
  callerSetManifestPath = lib.hasInfix "--manifest-path" cargoExtraArgs;
  # Escape the path so a space or shell metachar in an intermediate directory
  # (cargoRoot..src-tauri) survives crane's unquoted interpolation of
  # cargoExtraArgs into its build command. escapeShellArg is a no-op for an
  # ordinary `src-tauri/Cargo.toml`, so the emitted string is unchanged for the
  # common case.
  manifestPathArg = lib.optionalString (
    isMonorepo && !callerSetManifestPath
  ) "--manifest-path ${lib.escapeShellArg "${tauriSubdir}/Cargo.toml"}";

  joinArgs = parts: lib.concatStringsSep " " (lib.filter (s: s != "") parts);

  # The two flavors differ only by the injected --manifest-path: `cargo tauri
  # build` rejects it, every other cargo command run from cargoRoot needs it.
  baseCargoExtraArgs = [
    "--features tauri/custom-protocol"
    cargoExtraArgs
  ];

  tauriBuildCargoExtraArgs = joinArgs baseCargoExtraArgs;

  sharedCargoExtraArgs = joinArgs (baseCargoExtraArgs ++ [ manifestPathArg ]);

  # Pin crane's vendoring to the tauri crate's own Cargo.lock when one exists
  # there. In a "loose path-deps" layout each crate carries its own lockfile,
  # and without this override crane would vendor from whichever Cargo.lock
  # sits at the fileset root (cargoRoot) and feed the tauri build the wrong
  # dependency set. In a true cargo workspace only the workspace root has a
  # Cargo.lock, so we leave crane on its default (workspace lockfile at
  # cargoRoot). A caller-supplied `cargoLock` always wins — see `sharedArgs`.
  monorepoCargoLock = lib.optionalAttrs (
    isMonorepo && builtins.pathExists (tauriSrc + "/Cargo.lock")
  ) { cargoLock = tauriSrc + "/Cargo.lock"; };

  # `cargo tauri build` chdirs into ${tauriSubdir} before invoking cargo, so a
  # relative CARGO_TARGET_DIR would resolve to different absolute paths in the
  # deps build (CWD = cargoRoot) and the app build (CWD = cargoRoot/${tauriSubdir}).
  # Every cached crate's fingerprint check would then fail and the deps cache
  # would be useless. Set an absolute target dir at preConfigure so both
  # builds share the same target/ tree.
  exportAbsoluteCargoTargetDir = lib.optionalString isMonorepo ''
    export CARGO_TARGET_DIR="$PWD/target"
  '';

  # `monorepoCargoLock` is placed *before* `cleanedArgs` so a caller-supplied
  # `cargoLock` overrides it. This is the escape hatch for layouts the auto-
  # detect above doesn't cover.
  sharedArgs =
    monorepoCargoLock
    // cleanedArgs
    // {
      inherit pname version;
      strictDeps = true;
      cargoExtraArgs = sharedCargoExtraArgs;
      nativeBuildInputs = [
        pkgs.pkg-config
      ]
      ++ (origArgs.nativeBuildInputs or [ ])
      ++ extraNativeBuildInputs;
      buildInputs = tauriBuildInputs ++ (origArgs.buildInputs or [ ]) ++ extraBuildInputs;
      preConfigure = lib.concatStringsSep "\n" [
        exportAbsoluteCargoTargetDir
        (cleanedArgs.preConfigure or "")
        relocateCachedTauriPaths
      ];
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
    # Path of the tauri crate relative to cargoRoot ("." outside monorepo
    # mode). Exposed so consumers can target the tauri crate from cargoRoot.
    # cargo-deny runs as `cargo deny check` and finds the manifest from CWD, so
    # it wants `cargoExtraArgs = ""` — the top-level `cargo` invocation rejects
    # --features/--manifest-path. Use cargoDenyExtraArgs (or tauriSubdir) if you
    # must point it at the tauri crate explicitly.
    tauriSubdir
    ;
  cargoArtifacts = resolvedCargoArtifacts;
}
