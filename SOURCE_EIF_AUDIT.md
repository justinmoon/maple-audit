# OpenSecret/Maple Source EIF Audit

Date: 2026-05-26 America/Chicago / 2026-05-27 UTC

Workspace: `/Users/justin/code/maple-audit`

Primary repo: `opensecret` at `b75ed7d20fd04fb9d893eda54c13c0eabcfb67be`

## Result

I built an application-level source-derived production EIF:

```sh
nix build --system aarch64-linux --max-jobs 0 './opensecret?submodules=1#eif-prod-source' -o result-prod-source-arm --print-build-logs
```

Output:

```text
result-prod-source-arm -> /nix/store/vbx32w46ycwa3qi3gdywgy21fnki9h8b-opensecret-eif-prod-source
sha256(result-prod-source-arm/image.eif) = 04ce61d813dad461cfc0d0fd004d790fac2954b02ef7be9fbf23242a9abc34ce
```

Source EIF PCRs:

```json
{
  "HashAlgorithm": "Sha384 { ... }",
  "PCR0": "6ba947597a6f6cdd2e563f139e4a0ace82aeb86aeb1017a3e66d06f6b717db70575a1d3b0528da285c42cbae9d7e8ff0",
  "PCR1": "5ecc5151d681c53c455898da9cd67db547cebdd0e59021accd9d0729e9bc6f566f682003a2d010a34ec7da4c6379a8df",
  "PCR2": "ca8f963e7f82873d6848b8372f51c54ca4f1f083caa56180e47805771415f536100d1206d56943c44bb713b7b652e06d"
}
```

This source-derived EIF does not match production.

## Live Production Attestation

I fetched a fresh Nitro attestation document from:

```text
https://enclave.trymaple.ai/attestation/<nonce>
```

Nonce:

```text
069c9bf7-182b-4d36-873a-bbac1b9f9165
```

Attestation timestamp:

```text
2026-05-27T00:39:52.228Z
```

The attestation document was verified against:

- local AWS Nitro root certificate: `OpenSecret-SDK/rust/assets/aws_nitro_root.der`
- the certificate chain in the attestation document
- the COSE_Sign1 ECDSA P-384/SHA-384 signature
- the nonce embedded in the attestation document

Live production PCRs:

```json
{
  "PCR0": "3c374a4b3c4f4cd5c5a6cc28d89cc2462fdd129eac5cd0eacf7fc78b98af11e9a08750a76cd1c1ab75c2715300530a26",
  "PCR1": "5ecc5151d681c53c455898da9cd67db547cebdd0e59021accd9d0729e9bc6f566f682003a2d010a34ec7da4c6379a8df",
  "PCR2": "a42ae8842b9a34e550bd6d9b56bf37c458e8ce62d9e16ed97a22c61e42bacdf937a013ba96150f5b1922e7f961f5d5d7"
}
```

These exactly match both:

- `opensecret/pcrProd.json`
- the local checked-binary production EIF build at `result-prod-arm`

Checked-binary production EIF:

```text
result-prod-arm -> /nix/store/gzrp8n5zchwc1llhm4fd2xql12l0hrv0-opensecret-eif-prod
sha256(result-prod-arm/image.eif) = 2982295c13c5b92055b1f7593124cb7e6da93220d4fadd0c9496291e4044eca4
```

## PCR Comparison

```text
                    checked-binary/live production                         source-derived build
PCR0                3c374a4b3c4f4cd5...0530a26                             6ba947597a6f6cdd...7e8ff0
PCR1                5ecc5151d681c53c...379a8df                             5ecc5151d681c53c...379a8df
PCR2                a42ae8842b9a34e5...1f5d5d7                             ca8f963e7f82873d...652e06d
```

Conclusion: production is running the checked-binary EIF, not the source-derived EIF built here.

## Replaced Checked-In Enclave Binaries

The source EIF replaces these checked-in artifacts:

- `opensecret/nitro-bins/libnsm.so`
- `opensecret/nitro-bins/kmstool_enclave_cli`
- `opensecret/continuum-proxy`
- `opensecret/tinfoil-proxy/dist/tinfoil-proxy`

Source replacements:

- `libnsm.so`: built from `aws/aws-nitro-enclaves-nsm-api` tag `v0.4.0`
- `kmstool_enclave_cli`: built from `aws/aws-nitro-enclaves-sdk-c` commit `00c6048945a3adbb84bd269f8388282d81110499`
- AWS C dependencies: built from source in `opensecret/source-packages.nix`
- `continuum-proxy`: built from the `privatemode-public` submodule
- `tinfoil-proxy`: built from `opensecret/tinfoil-proxy` Go source, with checked-in `dist/` excluded from the source filter

Binary hashes:

```text
checked-in:
032f54092d362a479dd69076a68e1344d887c14c085ff0d94065db6b19780644  opensecret/nitro-bins/libnsm.so
6b151442e024456e52f65e5369a3bb647093618ac516f66e06854f37ec336ade  opensecret/nitro-bins/kmstool_enclave_cli
0fe4b0efd4a392384bb86b5308eb6fa6d30e7de16eaf26e05b24f67659e1a4f4  opensecret/continuum-proxy
fe7401957606fad29348f6b203c574e3ad6a0663fe2bc5c3ce8de94d2b148484  opensecret/tinfoil-proxy/dist/tinfoil-proxy

source-built:
21aaf6f7366a5cb90214698700c19c3950d2de3902fec20359ad2e6f9e453c12  result-nitro-bins-source-arm/lib/libnsm.so
51ae1d449da67bb68e15c33761935be7a227057220f1bccae2533afa8d771d74  result-nitro-bins-source-arm/bin/kmstool_enclave_cli
0fe4b0efd4a392384bb86b5308eb6fa6d30e7de16eaf26e05b24f67659e1a4f4  result-continuum-source-arm/bin/continuum-proxy
8ce1a1c215e80490027e3f82caf87f52db1692b14f589bc5ca58fd9108283c7f  result-tinfoil-source-arm/bin/tinfoil-proxy
```

`continuum-proxy` reproduced byte-for-byte from source. The first Nix source build did not reproduce the Nitro binaries or `tinfoil-proxy`.

## Reproducibility Follow-Up

### `tinfoil-proxy`

The checked `tinfoil-proxy` binary embeds this Go provenance:

```text
go1.26.1
vcs=git
vcs.revision=c8695c01b4dde11a8815a3a681330fa1e39e68c6
vcs.time=2026-04-09T17:56:20Z
vcs.modified=true
CGO_ENABLED=0
GOOS=linux
GOARCH=arm64
-trimpath=true
```

The Go module source files at current `HEAD` are not different from that commit:

```text
git diff --name-status c8695c01b4dde11a8815a3a681330fa1e39e68c6..HEAD -- \
  tinfoil-proxy/go.mod tinfoil-proxy/go.sum tinfoil-proxy/main.go tinfoil-proxy/main_test.go
```

No files were reported.

The embedded commit is present in this local clone but is not reachable from `origin/master` and was not fetchable from GitHub by hash during this audit. A fresh GitHub clone could not check out `c8695c01b4dde11a8815a3a681330fa1e39e68c6`. For the rebuild test I bundled that local commit and built it on an aarch64 Linux Nix host with the `tinfoil-proxy` flake's locked Go `1.26.1`.

A clean Linux build produced a different hash and `vcs.modified=false`:

```text
2a98ea90dd920b058805df0e13921bb8ca8156aba3998734fc4e43a83b406c2c  clean
```

After dirtying a non-compiled repository file (`README.md`), the Linux build reproduced the checked binary byte-for-byte:

```text
fe7401957606fad29348f6b203c574e3ad6a0663fe2bc5c3ce8de94d2b148484  dirty rebuild
fe7401957606fad29348f6b203c574e3ad6a0663fe2bc5c3ce8de94d2b148484  opensecret/tinfoil-proxy/dist/tinfoil-proxy
```

Conclusion: `tinfoil-proxy` was not a wrong-source-version failure. It is reproducible with the right host OS/arch, Go version, source commit, build flags, and dirty VCS state. The earlier Darwin cross-build and the Nix derivation's `.git`-free source filter were insufficient to reproduce Go's VCS-stamped output.

### Nitro C Binaries

The checked Nitro C artifacts point at the expected upstream source family:

```text
opensecret/nitro-bins/kmstool_enclave_cli:
  aws-nitro_enclaves-sdk-c/v0.4.0-8-g00c6048
  /tmp/crt-builder/aws-nitro-enclaves-sdk-c/...
  /tmp/crt-builder/aws-c-auth/...
  /tmp/crt-builder/aws-c-http/...

opensecret/nitro-bins/libnsm.so:
  rustc version 1.63.0 (4b91a6ea7 2022-08-08)
  serde-1.0.215
  log-0.4.22
  libc-0.2.126
  compiler_builtins-0.1.73
```

The source-derived Nix build used the right high-level AWS source refs, but not the same build environment or Rust dependency resolution:

```text
result-nitro-bins-source-arm/lib/libnsm.so:
  rustc version 1.88.0 (6b00bc388 2025-06-23)
  serde_core-1.0.228

result-nitro-bins-source-arm/bin/kmstool_enclave_cli:
  /nix/store/... paths
  GCC 14.3.0 / 11.5.0 markers
  glibc 2.40 loader/runpath markers
```

I then tried the repo's original Dockerfile path:

```sh
docker build --platform linux/arm64 --progress=plain \
  -t opensecret-enclave-base-audit:current \
  -f opensecret/nitro-toolkit/enclave-base-image/Dockerfile \
  opensecret/nitro-toolkit/enclave-base-image
```

This resolved the mutable base tag to:

```text
public.ecr.aws/amazonlinux/amazonlinux:minimal@sha256:25fb18d93f8f27b0812bdc61354ce1fd27f4aea43c5883b23590d1ccf4a35f61
```

It installed current Amazon Linux packages including:

```text
gcc-11.5.0-5.amzn2023.0.5
gcc-c++-11.5.0-5.amzn2023.0.5
glibc-devel-2.34-231.amzn2023.0.4
golang-1.25.10-1.amzn2023.0.1
```

That already differs from the checked `kmstool_enclave_cli`, which contains a GCC `11.4.1` marker. The Dockerfile also failed today while building `aws-nitro-enclaves-nsm-api` because it runs Cargo 1.63 against live crates.io without a `Cargo.lock`:

```text
Downloaded serde_core v1.0.228
Downloaded log v0.4.30
Downloaded getrandom v0.4.2
error: failed to parse manifest at .../getrandom-0.4.2/Cargo.toml
Caused by:
  this version of Cargo is older than the `2024` edition
```

Conclusion: for `libnsm.so` and `kmstool_enclave_cli`, the evidence points to the expected high-level source versions but an under-specified, time-varying build environment. The committed recipe lacks at least:

- a pinned Amazon Linux base image digest from the production build
- pinned RPM repository snapshots/package NEVRAs
- a Cargo lockfile or vendored Rust dependency set for `aws-nitro-enclaves-nsm-api`
- source-controlled build metadata sufficient to recreate the exact `/tmp/crt-builder` toolchain state

So the Nitro C binaries are not reproducible from the public committed source recipe as it stands.

## Source-Only Caveats

This is source-derived at the application/EIF payload level, not a proof of a source-only universe.

Remaining trust roots and caveats:

- The live deployment still matches the repo's checked-in binary EIF, not the source-derived EIF.
- The checked-in Nitro binaries are not byte-for-byte reproduced from source by this build, and the original Dockerfile recipe now fails because Rust dependencies are not locked.
- The checked-in `tinfoil-proxy` is byte-for-byte reproducible from source when built on aarch64 Linux from the embedded commit with Go 1.26.1 and a dirty worktree marker. The source commit is not currently reachable from GitHub `origin/master`, though the relevant Go source files match current `HEAD`.
- Upstream `aws-nitro-enclaves-nsm-api` v0.4.0 does not ship a `Cargo.lock`; I generated one and applied it as a patch for deterministic Nix builds.
- Nix binary substitutes were allowed during these builds. The derivations are source recipes, but this is not a from-bootstrap no-binary-substitutes build.
- AWS Nitro hardware, the Nitro hypervisor/runtime, NSM device implementation, CPU firmware/microcode, and AWS KMS are outside this source audit.
- `monzo/aws-nitro-util` contains AWS blob files in its source tree. This EIF uses a Nix-built custom Linux kernel and sets `nsmKo = null`; it uses the AWS kernel config text from that source tree and a source-built `eif-init`.

## Bottom Line

We know the live enclave's current PCRs, and they match the checked-binary production EIF built from this repo.

We do not have evidence that the live enclave corresponds to an application-level source-only rebuild. The source-derived EIF built here has different PCR0 and PCR2.
