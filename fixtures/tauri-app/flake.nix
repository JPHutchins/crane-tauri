{
  description = "Tauri app";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    crane.url = "github:ipetkov/crane";
    crane-tauri = {
      url = "path:../..";
      inputs = { };
    };
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
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
          pname = "tauri-app-frontend";
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

          npmDepsHash = "sha256-6llRWm8jwaIPSzTPTI1tBoGRknuvEAUS9YJnE5SSkb4=";

          installPhase = ''
            runHook preInstall
            cp -r dist $out
            runHook postInstall
          '';
        };

        tauri = crane-tauri.lib.buildTauriApp { inherit pkgs craneLib; } {
          pname = "tauri-app";
          version = "0.1.0";
          src = ./.;
          inherit frontend;
        };
      in
      {
        checks = {
          inherit (tauri) app;

          clippy = craneLib.cargoClippy (
            tauri.commonArgs
            // {
              cargoArtifacts = tauri.cargoArtifacts;
              cargoClippyExtraArgs = "--all-targets -- -D warnings";
              TAURI_CONFIG = tauri.tauriConfig;
            }
          );

          fmt = craneLib.cargoFmt { src = tauri.commonArgs.src; };

          nixfmt = pkgs.runCommand "nixfmt-check" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            nixfmt --check ${self}/*.nix
            touch $out
          '';
        };

        packages = {
          inherit frontend;
          default = tauri.app;
        };

        devShells.default = craneLib.devShell {
          checks = self.checks.${system};
        };
      }
    );
}
