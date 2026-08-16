# crane-tauri

Build Tauri apps with Nix while reusing `crane` for Cargo dependency caching.

- build your frontend as a normal Nix derivation
- pass that derivation into `buildTauriApp`
- use `tauri.app` as the final package
- reuse `tauri.cargoArtifacts` for clippy and other checks

## Quick Start

If you just want a starter project, use the template:

```bash
nix flake init -t github:JPHutchins/crane-tauri
```

## Minimal Example

```nix
{
	inputs = {
		nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
		crane.url = "github:ipetkov/crane";
		crane-tauri.url = "github:JPHutchins/crane-tauri";
		flake-utils.url = "github:numtide/flake-utils";
	};

	outputs =
		{
			nixpkgs,
			crane,
			crane-tauri,
			flake-utils,
			...
		}:
		flake-utils.lib.eachDefaultSystem (
			system:
			let
				pkgs = nixpkgs.legacyPackages.${system};
				inherit (pkgs) lib;
				craneLib = crane.mkLib pkgs;

				frontend = pkgs.buildNpmPackage {
					pname = "my-app-frontend";
					version = "0.1.0";

					src = lib.fileset.toSource {
						root = ./.;
						fileset = lib.fileset.unions [
							./package.json
							./package-lock.json
							./tsconfig.json
							./tsconfig.node.json
							./vite.config.ts
							./index.html
							./src
							./public
						];
					};

					npmDepsHash = "sha256-...";

					installPhase = ''
						runHook preInstall
						cp -r dist $out
						runHook postInstall
					'';
				};

				tauri = crane-tauri.lib.buildTauriApp { inherit pkgs craneLib; } {
					pname = "my-app";
					version = "0.1.0";
					src = ./.;
					inherit frontend;
				};
			in
			{
				packages.default = tauri.app;

				checks = {
					inherit (tauri) app;

					# `nix flake check` runs values under `checks`.
					clippy = craneLib.cargoClippy (
						tauri.commonArgs
						// {
							# Reuse the dependency cache produced by `buildTauriApp`
							# so clippy does not rebuild all Rust dependencies.
							cargoArtifacts = tauri.cargoArtifacts;
							cargoClippyExtraArgs = "--all-targets -- -D warnings";
							TAURI_CONFIG = tauri.tauriConfig;
						}
					);
				};
			}
		);
}
```

## Notes

- `src` should point at the repo root that contains `src-tauri`
- `frontend` should be the built web assets, not the source tree
- `tauri.app` is the final binary package
- `tauri.cargoArtifacts` is the reusable crane dependency cache derivation
- `tauri.commonArgs`, `tauri.tauriConfig`, and `tauri.tauriSubdir` are exposed
  for composing extra checks (clippy, deny) against the same source and config
- `binaryName` defaults to `pname`, but the installed binary is named by cargo
  (`[package].name` in `src-tauri/Cargo.toml`). Set `binaryName` when they
  differ, or the build fails at the install step with `failed to locate built
  binary`
- to add system dependencies, pass `extraNativeBuildInputs` / `extraBuildInputs`
  (appended to `pkg-config` and the Tauri system libraries); other crane /
  `mkDerivation` args go via `craneArgs`
- phase/install-shaping `craneArgs` keys (`buildPhase`, `installPhase*`,
  `checkPhase*`, `buildCommand`, `phases`, `dont*`, ...) are stripped before
  the deps build and from `tauri.commonArgs`, so they cannot replace the
  dependency build or hollow out a composed check; customise the deps build
  via `cargoArtifactsArgs`, which is applied to `buildDepsOnly` and honors
  crane's `buildPhaseCargoCommand` there
- `tauri/custom-protocol` is injected by default (required for Tauri v2 release
  builds); override the feature set via `tauriFeatures`, and your
  `cargoExtraArgs` is appended
- `tauriBuild` / `tauriInstall` replace the build and install phase commands:
  closures over the computed context (`configFlag`, `cargoExtraArgs`,
  `frontendDist`, `tauriSubdir`, `pname`, `version`, `binaryName`) that must
  accept `...` — the context may gain keys. A caller closure replaces the
  default rather than appending to it, and `craneArgs.buildPhase` /
  `installPhase` still take precedence over the closures on the app

  ```nix
  tauriBuild = { configFlag, cargoExtraArgs, ... }:
    "cargo tauri build -b deb ${cargoExtraArgs} ${configFlag}";
  ```

For a more complete example with checks, see [templates/default/flake.nix](./templates/default/flake.nix).

## Monorepo Support

If `src-tauri/Cargo.toml` depends on sibling crates by relative path:

```toml
[dependencies]
my_logger = { path = "../my_logger" }
```

then the default fileset root (`${src}/src-tauri`) won't reach those siblings
and the build will fail to find them. Pass `cargoRoot` to widen the root to a
common ancestor of `src-tauri/` and the path-dep crates:

```nix
tauri = crane-tauri.lib.buildTauriApp { inherit pkgs craneLib; } {
  pname = "my-app";
  version = "0.1.0";
  src = ./.;
  cargoRoot = ./.;  # closest ancestor of src-tauri/ and ../my_logger
  inherit frontend;
};
```

Pick the *closest* common ancestor. Setting `cargoRoot` to the entire repo
pulls every `Cargo.toml` and `*.rs` in the tree into the build inputs and
inflates the dependency cache, invalidating it on changes to unrelated crates.

Non-manifest files the app needs at compile time (SQL migrations, JSON
fixtures, etc.) can be added via `extraFileset`. These are only added to the
app build, not the dependency build, so they don't invalidate `cargoArtifacts`
when they change:

```nix
tauri = crane-tauri.lib.buildTauriApp { inherit pkgs craneLib; } {
  pname = "my-app";
  version = "0.1.0";
  src = ./.;
  cargoRoot = ./.;
  extraFileset = lib.fileset.unions [
    ./src-tauri/migrations
  ];
  inherit frontend;
};
```

> **`.toml` files are not candidates for `extraFileset`.** crane's
> `commonCargoSources` keeps every `.toml` under `cargoRoot` in *both* the app
> and dependency sources (they commonly configure cargo tooling), so editing
> one always busts `cargoArtifacts` and passing it through `extraFileset` has no
> effect. In monorepo mode this means an edit to any `deny.toml`,
> `rustfmt.toml`, `.cargo/config.toml`, etc. anywhere under `cargoRoot`
> invalidates the dependency cache.

### Caveats

- **Lockfile**: monorepo mode prefers `${src}/src-tauri/Cargo.lock` if it
  exists (the "loose path-deps" layout where each crate has its own lockfile)
  and otherwise falls back to crane's default of using whatever `Cargo.lock`
  lives at `cargoRoot` (cargo workspaces). If neither matches your layout,
  pass `cargoLock` explicitly — a caller-supplied value always wins.

- **`--manifest-path` injection**: monorepo mode adds
  `--manifest-path src-tauri/Cargo.toml` to `commonArgs.cargoExtraArgs` so
  cargo commands run from `cargoRoot` know which manifest to target. It is
  injected at the *top-level* `cargo` position (`cargo … ${cargoExtraArgs}
  <subcommand>`), which only some subcommands accept. `cargo-deny`, for
  instance, runs as `cargo deny check` and discovers the manifest from the
  working directory — the top-level `cargo` rejects both `--features` and
  `--manifest-path`, so it needs an empty `cargoExtraArgs`:

  ```nix
  deny = craneLib.cargoDeny (
    tauri.commonArgs // {
      cargoExtraArgs = "";
    }
  );
  ```

  To target a specific crate's manifest in a monorepo, pass it via
  `cargoDenyExtraArgs` (which lands after the `deny` subcommand), not
  `cargoExtraArgs`; `tauri.tauriSubdir` gives the tauri crate's path relative to
  `cargoRoot`.

  If a caller passes their own `--manifest-path` via `cargoExtraArgs` to
  `buildTauriApp` (unusual but valid for an exotic layout), injection is
  skipped so the caller's flag wins.

- **`cargoRoot` and `src` must share the same on-disk root**: the
  monorepo-detection check compares `toString`-evaluated paths. If `src` is
  a store path (e.g. from `fetchFromGitHub`) and `cargoRoot` is a local
  source path (or vice versa) the prefix check fails and the build is
  rejected with a clear error. Derive `cargoRoot` from `src`
  (e.g. `cargoRoot = src;`) when the project doesn't live at a fixed local
  path.

- **No automatic GTK wrapping**: the lib still leaves binary wrapping
  (`wrapGAppsHook3`, etc.) to consumers in a separate derivation. Adding it
  to the shared inputs perturbs `PKG_CONFIG_PATH` and invalidates every
  `-sys` crate fingerprint.
