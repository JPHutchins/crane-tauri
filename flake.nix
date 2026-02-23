{
  description = "Tauri app — Rust crate build";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    crane.url = "github:ipetkov/crane";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      crane,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib;

        craneLib = crane.mkLib pkgs;

        src = lib.fileset.toSource {
          root = ./src-tauri;
          fileset = lib.fileset.unions [
            (craneLib.fileset.commonCargoSources ./src-tauri)
            ./src-tauri/tauri.conf.json
            ./src-tauri/icons
            ./src-tauri/capabilities
          ];
        };

        commonArgs = {
          inherit src;
          strictDeps = true;

          nativeBuildInputs = with pkgs; [
            pkg-config
          ];

          buildInputs =
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
        };

        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        tauri-app = craneLib.buildPackage (
          commonArgs
          // {
            inherit cargoArtifacts;
          }
        );
      in
      {
        checks = {
          inherit tauri-app;

          clippy = craneLib.cargoClippy (
            commonArgs
            // {
              inherit cargoArtifacts;
              cargoClippyExtraArgs = "--all-targets -- -D warnings";
            }
          );

          fmt = craneLib.cargoFmt { inherit src; };

          nixfmt = pkgs.runCommand "nixfmt-check" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            nixfmt --check ${self}/*.nix
            touch $out
          '';
        };

        packages.default = tauri-app;

        devShells.default = craneLib.devShell {
          checks = self.checks.${system};
        };
      }
    );
}
