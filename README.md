# Maple / OpenSecret EIF Reproducibility Audit

This repo records a focused reproducibility check of the OpenSecret/Maple production Nitro Enclave image.

What I did:

- Verified a live attestation from `https://enclave.trymaple.ai`.
- Confirmed the live PCRs match the repo's checked-binary production EIF.
- Built a source-derived EIF from the available public source.
- Compared the source-derived binaries and PCRs against the checked production artifacts.

Finding:

- `continuum-proxy` reproduced byte-for-byte from source.
- `tinfoil-proxy` reproduced byte-for-byte when built on Linux arm64 with Go 1.26.1, the embedded commit, and the same dirty Git state.
- The AWS Nitro C pieces, especially `libnsm.so` and `kmstool_enclave_cli`, did not reproduce from the committed build formula.

The Nitro source refs appear broadly correct, but the build formula is unclear and under-specified: it relies on mutable Amazon Linux images/RPM repositories and an unlocked Cargo dependency graph for `aws-nitro-enclaves-nsm-api`. Re-running the Dockerfile today resolves different toolchain packages and fails because Cargo 1.63 pulls newer crates it cannot parse.

Bottom line: the live enclave matches the checked-in production EIF, but the public source/build recipe is not sufficient to independently reproduce the AWS Nitro binary chain or the full source-derived EIF.

See [`SOURCE_EIF_AUDIT.md`](SOURCE_EIF_AUDIT.md) for details.

## Reproduce the build

Prerequisites:

- Nix with flakes enabled.
- An `aarch64-linux` builder. On macOS this usually means a configured remote Linux builder; set `EXTRA_NIX_ARGS="--max-jobs 0"` if you want to force remote builds.

Run the one-command source-derived build:

```sh
scripts/reproduce-build.sh
```

The script clones the pinned OpenSecret commit, initializes submodules, applies [`patches/opensecret-source-build.patch`](patches/opensecret-source-build.patch), and builds:

- `eif-prod-source`: the source-derived EIF used in this audit

Expected hashes:

```text
2982295c13c5b92055b1f7593124cb7e6da93220d4fadd0c9496291e4044eca4  checked-binary EIF
04ce61d813dad461cfc0d0fd004d790fac2954b02ef7be9fbf23242a9abc34ce  source-derived EIF
```

This is the main "I tried to prove the source maps to the live enclave, and it does not" reproduction. The source-derived EIF reproducibly builds to the second hash, not the production hash.

What is missing to make the source build match production is not another local script; it is upstream build provenance for the AWS Nitro C binary chain: the exact Amazon Linux base digest, RPM repository/package snapshot, Cargo lockfile or vendored dependencies for `aws-nitro-enclaves-nsm-api`, and build metadata for the `/tmp/crt-builder` environment that produced the checked `libnsm.so` and `kmstool_enclave_cli`.
