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

replace_in_file() {
  local expression="$1"
  local file="$2"
  local temp_file

  temp_file=$(mktemp)
  sed "$expression" "$file" > "$temp_file"
  mv "$temp_file" "$file"
}

# Inserts the lines read from stdin after the first line matching the anchor
# regex, failing loudly if no line matches. Lines are taken verbatim (no
# shell/awk interpolation), so they can carry $ and ${...} for nix.
insert_after_anchor() {
  local anchor="$1"
  local target="$2"
  local lines_file

  lines_file=$(mktemp)
  cat > "$lines_file"
  awk -v anchor="$anchor" -v lines_file="$lines_file" '
    $0 ~ anchor && !done {
      print
      while ((getline line < lines_file) > 0) print line
      close(lines_file)
      done = 1
      next
    }
    { print }
    END {
      if (!done) {
        print "ERROR: did not find the anchor to insert after: " anchor > "/dev/stderr"
        exit 1
      }
    }
  ' "$target" > "$target.new"
  mv "$target.new" "$target"
  rm -f "$lines_file"
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
grep -qaFR "vite.svg" "$app_out/bin/tauri-app" || fail "frontend not embedded in binary"
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
BUILD4_LOG="$LOG_DIR/build-monorepo.log"
BUILD5_LOG="$LOG_DIR/build-monorepo-sibling-change.log"
BUILD6_LOG="$LOG_DIR/build-extrafileset-change.log"

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
          wrapped = tauri.wrappedApp;
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

replace_in_file "s|CRANE_TAURI_URL_PLACEHOLDER|path:$LIB_SNAPSHOT|" "$WORKDIR/flake.nix"

cd "$WORKDIR"
git init -q
commit_all "init"

echo "  Building initial (deps + app)..."
capture_verbose "$BUILD1_LOG" nix build "${NIX_BUILD_ARGS[@]}" .#default

consumer_out=$(run_verbose nix path-info .#default)
test -x "$consumer_out/bin/tauri-app" || fail "consumer binary not found"
grep -qaFR "vite.svg" "$consumer_out/bin/tauri-app" || fail "consumer frontend not embedded"
pass "fresh consumer project builds with embedded frontend"

app_out_before="$consumer_out"

deps_hash_before=$(cargo_artifacts_out_path)

echo "=== Test 5: Dep caching survives Rust source changes ==="

echo "  Modifying Rust source..."
replace_in_file 's/Hello, {}!/Goodbye, {}!/' src-tauri/src/lib.rs
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
replace_in_file 's/features = \["derive"\]/features = ["derive", "rc"]/' src-tauri/Cargo.toml
commit_all "modify manifest"

echo "  Rebuilding after manifest change..."
capture_verbose "$BUILD3_LOG" nix build "${NIX_BUILD_ARGS[@]}" .#default

deps_hash_after_manifest=$(cargo_artifacts_out_path)

if [ "$deps_hash_before" != "$deps_hash_after_manifest" ]; then
  pass "cargoArtifacts store path changed after Cargo manifest modification ($deps_hash_after_manifest)"
else
  fail "cargoArtifacts did not change after Cargo manifest modification"
fi

# Anchor the crane "-deps" naming convention that the assert_log_lacks oracle in
# Tests 5/8/9 depends on. Read straight from the derivation name (not a build
# log, which is cache-dependent — a warm local or remote cache serves the deps
# with no "building" line), so if crane ever renames the deps derivation this
# fails loudly and the assert_log_lacks pattern gets fixed instead of silently
# rotting into a vacuous pass.
deps_drv_name=$(basename "$(nix eval --raw ".#packages.$SYSTEM.cargoArtifacts.drvPath")")
case "$deps_drv_name" in
*-tauri-app-deps-0.1.0.drv)
  pass "deps derivation name '$deps_drv_name' matches the assert_log_lacks pattern" ;;
*)
  fail "deps derivation name '$deps_drv_name' no longer matches 'tauri-app-deps-0.1.0.drv' — update the assert_log_lacks pattern" ;;
esac

echo "=== Test 7: Monorepo mode with sibling path-dep crate ==="

echo "  Creating sibling crate..."
mkdir -p sibling-crate/src
cat > sibling-crate/Cargo.toml << 'EOF'
[package]
name = "sibling-crate"
version = "0.1.0"
edition = "2021"
EOF

cat > sibling-crate/src/lib.rs << 'EOF'
pub fn greeting(name: &str) -> String {
    format!("MONOREPO_SIBLING_MARKER greetings to {name}")
}
EOF

echo "  Adding path-dep to src-tauri/Cargo.toml..."
printf '\nsibling-crate = { path = "../sibling-crate" }\n' >> src-tauri/Cargo.toml

echo "  Rewriting src-tauri/src/lib.rs to call the sibling..."
cat > src-tauri/src/lib.rs << 'EOF'
// Pulled in from migrations/ via extraFileset (a *.sql file crane's
// commonCargoSources does not capture). include_str! makes a broken extraFileset
// fail at compile time, and embeds the marker into the binary for the test grep.
const MIGRATION: &str = include_str!("../../migrations/0001_init.sql");

#[tauri::command]
fn greet(name: &str) -> String {
    format!("{} {}", MIGRATION.trim(), sibling_crate::greeting(name))
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![greet])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
EOF

echo "  Surgically adding sibling-crate to Cargo.lock..."
awk '
  /^name = "tauri-app"$/ { in_tauri_app = 1 }
  in_tauri_app && /^ "tauri",$/ {
    print " \"sibling-crate\","
    inserted = 1
    in_tauri_app = 0
  }
  { print }
  END {
    if (!inserted) {
      print "ERROR: did not patch tauri-app deps array (Cargo.lock format drift?)" > "/dev/stderr"
      exit 1
    }
    print ""
    print "[[package]]"
    print "name = \"sibling-crate\""
    print "version = \"0.1.0\""
  }
' src-tauri/Cargo.lock > src-tauri/Cargo.lock.new
mv src-tauri/Cargo.lock.new src-tauri/Cargo.lock

echo "  Adding a non-cargo file consumed via include_str! to exercise extraFileset..."
# A *.sql file is NOT captured by crane's commonCargoSources (unlike *.rs and
# *.toml), so it reaches the app build ONLY through extraFileset. Because lib.rs
# include_str!s it, a broken/ignored extraFileset becomes a hard compile error
# rather than a silently-passing build.
mkdir -p migrations
printf 'EXTRA_FILESET_MARKER\n' > migrations/0001_init.sql

echo "  Updating flake.nix to set cargoRoot and extraFileset..."
awk '
  /src = \.\/\.;/ && !done {
    print
    print "          cargoRoot = ./.;"
    print "          extraFileset = ./migrations;"
    done = 1
    next
  }
  { print }
' flake.nix > flake.nix.new
mv flake.nix.new flake.nix

commit_all "convert to monorepo"

echo "  Building in monorepo mode..."
capture_verbose "$BUILD4_LOG" nix build "${NIX_BUILD_ARGS[@]}" .#default

monorepo_out=$(run_verbose nix path-info .#default)
test -x "$monorepo_out/bin/tauri-app" || fail "monorepo binary not found"
pass "monorepo build with sibling path-dep produces an executable binary"

grep -qaFR "MONOREPO_SIBLING_MARKER" "$monorepo_out/bin/tauri-app" \
  || fail "sibling-crate marker string not found in binary — sibling not linked?"
pass "sibling-crate compiled and linked into the tauri binary"

grep -qaFR "EXTRA_FILESET_MARKER" "$monorepo_out/bin/tauri-app" \
  || fail "extraFileset file not embedded — migrations/ did not reach the app build?"
pass "extraFileset file reached the app build (include_str! marker embedded)"

deps_hash_monorepo=$(cargo_artifacts_out_path)

echo "=== Test 8: Sibling crate source edits don't bust the deps cache ==="

echo "  Modifying sibling-crate source (not its manifest)..."
replace_in_file 's/MONOREPO_SIBLING_MARKER/MONOREPO_SIBLING_MARKER_v2/' sibling-crate/src/lib.rs
commit_all "modify sibling source"

echo "  Rebuilding after sibling source change..."
capture_verbose "$BUILD5_LOG" nix build "${NIX_BUILD_ARGS[@]}" .#default

deps_hash_after_sibling=$(cargo_artifacts_out_path)

if [ "$deps_hash_monorepo" = "$deps_hash_after_sibling" ]; then
  pass "cargoArtifacts unchanged after sibling .rs change ($deps_hash_monorepo)"
else
  fail "cargoArtifacts changed on sibling .rs edit: before=$deps_hash_monorepo after=$deps_hash_after_sibling"
fi

assert_log_lacks 'tauri-app-deps-0\.1\.0\.drv' "$BUILD5_LOG" "deps derivation not rebuilt after sibling .rs change"

monorepo_out_after_sibling=$(run_verbose nix path-info .#default)
grep -qaFR "MONOREPO_SIBLING_MARKER_v2" "$monorepo_out_after_sibling/bin/tauri-app" \
  || fail "updated sibling marker not found in rebuilt binary"
pass "rebuilt binary picks up the sibling source edit"

echo "=== Test 9: extraFileset content edits don't bust the deps cache ==="

echo "  Modifying the extraFileset file (migrations/0001_init.sql)..."
replace_in_file 's/EXTRA_FILESET_MARKER/EXTRA_FILESET_MARKER_v2/' migrations/0001_init.sql
commit_all "modify extraFileset migration"

echo "  Rebuilding after extraFileset content change..."
capture_verbose "$BUILD6_LOG" nix build "${NIX_BUILD_ARGS[@]}" .#default

deps_hash_after_extrafileset=$(cargo_artifacts_out_path)

if [ "$deps_hash_after_sibling" = "$deps_hash_after_extrafileset" ]; then
  pass "cargoArtifacts unchanged after extraFileset content edit ($deps_hash_after_extrafileset)"
else
  fail "cargoArtifacts changed on extraFileset edit: before=$deps_hash_after_sibling after=$deps_hash_after_extrafileset"
fi

assert_log_lacks 'tauri-app-deps-0\.1\.0\.drv' "$BUILD6_LOG" "deps derivation not rebuilt after extraFileset content edit"

extrafileset_out=$(run_verbose nix path-info .#default)
grep -qaFR "EXTRA_FILESET_MARKER_v2" "$extrafileset_out/bin/tauri-app" \
  || fail "updated extraFileset marker not found in rebuilt binary"
pass "rebuilt binary picks up the extraFileset content edit"

echo "=== Test 12: wrappedApp wraps the binary with the GApps environment ==="

wrapped_out=$(run_verbose nix build "${NIX_BUILD_ARGS[@]}" .#wrapped --print-out-paths)

case "$SYSTEM" in
*-darwin)
  pass "wrappedApp passes the app through unchanged on darwin" ;;
*)
  head -c 2 "$wrapped_out/bin/tauri-app" | grep -q '^#!' || fail "wrappedApp binary is not a wrapper script"
  grep -qaFR "vite.svg" "$wrapped_out/bin/" || fail "wrappedApp binary lost the embedded frontend marker"
  pass "wrappedApp binary is a wrapper script around the real ELF" ;;
esac

echo "=== Test 11: tauriBuild/tauriInstall closures replace the defaults ==="

# Evaluation only — no build.

# Read one named flake output rather than the whole recursive closure: it avoids
# materialising every derivation the app depends on, and it anchors the deps
# derivation by its flake attr instead of a hard-coded name/version string.
#
# Nix 2.35 wraps `derivation show` output as {version, derivations}; 2.28 emits
# the bare drvPath->derivation map. `(.derivations // .)` accepts either, and the
# two `error` branches turn a further shape change into a readable message rather
# than a jq stack trace, since `set -e` aborts on either.
#
# Each derivation is evaluated once and every lookup below reads from the
# captured JSON — the previous version spawned five `nix derivation show` runs
# per leg, re-evaluating the consumer flake each time.
drv_json() {
  run_verbose nix derivation show ".#$1" | jq -c '
    (if type == "object" then . else error("derivation show did not return an object") end)
    | (.derivations // .)
    | to_entries
    | (if length == 1 then . else error("expected exactly 1 derivation, got \(length)") end)
    | .[0].value'
}

drv_env() {
  jq -r --arg key "$1" '.env[$key] // ""' <<<"$2"
}

echo "  Adding caller closures to flake.nix..."
insert_after_anchor 'extraFileset = \.\/migrations;' flake.nix <<'CLOSURES'
          tauriBuild = { configFlag, ... }: "echo SENTINEL_CALLER_BUILD ${configFlag}";
          tauriInstall = _: "mkdir -p $out";
CLOSURES
commit_all "add caller tauriBuild/tauriInstall closures"

app_drv=$(drv_json default)
app_build_phase=$(drv_env buildPhase "$app_drv")
app_install_phase=$(drv_env installPhase "$app_drv")

# The load-bearing option-default semantics: a caller closure REPLACES the
# library default; without the mkOptionDefault priority, types.lines would
# concatenate the two commands.
case "$app_build_phase" in
*SENTINEL_CALLER_BUILD*)
  pass "caller tauriBuild replaces the default" ;;
*)
  fail "caller tauriBuild did not replace the default: $app_build_phase" ;;
esac

case "$app_build_phase$app_install_phase" in
*cargo\ tauri\ build*|*find\ target*)
  fail "default closure leaked alongside the caller's: $app_build_phase $app_install_phase" ;;
*)
  pass "default closures did not concatenate with the caller's" ;;
esac

# A closure may ignore any part of the context — the install closure above takes
# no context at all — and must still render.
case "$app_install_phase" in
*"mkdir -p \$out"*)
  pass "context-ignoring closure still renders" ;;
*)
  fail "context-ignoring closure did not render: $app_install_phase" ;;
esac

replace_in_file '/tauriBuild = { configFlag/d; /tauriInstall = _:/d' flake.nix
commit_all "remove caller closures"

echo "  Adding a caller mkDefault closure to flake.nix..."
insert_after_anchor 'extraFileset = \.\/migrations;' flake.nix <<'CLOSURES'
          tauriBuild = lib.mkDefault ({ ... }: "echo SENTINEL_CALLER_MKDEFAULT");
CLOSURES
commit_all "add caller mkDefault tauriBuild"

app_drv=$(drv_json default)
app_build_phase=$(drv_env buildPhase "$app_drv")

# Option defaults sit at mkOptionDefault priority, below a caller's
# lib.mkDefault — so even a mkDefault-priority caller closure replaces the
# default instead of tying with it (a tie would concatenate via types.lines).
case "$app_build_phase" in
*SENTINEL_CALLER_MKDEFAULT*)
  pass "caller mkDefault tauriBuild replaces the option default" ;;
*)
  fail "caller mkDefault tauriBuild did not replace the option default: $app_build_phase" ;;
esac

case "$app_build_phase" in
*cargo\ tauri\ build*)
  fail "option default concatenated with the caller's mkDefault: $app_build_phase" ;;
*)
  pass "option default did not concatenate with the caller's mkDefault" ;;
esac

replace_in_file '/tauriBuild = lib.mkDefault/d' flake.nix
commit_all "remove mkDefault closure"

echo "=== Test 10: craneArgs phase keys never reach the deps derivation ==="

# Evaluation only — no build. Runs last because it leaves the consumer flake with
# a deliberately broken app build.

echo "  Adding craneArgs phase overrides to flake.nix..."
insert_after_anchor 'extraFileset = \.\/migrations;' flake.nix <<'CRANEARGS'
          craneArgs = {
            buildCommand = "echo SENTINEL_APP_BUILD_COMMAND";
            buildCommandPath = "/nonexistent/SENTINEL_APP_BUILD_COMMAND_PATH";
            buildPhase = "echo SENTINEL_APP_BUILD_PHASE";
            buildPhaseCargoCommand = "echo SENTINEL_APP_BUILD_PHASE_CARGO";
            cargoBuildCommand = "echo SENTINEL_APP_CARGO_BUILD";
            cargoCheckCommand = "echo SENTINEL_APP_CARGO_CHECK";
            cargoTestCommand = "echo SENTINEL_APP_CARGO_TEST";
            checkPhase = "echo SENTINEL_APP_CHECK_PHASE";
            checkPhaseCargoCommand = "echo SENTINEL_APP_CHECK_PHASE_CARGO";
            dontBuild = "SENTINEL_APP_DONT_BUILD";
            dontCheck = "SENTINEL_APP_DONT_CHECK";
            dontConfigure = "SENTINEL_APP_DONT_CONFIGURE";
            dontDist = "SENTINEL_APP_DONT_DIST";
            dontFixup = "SENTINEL_APP_DONT_FIXUP";
            dontInstall = "SENTINEL_APP_DONT_INSTALL";
            dontPatch = "SENTINEL_APP_DONT_PATCH";
            dontUnpack = "SENTINEL_APP_DONT_UNPACK";
            doInstallCargoArtifacts = false;
            fixupPhase = "echo SENTINEL_APP_FIXUP_PHASE";
            installPhase = "echo SENTINEL_APP_INSTALL_PHASE";
            installPhaseCommand = "echo SENTINEL_APP_INSTALL_PHASE_CARGO";
            meta.description = "SENTINEL_APP_META";
            outputs = [ "out" "doc" ];
            phases = "unpackPhase patchPhase installPhase";
            postInstall = "echo SENTINEL_APP_POST_INSTALL";
            preFixup = "echo SENTINEL_APP_PRE_FIXUP";
          };
CRANEARGS
commit_all "add craneArgs phase overrides"

app_drv=$(drv_json default)
deps_drv=$(drv_json cargoArtifacts)

app_build_phase=$(drv_env buildPhase "$app_drv")
deps_build_phase=$(drv_env buildPhase "$deps_drv")
deps_install_phase=$(drv_env installPhase "$deps_drv")

# Anchors the reader: if the phase attributes stop being plain env vars these fail
# loudly instead of letting the SENTINEL checks below pass vacuously against empty
# strings.
if [ -n "$deps_build_phase" ] && [ -n "$deps_install_phase" ]; then
  pass "deps derivation phases are readable from the derivation graph"
else
  fail "could not read phases for the deps derivation — update drv_json in Test 10"
fi

# Proves craneArgs still reaches the app, so the SENTINEL checks below are testing
# that the deps args were filtered, not that nothing was passed at all.
case "$app_build_phase" in
*SENTINEL_APP_BUILD_PHASE*)
  pass "craneArgs still reaches the app derivation" ;;
*)
  fail "craneArgs.buildPhase did not reach the app derivation: $app_build_phase" ;;
esac

case "$deps_build_phase" in
*cargoWithProfile*)
  pass "deps derivation still runs crane's own build command" ;;
*)
  fail "deps buildPhase is not crane's default: $deps_build_phase" ;;
esac

# Every denylist key that leaks surfaces either as its own env var (dont*,
# buildCommand, phases, ...) or spliced into an assembled phase string
# (buildPhaseCargoCommand / cargoBuildCommand into buildPhase,
# installPhaseCommand / postInstall into installPhase, checkPhaseCargoCommand /
# cargoCheckCommand into checkPhase, ...), so one scan of every env value catches
# all of them in a single assertion.
deps_leaked_keys=$(jq -r '
  .env | to_entries | map(select(.value | test("SENTINEL_APP_"))) | map(.key) | join(", ")
' <<<"$deps_drv")
if [ -z "$deps_leaked_keys" ]; then
  pass "no craneArgs phase key reached the deps derivation"
else
  fail "craneArgs phase keys leaked into the deps derivation: $deps_leaked_keys"
fi

# buildDepsOnly force-sets doInstallCargoArtifacts = true so the cache is always
# published, and its cleanedArgs drop `outputs` — both hold for current crane,
# and the denylist entries keep them true for whatever crane rev a consumer
# pins. The sentinels set the opposite values, so both assertions prove the deps
# derivation keeps crane's own defaults.
deps_do_install=$(drv_env doInstallCargoArtifacts "$deps_drv")
if [ "$deps_do_install" = "1" ]; then
  pass "deps derivation keeps crane's doInstallCargoArtifacts"
else
  fail "doInstallCargoArtifacts leaked into the deps derivation: $deps_do_install"
fi

# The versioned `derivation show` shape renders outputs as an object keyed by
# output name; the flat shape as a list. Normalize to the list of names.
deps_outputs=$(jq -c '[.outputs | if type == "array" then .[] else keys[] end] | sort' <<<"$deps_drv")
if [ "$deps_outputs" = '["out"]' ]; then
  pass "deps derivation keeps its single out output"
else
  fail "outputs leaked into the deps derivation: $deps_outputs"
fi

# meta is not an env var and `nix derivation show` does not serialize it, so
# read it from the derivation attr instead. The sentinel above sets
# description, so empty proves the key was stripped.
deps_meta_description=$(run_verbose nix eval --raw --apply 'd: d.meta.description or ""' ".#packages.$SYSTEM.cargoArtifacts")
if [ -z "$deps_meta_description" ]; then
  pass "craneArgs meta did not reach the deps derivation"
else
  fail "meta leaked into the deps derivation: $deps_meta_description"
fi

echo "  Adding cargoArtifactsArgs to flake.nix..."
insert_after_anchor 'extraFileset = \.\/migrations;' flake.nix <<'DEPS_ARGS'
          cargoArtifactsArgs = {
            buildPhaseCargoCommand = "echo SENTINEL_DEPS_CHANNEL";
          };
DEPS_ARGS
commit_all "add cargoArtifactsArgs deps override"

deps_drv=$(drv_json cargoArtifacts)
deps_build_phase=$(drv_env buildPhase "$deps_drv")

case "$deps_build_phase" in
*SENTINEL_DEPS_CHANNEL*)
  pass "cargoArtifactsArgs reaches the deps derivation" ;;
*)
  fail "cargoArtifactsArgs.buildPhaseCargoCommand did not reach the deps build: $deps_build_phase" ;;
esac

echo ""
echo "=== All integration tests passed ==="
