#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${WORKDIR:-$ROOT/work}"
OPENSECRET_COMMIT="${OPENSECRET_COMMIT:-b75ed7d20fd04fb9d893eda54c13c0eabcfb67be}"
OPENSECRET_REPO="${OPENSECRET_REPO:-https://github.com/OpenSecretCloud/opensecret.git}"
OPENSECRET_DIR="$WORKDIR/opensecret"
PATCH="$ROOT/patches/opensecret-source-build.patch"
SYSTEM="${SYSTEM:-aarch64-linux}"
EXTRA_NIX_ARGS="${EXTRA_NIX_ARGS:-}"

usage() {
  cat <<'EOF'
Usage: providers/maple/scripts/reproduce-build.sh

Clones the pinned OpenSecret repo, applies the source-build patch from this
audit, then builds the source-derived production EIF:

  - eif-prod-source   source-derived EIF with rebuilt app-level binaries

Environment:
  WORKDIR            scratch directory, default ./work
  SYSTEM             Nix target system, default aarch64-linux
  EXTRA_NIX_ARGS     extra args passed to nix build, e.g. "--max-jobs 0"
  OPENSECRET_COMMIT  source commit, default audit commit
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1"
  else
    shasum -a 256 "$1"
  fi
}

nix_build() {
  local attr="$1"
  local out="$2"
  rm -f "$out"
  # shellcheck disable=SC2086
  nix build --system "$SYSTEM" --print-build-logs $EXTRA_NIX_ARGS "$attr" -o "$out"
}

need git
need nix

mkdir -p "$WORKDIR"

if [[ ! -d "$OPENSECRET_DIR/.git" ]]; then
  git clone "$OPENSECRET_REPO" "$OPENSECRET_DIR"
fi

git -C "$OPENSECRET_DIR" fetch origin "$OPENSECRET_COMMIT"
git -C "$OPENSECRET_DIR" checkout --detach "$OPENSECRET_COMMIT"
git -C "$OPENSECRET_DIR" reset --hard "$OPENSECRET_COMMIT"
git -C "$OPENSECRET_DIR" clean -ffd
git -C "$OPENSECRET_DIR" submodule update --init --recursive

git -C "$OPENSECRET_DIR" apply "$PATCH"

# Nix's git flake source only sees tracked files. Stage the patch outputs in
# this scratch checkout so added source-build files are visible to Nix.
git -C "$OPENSECRET_DIR" add \
  flake.lock \
  flake.nix \
  source-packages.nix \
  tinfoil-proxy/flake.nix \
  nix/aws-nitro-enclaves-nsm-api-Cargo.lock \
  nix/aws-nitro-enclaves-nsm-api-Cargo-lock.patch

source_out="$WORKDIR/result-prod-source-arm"
expected_prod_hash="2982295c13c5b92055b1f7593124cb7e6da93220d4fadd0c9496291e4044eca4"
expected_source_hash="04ce61d813dad461cfc0d0fd004d790fac2954b02ef7be9fbf23242a9abc34ce"

nix_build "$OPENSECRET_DIR?submodules=1#eif-prod-source" "$source_out"

echo
echo "Source-derived EIF image hash:"
source_hash="$(hash_file "$source_out/image.eif" | awk '{print $1}')"
echo "$source_hash  source-derived EIF ($source_out/image.eif)"

cat <<EOF

Expected production EIF hash:
  $expected_prod_hash

Expected source-derived EIF hash from this audit:
  $expected_source_hash
EOF

if [[ "$source_hash" == "$expected_prod_hash" ]]; then
  echo
  echo "Unexpected result: source-derived EIF matched the production EIF hash."
  exit 1
fi

if [[ "$source_hash" != "$expected_source_hash" ]]; then
  echo
  echo "Unexpected result: source-derived EIF did not match the audit hash."
  exit 1
fi

echo
echo "Result: source-derived EIF reproduced the audit hash and does not match production."
