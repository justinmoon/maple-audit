# PPQ Private TEE Model Audit

This checks PPQ's claim that private models use TEE-backed, end-to-end encrypted inference.

PPQ sources:

- Blog: <https://ppq.ai/blog/introducing-tee-models>
- API docs: <https://ppq.ai/api-docs>
- Local proxy source: <https://github.com/PayPerQ/ppq-private-mode-proxy>

## Finding

The PPQ private endpoint is not just trusting PPQ's server. The PPQ proxy delegates attestation to the Tinfoil SDK, which verifies a live bundle from `https://api.ppq.ai/private/attestation` against `tinfoilsh/confidential-model-router`. I inspected `PayPerQ/ppq-private-mode-proxy` at `bbb372bc69b7e435dcc424a07bd4e9749485e850`; it calls `SecureClient.ready()` and relies on Tinfoil's default router verification rather than pinning a PPQ-specific measurement itself.

On 2026-05-27, the live bundle verified successfully:

- enclave host: `router.inf6.tinfoil.sh`
- router release: `v0.0.104`
- release digest: `ebb921d8572bc8f6b4e04812a7e65bffcf6ac1a2fabe8a55115a13d61e901b85`
- SEV-SNP measurement: `b126c633a662ee13b77c8ff21cb29b9ac2da92674d290298a52b259fc74f6e9ed4691ffb240587834777a52d24e19f69`
- router image: `ghcr.io/tinfoilsh/confidential-model-router@sha256:3c8fb768331fd298e3bdc44a441c5ec8261a749aaf330c8628dc5df3232d0287`

The pinned router image's attached BuildKit/SLSA provenance links the linux/amd64 image manifest to:

- source repo: `https://github.com/tinfoilsh/confidential-model-router`
- source commit: `4ad5a7229fdd37f5d270b56a92dfb23a3fb2b562`
- build run: `https://github.com/tinfoilsh/confidential-model-router/actions/runs/26370856087/attempts/1`
- release publish run: `https://github.com/tinfoilsh/confidential-model-router/actions/runs/26370884536/attempts/1`

The router is not the whole inference stack. Its status endpoint reported 17 downstream Tinfoil model/tool enclaves, each with a public Tinfoil config repo, release tag, measurement, and enclave hostname. The router source verifies those downstream attestations before proxying: it fetches the repo release digest and Sigstore bundle, verifies the release measurement, verifies each remote enclave attestation, compares the measurements, and pins outbound TLS to the attested key.

## Limits

This does prove the live PPQ private entrypoint is a Tinfoil-attested router release, and it gives the current code/config identity for the downstream model enclaves.

This does not prove a source-only rebuild of the full stack. At router release `v0.0.104`, the Dockerfile used mutable base tags (`golang:1.25-alpine`, `alpine:latest`); the registry provenance records the base image digests resolved during the build, but `buildkit_completeness.resolvedDependencies` is `false`. I rebuilt the router executable byte-for-byte, but not the full container manifest.

The Tinfoil CVM image is worse: `scripts/rebuild-cvmimage.sh` attempted the public `tinfoilsh/cvmimage@v0.7.5` recipe and the build no longer resolves from public package repositories. The failure is in live external NVIDIA/container apt repos whose current dependency metadata no longer matches the pinned versions in the recipe.

Downstream model repos are public Tinfoil deployment/config repos that pin container image digests and model weight refs; they are not, by themselves, source-only rebuilds of every container, CUDA library, vLLM image, or model weight artifact. For example, `tinfoilsh/confidential-gpt-oss-120b@v0.0.22` is a deployment config that pins `vllm/vllm-openai:v0.17.0-cu130@sha256:de06f6d78a2ce86856094a643d6c914d8bd7109f73c2e30f38097197b2f2bba1` and `openai/gpt-oss-120b@b5c939de8f754692c1647ca79fbf85e8c1e70f8a`, not a from-source rebuild recipe for those artifacts.

Bottom line: PPQ/Tinfoil gives a live cryptographic proof of the deployed enclave measurements and links them to public release/config provenance. I can identify what deployment artifacts are running today. I did not prove that every artifact can be rebuilt from source to the same hashes.

## Reproduce

```sh
cd ppq
npm ci
npm run verify -- --out proofs/live-attestation-summary.json
scripts/rebuild-router-container.sh
scripts/rebuild-cvmimage.sh
npm run audit:tinfoil -- --out proofs/tinfoil-chain-summary.json
```

The verification script:

- fetches the live PPQ attestation bundle;
- verifies the SEV-SNP attestation, Sigstore release provenance, measurement equality, and enclave certificate with `@tinfoilsh/verifier`;
- decodes the signed `tinfoil-deployment.json` payload;
- fetches router status from the verified Tinfoil host;
- queries GHCR anonymously for the pinned router image manifest and attached SLSA provenance.

The router rebuild script uses Docker with a temporary Docker config so it does not read macOS keychain credentials.

Current captured outputs: [`proofs/live-attestation-summary.json`](proofs/live-attestation-summary.json), [`proofs/router-container-rebuild.json`](proofs/router-container-rebuild.json), [`proofs/cvmimage-rebuild.json`](proofs/cvmimage-rebuild.json).

Tinfoil chain details: [`TINFOIL_CHAIN_AUDIT.md`](TINFOIL_CHAIN_AUDIT.md).
