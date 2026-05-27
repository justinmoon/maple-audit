# Tinfoil Chain Audit

This is the current PPQ/Tinfoil trust-chain breakdown. It starts at PPQ's private endpoint and stops before trying to rebuild third-party vLLM/CUDA/Python stacks.

## What The Router Is

The router container is Tinfoil's Go service at <https://github.com/tinfoilsh/confidential-model-router>. PPQ's local proxy asks the Tinfoil SDK to verify `https://api.ppq.ai/private/attestation`, then sends encrypted requests through the verified router.

The router is not a model server. It is the in-enclave control/proxy layer that:

- loads Tinfoil model config repos and release measurements;
- verifies model release Sigstore attestations;
- fetches live downstream enclave attestations;
- compares live measurements against release measurements;
- pins outbound TLS to each downstream enclave's attested TLS key;
- reverse-proxies API requests to the selected downstream model/tool enclave.

## Current Classification

Classification meanings are recorded in [`proofs/tinfoil-chain-summary.json`](proofs/tinfoil-chain-summary.json).

Current results:

- Router release: `SOURCE-BINARY-REPRO`
- CVM image release: `BUILD-FORMULA-BROKEN`
- Downstream Tinfoil model/tool release configs: 14 `BINARY-PROVENANCE`
- Downstream container images: 6 `BINARY-PROVENANCE`, 7 `HASH-ONLY`
- Model weight refs: 14 `MODEL-HASH`

## Router Container Rebuild

Live router:

- repo: `tinfoilsh/confidential-model-router`
- source commit from image provenance: `4ad5a7229fdd37f5d270b56a92dfb23a3fb2b562`
- release tag: `v0.0.104`
- live index digest: `sha256:3c8fb768331fd298e3bdc44a441c5ec8261a749aaf330c8628dc5df3232d0287`
- live linux/amd64 image manifest digest: `sha256:3de81dd9fbbc005bdd2fc1e2712892c575fae46cc5b88f7169b7253eeef09963`

Rebuild result from [`scripts/rebuild-router-container.sh`](scripts/rebuild-router-container.sh):

- local image manifest digest: `sha256:9f4836532c11903528733d5935815a44950f7776d5f44bcb87d18a069c2d2d7f`
- manifest matched: no
- local `/app/proxy` sha256: `4319a7932dd64e8421d22a312ceba38c08dd1f7556a58cf15a3203953e976b3e`
- live `/app/proxy` sha256: `4319a7932dd64e8421d22a312ceba38c08dd1f7556a58cf15a3203953e976b3e`
- proxy binary matched: yes

The first two image layers matched the live image. The application layer did not match as a compressed tar layer because its file mtimes came from the build time. The rebuilt executable itself is byte-for-byte identical to the live executable extracted from GHCR.

So this is not a full container digest reproduction, but it is a source reproduction of the main router binary.

## CVM Image

The router attestation uses Tinfoil CVM image `v0.7.5` from <https://github.com/tinfoilsh/cvmimage/releases/tag/v0.7.5>.

The live attested hashes match that release manifest:

- root: `5c1f3121fb34dbf8b55d35abbd328daaab589f1e2566bc6c99afdc231d705f59`
- initrd: `1bb89997c15dd48e67b79431079505262da64df0cad11c12f0994fac8d61bd97`
- kernel: `39cc3d97d415d99523754af0203f3951fa3bfdace5f3387926ccf2a7fd4fc8f0`
- raw disk: `684b5b68b43495f0a4aef1db8bbd79fcd9040852444329c560951455cd55b181`

The CVM release has GitHub build attestations for the manifest and downloadable artifacts. I attempted the source rebuild with [`scripts/rebuild-cvmimage.sh`](scripts/rebuild-cvmimage.sh), using:

- source tag/commit: `v0.7.5` / `35d3e393d822ca0fa5eab4cc2edd651c8ded2d77`
- `mkosi` commit: `54c625c380ef5500f17460981a3c67b109b6a847` (`mkosi 25.3`)
- Go version available in the build environment: `go1.25.5`

Result from [`proofs/cvmimage-rebuild.json`](proofs/cvmimage-rebuild.json): `BUILD-FORMULA-BROKEN`.

The build reached `mkosi` and failed during apt dependency resolution. The public recipe pins some NVIDIA/container package versions, but uses live external NVIDIA/container repositories. Current public repo metadata wants:

- `nvidia-container-toolkit-base=1.19.1-1` while the recipe pins `nvidia-container-toolkit=1.19.0-1`
- NVIDIA `580.159.04` dependency packages while the recipe pins `nvidia-driver-580-open=580.126.20-1ubuntu1`

So the public `v0.7.5` source formula no longer builds from public inputs. That is worse than a hash mismatch: we cannot currently produce a local CVM image hash to compare against the attested release hash.

## Downstream Releases

The live router reported 17 model/tool names backed by 14 unique Tinfoil config releases. Every release had `tinfoil.hash`, `tinfoil-deployment.json`, and a GitHub attestation for the deployment digest.

Those releases are deployment/config provenance, not source-only rebuilds of every runtime image. The configs pin container images and, where relevant, model weight refs.

## Remaining Hash-Only Containers

These are still binary trust roots at this layer:

- `ghcr.io/huggingface/text-embeddings-inference@sha256:346a39baecdd03c40e77184c66a4a9931ec2e25b8e57ff3766b79affdbd38673`
- `ghcr.io/tinfoilsh/vllm-openai-audio:v0.0.11@sha256:5c91900505727f91a32a533be9715123e703ea6ffcd7888239b0ebc2fd976d50`
- `vllm/vllm-openai:glm51-cu130@sha256:bdc161fa9c43539656211239260c193f72c165aeaaba8d1383dba98cef99a86f`
- `vllm/vllm-openai:v0.17.0-cu130@sha256:de06f6d78a2ce86856094a643d6c914d8bd7109f73c2e30f38097197b2f2bba1`
- `vllm/vllm-openai:v0.17.1-cu130@sha256:bbeaaf81ba5704c30f6b87a5df5b10b930d97e916fc98c825d3ad30806e9638b`
- `vllm/vllm-openai:v0.20.0-cu130-ubuntu2404@sha256:aff65d7198dd284c37dd0a18a606544cc5e92bfb0d5eb608b77e8b8f1c6b8b0d`
- `vllm/vllm-openai:v0.21.0-ubuntu2404@sha256:b0ac5da3f45ae5bfacb72e69b5bfd6150c22bd9cf4fc2c839400395106a5cc4e`

## Reproduce

```sh
cd ppq
npm ci
npm run verify -- --out proofs/live-attestation-summary.json
scripts/rebuild-router-container.sh
scripts/rebuild-cvmimage.sh
npm run audit:tinfoil -- --out proofs/tinfoil-chain-summary.json
```

The router rebuild script uses a temporary Docker config and does not read macOS keychain credentials. The CVM rebuild script must run on x86_64 Linux with passwordless `sudo`; on NixOS it enters a Nix shell and uses a private mount namespace to provide the Ubuntu-style host tools that `mkosi` expects.
