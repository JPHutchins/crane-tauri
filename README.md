# crane-tauri

Build Tauri apps with Nix while reusing `crane` for Cargo dependency caching.

- build your frontend as a normal Nix derivation
- pass that derivation into `buildTauriApp`
- use `tauri.app` as the final package
- reuse `tauri.cargoArtifacts` for clippy and other checks

## Quick Start

If you just want a starter project, use the template:

```bash
nix flake init -t github:jphutchins/crane-tauri
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

For a more complete example with checks, see [templates/default/flake.nix](./templates/default/flake.nix).
