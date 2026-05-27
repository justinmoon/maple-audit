# TEE Provider Audits

This repo collects small, reproducible checks for AI products that claim TEE-backed private inference.

## Providers

- [`maple`](maple): Maple/OpenSecret Nitro Enclave audit. The live Nitro PCRs matched the checked production EIF, but the available public source recipe did not reproduce that EIF. The missing piece is upstream AWS Nitro C binary build provenance.
- [`ppq`](ppq): PPQ private model audit. The live PPQ private endpoint verified as a Tinfoil router enclave release with Sigstore-backed provenance, and the router reports verified downstream Tinfoil model enclaves. The router executable rebuilt byte-for-byte, but the Tinfoil CVM image source formula no longer resolves from public NVIDIA/container apt repos, so this is not a full source-only rebuild.

Each provider directory contains the scripts and captured proof summaries for that provider.
