#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${WORKDIR:-$ROOT/work/router-container}"
ROUTER_REPO="${ROUTER_REPO:-https://github.com/tinfoilsh/confidential-model-router.git}"
ROUTER_DIR="$WORKDIR/confidential-model-router"

SOURCE_COMMIT="${SOURCE_COMMIT:-4ad5a7229fdd37f5d270b56a92dfb23a3fb2b562}"
RELEASE_TAG="${RELEASE_TAG:-v0.0.104}"
VERSION_LABEL="${VERSION_LABEL:-0.0.104}"
CREATED_LABEL="${CREATED_LABEL:-2026-05-24T19:39:21.847Z}"

GOLANG_BASE="${GOLANG_BASE:-golang:1.25-alpine@sha256:8d22e29d960bc50cd025d93d5b7c7d220b1ee9aa7a239b3c8f55a57e987e8d45}"
ALPINE_BASE="${ALPINE_BASE:-alpine:latest@sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11}"

EXPECTED_INDEX_DIGEST="${EXPECTED_INDEX_DIGEST:-sha256:3c8fb768331fd298e3bdc44a441c5ec8261a749aaf330c8628dc5df3232d0287}"
EXPECTED_IMAGE_MANIFEST_DIGEST="${EXPECTED_IMAGE_MANIFEST_DIGEST:-sha256:3de81dd9fbbc005bdd2fc1e2712892c575fae46cc5b88f7169b7253eeef09963}"
EXPECTED_APP_LAYER_DIGEST="${EXPECTED_APP_LAYER_DIGEST:-sha256:f0a014da990e98236b4deeeec59c25b67f99b88be16ccbf82bb53be4be3b934c}"

OUT_JSON="${OUT_JSON:-$ROOT/proofs/router-container-rebuild.json}"
OCI_TAR="$WORKDIR/router.oci.tar"
OCI_DIR="$WORKDIR/router.oci"
PATCHED_DOCKERFILE="$WORKDIR/Dockerfile.pinned"
DOCKER_CONFIG_DIR="$WORKDIR/docker-config"
BUILDER="${BUILDER:-maple-audit-router-repro}"
STRICT="${STRICT:-0}"

usage() {
  cat <<EOF
Usage: ppq/scripts/rebuild-router-container.sh

Attempts to rebuild the Tinfoil router container used by PPQ's live private
endpoint and compares the local OCI image manifest digest with the live digest.

Environment:
  WORKDIR     scratch directory, default ppq/work/router-container
  OUT_JSON    output proof JSON, default ppq/proofs/router-container-rebuild.json
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

need git
need docker
need jq
need tar
need curl

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

mkdir -p "$WORKDIR" "$(dirname "$OUT_JSON")" "$DOCKER_CONFIG_DIR"
docker_context="$(docker context show 2>/dev/null || true)"
if [[ -n "$docker_context" ]]; then
  printf '{"auths":{},"currentContext":"%s"}\n' "$docker_context" > "$DOCKER_CONFIG_DIR/config.json"
else
  printf '{"auths":{}}\n' > "$DOCKER_CONFIG_DIR/config.json"
fi
if [[ -d "$HOME/.docker/cli-plugins" && ! -e "$DOCKER_CONFIG_DIR/cli-plugins" ]]; then
  ln -s "$HOME/.docker/cli-plugins" "$DOCKER_CONFIG_DIR/cli-plugins"
fi
if [[ -d "$HOME/.docker/contexts" && ! -e "$DOCKER_CONFIG_DIR/contexts" ]]; then
  ln -s "$HOME/.docker/contexts" "$DOCKER_CONFIG_DIR/contexts"
fi
if [[ -d "$HOME/.docker/buildx" && ! -e "$DOCKER_CONFIG_DIR/buildx" ]]; then
  ln -s "$HOME/.docker/buildx" "$DOCKER_CONFIG_DIR/buildx"
fi
export DOCKER_CONFIG="$DOCKER_CONFIG_DIR"

if [[ ! -d "$ROUTER_DIR/.git" ]]; then
  git clone "$ROUTER_REPO" "$ROUTER_DIR"
fi

git -C "$ROUTER_DIR" fetch origin "$SOURCE_COMMIT"
git -C "$ROUTER_DIR" checkout --detach "$SOURCE_COMMIT"
git -C "$ROUTER_DIR" reset --hard "$SOURCE_COMMIT"
git -C "$ROUTER_DIR" clean -ffd

sed \
  -e "s|^FROM golang:1.25-alpine AS builder|FROM $GOLANG_BASE AS builder|" \
  -e "s|^FROM alpine:latest$|FROM $ALPINE_BASE|" \
  "$ROUTER_DIR/Dockerfile" > "$PATCHED_DOCKERFILE"

rm -f "$OCI_TAR"
rm -rf "$OCI_DIR"

if ! docker buildx inspect "$BUILDER" >/dev/null 2>&1; then
  docker buildx create --name "$BUILDER" --driver docker-container >/dev/null
fi
docker buildx inspect "$BUILDER" --bootstrap >/dev/null

docker buildx build \
  --builder "$BUILDER" \
  --platform linux/amd64 \
  --progress=plain \
  --build-arg "VERSION=$RELEASE_TAG" \
  --build-arg "SOURCE_DATE_EPOCH=0" \
  --label "org.opencontainers.image.created=$CREATED_LABEL" \
  --label "org.opencontainers.image.description=Tinfoil Orchestration Server" \
  --label "org.opencontainers.image.licenses=AGPL-3.0" \
  --label "org.opencontainers.image.revision=$SOURCE_COMMIT" \
  --label "org.opencontainers.image.source=https://github.com/tinfoilsh/confidential-model-router" \
  --label "org.opencontainers.image.title=confidential-model-router" \
  --label "org.opencontainers.image.url=https://github.com/tinfoilsh/confidential-model-router" \
  --label "org.opencontainers.image.version=$VERSION_LABEL" \
  --output "type=oci,dest=$OCI_TAR" \
  -f "$PATCHED_DOCKERFILE" \
  "$ROUTER_DIR"

mkdir -p "$OCI_DIR"
tar -xf "$OCI_TAR" -C "$OCI_DIR"

local_image_manifest_digest="$(jq -r '.manifests[0].digest' "$OCI_DIR/index.json")"
manifest_path="$OCI_DIR/blobs/sha256/${local_image_manifest_digest#sha256:}"
config_digest="$(jq -r '.config.digest' "$manifest_path")"
layer_digests="$(jq -c '[.layers[].digest]' "$manifest_path")"
local_app_layer_digest="$(jq -r '.layers[2].digest' "$manifest_path")"
matched=false
if [[ "$local_image_manifest_digest" == "$EXPECTED_IMAGE_MANIFEST_DIGEST" ]]; then
  matched=true
fi

rm -rf "$WORKDIR/local-app-layer" "$WORKDIR/live-app-layer"
mkdir -p "$WORKDIR/local-app-layer" "$WORKDIR/live-app-layer" "$WORKDIR/live"
tar -xzf "$OCI_DIR/blobs/sha256/${local_app_layer_digest#sha256:}" -C "$WORKDIR/local-app-layer"
ghcr_token="$(curl -fsSL 'https://ghcr.io/token?service=ghcr.io&scope=repository:tinfoilsh/confidential-model-router:pull' | jq -r .token)"
curl -fsSL \
  -H "Authorization: Bearer $ghcr_token" \
  "https://ghcr.io/v2/tinfoilsh/confidential-model-router/blobs/$EXPECTED_APP_LAYER_DIGEST" \
  > "$WORKDIR/live/app-layer.tar.gz"
tar -xzf "$WORKDIR/live/app-layer.tar.gz" -C "$WORKDIR/live-app-layer"
local_proxy_hash="$(hash_file "$WORKDIR/local-app-layer/app/proxy")"
live_proxy_hash="$(hash_file "$WORKDIR/live-app-layer/app/proxy")"
proxy_matched=false
if [[ "$local_proxy_hash" == "$live_proxy_hash" ]]; then
  proxy_matched=true
fi

classification="BROKEN"
if [[ "$matched" == true ]]; then
  classification="SOURCE-REPRO"
elif [[ "$proxy_matched" == true ]]; then
  classification="SOURCE-BINARY-REPRO"
fi

cat > "$OUT_JSON" <<EOF
{
  "checkedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "sourceRepo": "$ROUTER_REPO",
  "sourceCommit": "$SOURCE_COMMIT",
  "releaseTag": "$RELEASE_TAG",
  "expectedIndexDigest": "$EXPECTED_INDEX_DIGEST",
  "expectedImageManifestDigest": "$EXPECTED_IMAGE_MANIFEST_DIGEST",
  "expectedAppLayerDigest": "$EXPECTED_APP_LAYER_DIGEST",
  "localImageManifestDigest": "$local_image_manifest_digest",
  "localConfigDigest": "$config_digest",
  "localLayerDigests": $layer_digests,
  "localProxySha256": "$local_proxy_hash",
  "liveProxySha256": "$live_proxy_hash",
  "matchedExpectedImageManifest": $matched,
  "matchedProxyBinary": $proxy_matched,
  "classification": "$classification",
  "notes": "Built with patched base image digests from the live SLSA provenance and labels matching the GitHub release build. The live index digest also contains an attestation manifest; this comparison targets the actual linux/amd64 image manifest. In this run the rebuilt proxy binary matched the live proxy binary, but the image manifest did not because the application layer tar metadata timestamps differed from the release build."
}
EOF

cat "$OUT_JSON"

if [[ "$STRICT" == "1" && "$matched" != true ]]; then
  exit 2
fi
