#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${WORKDIR:-$ROOT/work/cvmimage}"
SOURCE_REPO="${SOURCE_REPO:-https://github.com/tinfoilsh/cvmimage.git}"
SOURCE_DIR="${SOURCE_DIR:-$WORKDIR/cvmimage}"

RELEASE_TAG="${RELEASE_TAG:-v0.7.5}"
SOURCE_COMMIT="${SOURCE_COMMIT:-35d3e393d822ca0fa5eab4cc2edd651c8ded2d77}"
MKOSI_COMMIT="${MKOSI_COMMIT:-54c625c380ef5500f17460981a3c67b109b6a847}"
EXPECTED_MANIFEST_URL="${EXPECTED_MANIFEST_URL:-https://github.com/tinfoilsh/cvmimage/releases/download/v0.7.5/tinfoil-inference-v0.7.5-manifest.json}"
EXPECTED_MANIFEST_DIGEST="${EXPECTED_MANIFEST_DIGEST:-sha256:e97ae94ade461d65ebeec58a4fcfd23b004e9109919e40c26040de4d9ebd4cb1}"
UBUNTU_KEYRING_DEB_URL="${UBUNTU_KEYRING_DEB_URL:-https://snapshot.ubuntu.com/ubuntu/20250107T000000Z/pool/main/u/ubuntu-keyring/ubuntu-keyring_2023.11.28.1_all.deb}"
UBUNTU_KEYRING_DEB_SHA256="${UBUNTU_KEYRING_DEB_SHA256:-36de43b15853ccae0028e9a767613770c704833f82586f28eb262f0311adb8a8}"

OUT_JSON="${OUT_JSON:-$ROOT/proofs/cvmimage-rebuild.json}"
BUILD_LOG="${BUILD_LOG:-$WORKDIR/mkosi-build.log}"
CREATED_HOST_KEYRING=0
NIX_PACKAGES=(
  nixpkgs#git
  nixpkgs#go_1_25
  nixpkgs#gcc
  nixpkgs#apt
  nixpkgs#dpkg
  nixpkgs#bash
  nixpkgs#jq
  nixpkgs#binutils
  nixpkgs#coreutils
  nixpkgs#curl
  nixpkgs#gnutar
  nixpkgs#gzip
  nixpkgs#zstd
  nixpkgs#xz
  nixpkgs#cpio
  nixpkgs#python3
  nixpkgs#gnumake
  nixpkgs#util-linux
  nixpkgs#findutils
  nixpkgs#gnused
  nixpkgs#gnugrep
  nixpkgs#gawk
  nixpkgs#systemd
  nixpkgs#e2fsprogs
  nixpkgs#dosfstools
  nixpkgs#cryptsetup
  nixpkgs#squashfsTools
  nixpkgs#gnupg
  nixpkgs#bubblewrap
  nixpkgs#qemu
  nixpkgs#parted
  nixpkgs#gptfdisk
)

usage() {
  cat <<EOF
Usage: ppq/scripts/rebuild-cvmimage.sh

Attempts to rebuild Tinfoil CVM image $RELEASE_TAG and compares the locally
generated manifest with the published release manifest.

Environment:
  WORKDIR     scratch directory, default ppq/work/cvmimage
  OUT_JSON    output proof JSON, default ppq/proofs/cvmimage-rebuild.json
  NO_NIX=1    do not auto-enter a nix shell
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
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

write_status_json() {
  local classification="$1"
  local notes="$2"
  mkdir -p "$(dirname "$OUT_JSON")"
  jq -n \
    --arg checkedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg sourceRepo "$SOURCE_REPO" \
    --arg sourceCommit "$SOURCE_COMMIT" \
    --arg releaseTag "$RELEASE_TAG" \
    --arg mkosiCommit "$MKOSI_COMMIT" \
    --arg expectedManifestUrl "$EXPECTED_MANIFEST_URL" \
    --arg expectedManifestDigest "$EXPECTED_MANIFEST_DIGEST" \
    --arg classification "$classification" \
    --arg notes "$notes" \
    '{
      checkedAt: $checkedAt,
      sourceRepo: $sourceRepo,
      sourceCommit: $sourceCommit,
      releaseTag: $releaseTag,
      mkosiCommit: $mkosiCommit,
      expectedManifestUrl: $expectedManifestUrl,
      expectedManifestDigest: $expectedManifestDigest,
      classification: $classification,
      notes: $notes
    }' > "$OUT_JSON"
  cat "$OUT_JSON"
}

write_build_failure_json() {
  local exit_code="$1"
  local log_tail="$WORKDIR/mkosi-build.tail.log"
  tail -120 "$BUILD_LOG" > "$log_tail" 2>/dev/null || true

  mkdir -p "$(dirname "$OUT_JSON")"
  jq -n \
    --arg checkedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg sourceRepo "$SOURCE_REPO" \
    --arg sourceCommit "$SOURCE_COMMIT" \
    --arg releaseTag "$RELEASE_TAG" \
    --arg goVersion "$go_version" \
    --arg mkosiCommit "$MKOSI_COMMIT" \
    --arg mkosiVersion "$mkosi_version" \
    --arg expectedManifestUrl "$EXPECTED_MANIFEST_URL" \
    --arg expectedManifestDigest "$EXPECTED_MANIFEST_DIGEST" \
    --arg buildLog "$BUILD_LOG" \
    --rawfile failureTail "$log_tail" \
    --arg bootSha256 "$boot_hash" \
    --arg shimSha256 "$shim_hash" \
    --argjson exitCode "$exit_code" \
    '{
      checkedAt: $checkedAt,
      sourceRepo: $sourceRepo,
      sourceCommit: $sourceCommit,
      releaseTag: $releaseTag,
      goVersion: $goVersion,
      mkosiCommit: $mkosiCommit,
      mkosiVersion: $mkosiVersion,
      expectedManifestUrl: $expectedManifestUrl,
      expectedManifestDigest: $expectedManifestDigest,
      local: {
        tinfoilBootSha256: $bootSha256,
        tinfoilShimSha256: $shimSha256
      },
      matchedExpectedManifest: false,
      classification: "BUILD-FORMULA-BROKEN",
      failedStep: "mkosi",
      exitCode: $exitCode,
      buildLog: $buildLog,
      failureTail: $failureTail,
      notes: "The public v0.7.5 source checkout and pinned mkosi commit were usable, but the mkosi package transaction did not resolve. The formula pins some NVIDIA/container package versions while using live external NVIDIA/container repositories, so the same source recipe no longer builds from public inputs."
    }' > "$OUT_JSON"
  cat "$OUT_JSON"
}

if [[ "$(uname -s)" != "Linux" ]]; then
  if command -v jq >/dev/null 2>&1; then
    write_status_json "UNSUPPORTED-HOST" "mkosi disk-image rebuilds require a Linux host with root privileges. Run this script on x86_64 Linux, for example with ssh to pika-build."
  else
    echo "mkosi disk-image rebuilds require Linux." >&2
  fi
  exit 1
fi

if [[ "${NO_NIX:-0}" != "1" && "${IN_NIX_CVMIMAGE_ENV:-0}" != "1" && -z "${IN_NIX_SHELL:-}" && "$(command -v nix || true)" != "" ]]; then
  export IN_NIX_CVMIMAGE_ENV=1
  exec nix shell "${NIX_PACKAGES[@]}" --command "$0" "$@"
fi

need git
need go
need jq
need curl
need objcopy
need python
need sudo
need ar
need tar
need find

if ! sudo -n true >/dev/null 2>&1; then
  write_status_json "BLOCKED" "mkosi needs root privileges, but sudo requires an interactive password on this host."
  exit 1
fi

mkdir -p "$WORKDIR" "$(dirname "$OUT_JSON")"

cleanup_host_keyring() {
  if [[ "$CREATED_HOST_KEYRING" == "1" ]]; then
    sudo -n rm -f /usr/share/keyrings/ubuntu-archive-keyring.gpg || true
  fi
}
trap cleanup_host_keyring EXIT

ensure_ubuntu_keyring() {
  local keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
  if [[ -r "$keyring" ]]; then
    return
  fi

  local keyring_dir="$WORKDIR/ubuntu-keyring"
  local deb="$keyring_dir/ubuntu-keyring.deb"
  local extract="$keyring_dir/extract"
  mkdir -p "$keyring_dir" "$extract"
  curl -fsSL "$UBUNTU_KEYRING_DEB_URL" -o "$deb"

  local deb_sha
  deb_sha="$(hash_file "$deb")"
  if [[ "$deb_sha" != "$UBUNTU_KEYRING_DEB_SHA256" ]]; then
    write_status_json "BLOCKED" "Downloaded ubuntu-keyring deb sha256 $deb_sha, expected $UBUNTU_KEYRING_DEB_SHA256."
    exit 1
  fi

  rm -rf "$extract"
  mkdir -p "$extract"
  (
    cd "$extract"
    ar x "$deb"
    tar -xf data.tar.*
  )
  sudo -n install -Dm644 "$extract/usr/share/keyrings/ubuntu-archive-keyring.gpg" "$keyring"
  CREATED_HOST_KEYRING=1
}

ensure_ubuntu_keyring

make_compat_usr_bin() {
  local compat="$WORKDIR/compat-usr-bin"
  rm -rf "$compat"
  mkdir -p "$compat"

  local old_ifs="$IFS"
  IFS=:
  for dir in $PATH; do
    if [[ -d "$dir" && ( "$dir" == /nix/store/* || "$dir" == /run/current-system/* ) ]]; then
      while IFS= read -r tool; do
        local name
        name="$(basename "$tool")"
        if [[ ! -e "$compat/$name" ]]; then
          ln -s "$tool" "$compat/$name"
        fi
      done < <(find "$dir" -maxdepth 1 \( -type f -o -type l \) -perm -111 2>/dev/null)
    fi
  done
  IFS="$old_ifs"

  for required in apt-get rm env bash sh mount; do
    if [[ ! -e "$compat/$required" ]]; then
      local resolved
      resolved="$(command -v "$required" || true)"
      if [[ -n "$resolved" ]]; then
        ln -s "$resolved" "$compat/$required"
      fi
    fi
  done

  printf '%s\n' "$compat"
}

run_mkosi() {
  local mkosi_bin="$1"
  shift

  if [[ -x /usr/bin/apt-get && -x /usr/bin/rm ]]; then
    sudo -n env "PATH=$PATH" "$mkosi_bin" "$@"
    return
  fi

  local compat helper unshare_bin bash_bin mount_bin env_bin
  compat="$(make_compat_usr_bin)"
  helper="$WORKDIR/run-mkosi-mountns.sh"
  unshare_bin="$(command -v unshare)"
  bash_bin="$(command -v bash)"
  mount_bin="$(command -v mount)"
  env_bin="$(command -v env)"

  cat > "$helper" <<'EOF'
set -euo pipefail
mount_bin="$1"
compat="$2"
shift 2
"$mount_bin" --bind "$compat" /usr/bin
exec "$@"
EOF

  sudo -n "$unshare_bin" -m "$bash_bin" "$helper" "$mount_bin" "$compat" \
    "$env_bin" "PATH=$PATH" "$mkosi_bin" "$@"
}

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
  git clone "$SOURCE_REPO" "$SOURCE_DIR"
fi

git -C "$SOURCE_DIR" fetch --tags origin "$SOURCE_COMMIT"
git -C "$SOURCE_DIR" checkout --detach "$SOURCE_COMMIT"
git -C "$SOURCE_DIR" reset --hard "$SOURCE_COMMIT"
git -C "$SOURCE_DIR" clean -ffd

actual_commit="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
if [[ "$actual_commit" != "$SOURCE_COMMIT" ]]; then
  write_status_json "BLOCKED" "Checked out $actual_commit, expected $SOURCE_COMMIT."
  exit 1
fi

mkdir -p "$WORKDIR/venv" "$WORKDIR/gocache" "$WORKDIR/gomodcache"
if [[ ! -x "$WORKDIR/venv/bin/mkosi" ]]; then
  python -m venv "$WORKDIR/venv"
  "$WORKDIR/venv/bin/pip" install --quiet "git+https://github.com/systemd/mkosi.git@$MKOSI_COMMIT"
fi
MKOSI="$WORKDIR/venv/bin/mkosi"

mkdir -p "$SOURCE_DIR/packages" "$SOURCE_DIR/mkosi.extra/usr/local/bin"
(
  cd "$SOURCE_DIR/tinfoil"
  GOCACHE="$WORKDIR/gocache" GOMODCACHE="$WORKDIR/gomodcache" \
    go build -ldflags="-s -w" -o ../mkosi.extra/usr/local/bin/tinfoil-boot ./cmd/boot
  GOCACHE="$WORKDIR/gocache" GOMODCACHE="$WORKDIR/gomodcache" \
    go build -ldflags="-s -w" -o ../mkosi.extra/usr/local/bin/tinfoil-shim ./cmd/shim
)

boot_hash="$(hash_file "$SOURCE_DIR/mkosi.extra/usr/local/bin/tinfoil-boot")"
shim_hash="$(hash_file "$SOURCE_DIR/mkosi.extra/usr/local/bin/tinfoil-shim")"
go_version="$(go version)"
mkosi_version="$("$MKOSI" --version)"

pushd "$SOURCE_DIR" >/dev/null
set +e
run_mkosi "$MKOSI" --image-version "$RELEASE_TAG" 2>&1 | tee "$BUILD_LOG"
mkosi_status="${PIPESTATUS[0]}"
set -e
if [[ "$mkosi_status" != "0" ]]; then
  write_build_failure_json "$mkosi_status"
  exit "$mkosi_status"
fi
sudo -n chmod 644 tinfoilcvm.*
sudo -n chown "$(id -u):$(id -g)" tinfoilcvm.*
popd >/dev/null

local_root="$(objcopy -O binary --only-section .cmdline "$SOURCE_DIR/tinfoilcvm.efi" /dev/stdout | cut -d "=" -f 2)"
local_initrd="$(hash_file "$SOURCE_DIR/tinfoilcvm.initrd")"
local_kernel="$(hash_file "$SOURCE_DIR/tinfoilcvm.vmlinuz")"
local_raw="$(hash_file "$SOURCE_DIR/tinfoilcvm.raw")"

expected_manifest="$WORKDIR/expected-manifest.json"
curl -fsSL "$EXPECTED_MANIFEST_URL" > "$expected_manifest"
expected_manifest_sha="sha256:$(hash_file "$expected_manifest")"
expected_root="$(jq -r .root "$expected_manifest")"
expected_initrd="$(jq -r .initrd "$expected_manifest")"
expected_kernel="$(jq -r .kernel "$expected_manifest")"
expected_raw="$(jq -r .raw "$expected_manifest")"
expected_built_at="$(jq -r .built_at "$expected_manifest")"

matched=false
classification="BROKEN"
if [[ "$local_root" == "$expected_root" && "$local_initrd" == "$expected_initrd" && "$local_kernel" == "$expected_kernel" && "$local_raw" == "$expected_raw" ]]; then
  matched=true
  classification="SOURCE-REPRO"
fi

jq -n \
  --arg checkedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg sourceRepo "$SOURCE_REPO" \
  --arg sourceCommit "$SOURCE_COMMIT" \
  --arg releaseTag "$RELEASE_TAG" \
  --arg goVersion "$go_version" \
  --arg mkosiCommit "$MKOSI_COMMIT" \
  --arg mkosiVersion "$mkosi_version" \
  --arg expectedManifestUrl "$EXPECTED_MANIFEST_URL" \
  --arg expectedManifestDigest "$EXPECTED_MANIFEST_DIGEST" \
  --arg expectedManifestSha256 "$expected_manifest_sha" \
  --arg expectedBuiltAt "$expected_built_at" \
  --arg expectedRoot "$expected_root" \
  --arg expectedInitrd "$expected_initrd" \
  --arg expectedKernel "$expected_kernel" \
  --arg expectedRaw "$expected_raw" \
  --arg localRoot "$local_root" \
  --arg localInitrd "$local_initrd" \
  --arg localKernel "$local_kernel" \
  --arg localRaw "$local_raw" \
  --arg bootSha256 "$boot_hash" \
  --arg shimSha256 "$shim_hash" \
  --arg classification "$classification" \
  --arg notes "This runs the public v0.7.5 release formula: source checkout, Go builds for tinfoil-boot and tinfoil-shim, and pinned mkosi commit. It does not recreate GitHub's runner image exactly, and the upstream workflow only requested go-version 1.25 rather than pinning a patch release." \
  --argjson matched "$matched" \
  '{
    checkedAt: $checkedAt,
    sourceRepo: $sourceRepo,
    sourceCommit: $sourceCommit,
    releaseTag: $releaseTag,
    goVersion: $goVersion,
    mkosiCommit: $mkosiCommit,
    mkosiVersion: $mkosiVersion,
    expectedManifestUrl: $expectedManifestUrl,
    expectedManifestDigest: $expectedManifestDigest,
    expectedManifestSha256: $expectedManifestSha256,
    expectedBuiltAt: $expectedBuiltAt,
    expected: {
      root: $expectedRoot,
      initrd: $expectedInitrd,
      kernel: $expectedKernel,
      raw: $expectedRaw
    },
    local: {
      root: $localRoot,
      initrd: $localInitrd,
      kernel: $localKernel,
      raw: $localRaw,
      tinfoilBootSha256: $bootSha256,
      tinfoilShimSha256: $shimSha256
    },
    matchedExpectedManifest: $matched,
    classification: $classification,
    notes: $notes
  }' > "$OUT_JSON"

cat "$OUT_JSON"

if [[ "$matched" != true ]]; then
  exit 2
fi
