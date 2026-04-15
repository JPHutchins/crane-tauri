#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$REPO_ROOT/fixtures/tauri-app"
SYSTEM="$(nix eval --raw --impure --expr builtins.currentSystem)"
NIX_BUILD_ARGS=(-L --show-trace --no-link)

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

print_command() {
  printf '+' >&2
  printf ' %q' "$@" >&2
  printf '\n' >&2
}

run_verbose() {
  print_command "$@"
  "$@"
}

capture_verbose() {
  local log_file="$1"
  shift

  print_command "$@"
  "$@" 2>&1 | tee "$log_file"
}

cargo_artifacts_out_path() {
  run_verbose nix eval --raw ".#packages.$SYSTEM.cargoArtifacts.outPath"
}

commit_all() {
  git add -A
  git -c user.name=test -c user.email=test@test commit -qm "$1"
}

assert_log_contains() {
  local pattern="$1"
  local log_file="$2"
  local description="$3"

  if grep -Eq "$pattern" "$log_file"; then
    pass "$description"
  else
    fail "$description"
  fi
}

assert_log_lacks() {
  local pattern="$1"
  local log_file="$2"
  local description="$3"

  if grep -Eq "$pattern" "$log_file"; then
    fail "$description"
  else
    pass "$description"
  fi
}

echo "=== Test 1: Build fixture app ==="
app_out=$(run_verbose nix build "${NIX_BUILD_ARGS[@]}" "$FIXTURE" --print-out-paths)
test -x "$app_out/bin/tauri-app" || fail "binary not found or not executable"
pass "fixture binary builds"

echo "=== Test 2: Frontend assets embedded ==="
grep -qc "vite.svg" "$app_out/bin/tauri-app" || fail "frontend not embedded in binary"
pass "frontend assets are embedded"

echo "=== Test 3: Frontend builds independently ==="
frontend_out=$(run_verbose nix build "${NIX_BUILD_ARGS[@]}" "$FIXTURE#frontend" --print-out-paths)
test -f "$frontend_out/index.html" || fail "frontend index.html missing"
test -d "$frontend_out/assets" || fail "frontend assets/ missing"
pass "frontend builds independently"

echo "=== Test 4: Fresh consumer project builds ==="

WORKDIR=$(mktemp -d)
LIB_SNAPSHOT=$(mktemp -d)
LOG_DIR="${CI_LOG_DIR:-$WORKDIR}"
trap 'rm -rf "$WORKDIR" "$LIB_SNAPSHOT"' EXIT
mkdir -p "$LOG_DIR"
BUILD1_LOG="$LOG_DIR/build-initial.log"
BUILD2_LOG="$LOG_DIR/build-source-change.log"
BUILD3_LOG="$LOG_DIR/build-manifest-change.log"

for path in flake.nix lib templates; do
  cp -r "$REPO_ROOT/$path" "$LIB_SNAPSHOT/$path"
done

for path in src public package.json package-lock.json tsconfig.json tsconfig.node.json vite.config.ts index.html; do
  cp -r "$FIXTURE/$path" "$WORKDIR/$path"
done

mkdir -p "$WORKDIR/src-tauri"

for path in Cargo.lock Cargo.toml build.rs tauri.conf.json capabilities icons src; do
  cp -r "$FIXTURE/src-tauri/$path" "$WORKDIR/src-tauri/$path"
done

rm -f "$WORKDIR/flake.nix" "$WORKDIR/flake.lock"

cat > "$WORKDIR/flake.nix" << 'FLAKE_NIX'
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    crane.url = "github:ipetkov/crane";
    crane-tauri = {
      url = "CRANE_TAURI_URL_PLACEHOLDER";
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
          pname = "test-frontend";
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
        packages = {
          default = tauri.app;
          cargoArtifacts = tauri.cargoArtifacts;
        };

        checks.clippy = craneLib.cargoClippy (
          tauri.commonArgs
          // {
            cargoArtifacts = tauri.cargoArtifacts;
            cargoClippyExtraArgs = "--all-targets -- -D warnings";
            TAURI_CONFIG = tauri.tauriConfig;
          }
        );
      }
    );
}
FLAKE_NIX

sed -i "s|CRANE_TAURI_URL_PLACEHOLDER|path:$LIB_SNAPSHOT|" "$WORKDIR/flake.nix"

cd "$WORKDIR"
git init -q
commit_all "init"

echo "  Building initial (deps + app)..."
capture_verbose "$BUILD1_LOG" nix build "${NIX_BUILD_ARGS[@]}" .#default

consumer_out=$(run_verbose nix path-info .#default)
test -x "$consumer_out/bin/tauri-app" || fail "consumer binary not found"
grep -qc "vite.svg" "$consumer_out/bin/tauri-app" || fail "consumer frontend not embedded"
pass "fresh consumer project builds with embedded frontend"

app_out_before="$consumer_out"

deps_hash_before=$(cargo_artifacts_out_path)

echo "=== Test 5: Dep caching survives Rust source changes ==="

echo "  Modifying Rust source..."
sed -i 's/Hello, {}!/Goodbye, {}!/' src-tauri/src/lib.rs
commit_all "modify source"

echo "  Rebuilding after source change..."
capture_verbose "$BUILD2_LOG" nix build "${NIX_BUILD_ARGS[@]}" .#default

app_out_after_source=$(run_verbose nix path-info .#default)
deps_hash_after_source=$(cargo_artifacts_out_path)

if [ "$app_out_before" != "$app_out_after_source" ]; then
  pass "app output store path changed after Rust source modification ($app_out_after_source)"
else
  fail "app output store path did not change after Rust source modification"
fi

if [ "$deps_hash_before" = "$deps_hash_after_source" ]; then
  pass "cargoArtifacts store path unchanged after source modification ($deps_hash_before)"
else
  fail "cargoArtifacts changed: before=$deps_hash_before after=$deps_hash_after_source"
fi

assert_log_lacks 'tauri-app-deps-0\.1\.0\.drv' "$BUILD2_LOG" "deps derivation not rebuilt after Rust source change"

echo "=== Test 6: Dep caching invalidates on Cargo manifest changes ==="

echo "  Modifying Cargo.toml..."
sed -i 's/features = \["derive"\]/features = ["derive", "rc"]/' src-tauri/Cargo.toml
commit_all "modify manifest"

echo "  Rebuilding after manifest change..."
capture_verbose "$BUILD3_LOG" nix build "${NIX_BUILD_ARGS[@]}" .#default

deps_hash_after_manifest=$(cargo_artifacts_out_path)

if [ "$deps_hash_before" != "$deps_hash_after_manifest" ]; then
  pass "cargoArtifacts store path changed after Cargo manifest modification ($deps_hash_after_manifest)"
else
  fail "cargoArtifacts did not change after Cargo manifest modification"
fi

echo ""
echo "=== All integration tests passed ==="
