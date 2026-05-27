#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${WORKDIR:-$ROOT/work}"
OPENSECRET_COMMIT="${OPENSECRET_COMMIT:-b75ed7d20fd04fb9d893eda54c13c0eabcfb67be}"
OPENSECRET_REPO="${OPENSECRET_REPO:-https://github.com/OpenSecretCloud/opensecret.git}"
OPENSECRET_DIR="$WORKDIR/opensecret"
PLATFORM="${PLATFORM:-linux/arm64}"
IMAGE_TAG="${IMAGE_TAG:-opensecret-nitro-dockerfile-audit:current}"
EXTRA_DOCKER_ARGS="${EXTRA_DOCKER_ARGS:-}"

usage() {
  cat <<'EOF'
Usage: scripts/check-nitro-dockerfile.sh

Runs the original Nitro C Dockerfile formula from the pinned OpenSecret checkout:

  opensecret/nitro-toolkit/enclave-base-image/Dockerfile

This is the Amazon Linux / rustup / crates.io path used to build libnsm.so and
kmstool_enclave_cli. During the audit, this formula was not reproducible from
public committed inputs: the base image/RPM set was mutable, and Cargo 1.63
resolved newer crates that it could not parse.

Environment:
  WORKDIR            scratch directory, default ./work
  PLATFORM           Docker platform, default linux/arm64
  IMAGE_TAG          local Docker tag, default opensecret-nitro-dockerfile-audit:current
  EXTRA_DOCKER_ARGS  extra args passed to docker build
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

need git
need docker

mkdir -p "$WORKDIR"

if [[ ! -d "$OPENSECRET_DIR/.git" ]]; then
  git clone "$OPENSECRET_REPO" "$OPENSECRET_DIR"
fi

git -C "$OPENSECRET_DIR" fetch origin "$OPENSECRET_COMMIT"
git -C "$OPENSECRET_DIR" checkout --detach "$OPENSECRET_COMMIT"
git -C "$OPENSECRET_DIR" reset --hard "$OPENSECRET_COMMIT"
git -C "$OPENSECRET_DIR" clean -ffd
git -C "$OPENSECRET_DIR" submodule update --init --recursive nitro-toolkit

dockerfile="$OPENSECRET_DIR/nitro-toolkit/enclave-base-image/Dockerfile"
context="$OPENSECRET_DIR/nitro-toolkit/enclave-base-image"

cat <<EOF
Running original Nitro Dockerfile formula:
  $dockerfile

Platform:
  $PLATFORM

Expected audit result:
  This build is expected to fail or produce a non-matching toolchain because
  the formula uses mutable Amazon Linux/RPM inputs and unlocked Cargo deps.

EOF

# shellcheck disable=SC2086
docker build --platform "$PLATFORM" --progress=plain -t "$IMAGE_TAG" $EXTRA_DOCKER_ARGS -f "$dockerfile" "$context"

out_dir="$WORKDIR/nitro-dockerfile-output"
rm -rf "$out_dir"
mkdir -p "$out_dir"

container="$(docker create "$IMAGE_TAG")"
trap 'docker rm -f "$container" >/dev/null 2>&1 || true' EXIT

docker cp "$container:/app/libnsm.so" "$out_dir/libnsm.so"
docker cp "$container:/app/kmstool_enclave_cli" "$out_dir/kmstool_enclave_cli"

echo
echo "Dockerfile output hashes:"
hash_file "$out_dir/libnsm.so"
hash_file "$out_dir/kmstool_enclave_cli"

echo
echo "Checked-in production hashes:"
hash_file "$OPENSECRET_DIR/nitro-bins/libnsm.so"
hash_file "$OPENSECRET_DIR/nitro-bins/kmstool_enclave_cli"

if cmp -s "$out_dir/libnsm.so" "$OPENSECRET_DIR/nitro-bins/libnsm.so" &&
   cmp -s "$out_dir/kmstool_enclave_cli" "$OPENSECRET_DIR/nitro-bins/kmstool_enclave_cli"; then
  echo
  echo "Dockerfile output matches checked-in Nitro binaries."
else
  echo
  echo "Dockerfile output does not match checked-in Nitro binaries."
  exit 1
fi
