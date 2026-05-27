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
