{
  description = "Tauri app";

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

        commonArgs = {
          inherit src;
          strictDeps = true;
          cargoExtraArgs = "--features tauri/custom-protocol";

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

        tauriConfig = builtins.toJSON {
          build = {
            frontendDist = "${frontend}";
            beforeBuildCommand = "";
          };
        };

        tauri-app = craneLib.mkCargoDerivation (
          commonArgs
          // {
            inherit cargoArtifacts;
            TAURI_CONFIG = tauriConfig;

            nativeBuildInputs = commonArgs.nativeBuildInputs ++ [ pkgs.cargo-tauri ];

            buildPhaseCargoCommand = ''
              cargo tauri build --no-bundle \
                --config '${tauriConfig}'
            '';

            installPhaseCommand = ''
              mkdir -p $out/bin
              cp target/release/tauri-app $out/bin/
            '';
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
              TAURI_CONFIG = tauriConfig;
            }
          );

          fmt = craneLib.cargoFmt { inherit src; };

          nixfmt = pkgs.runCommand "nixfmt-check" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            nixfmt --check ${self}/*.nix
            touch $out
          '';
        };

        packages = {
          inherit frontend;
          default = tauri-app;
        };

        devShells.default = craneLib.devShell {
          checks = self.checks.${system};
        };
      }
    );
}
