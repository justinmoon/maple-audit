# TEE Provider Audits

This repo collects small, reproducible checks for AI products that claim TEE-backed private inference.

## Providers

- [`maple`](maple): Maple/OpenSecret Nitro Enclave audit. The live Nitro PCRs matched the checked production EIF, but the available public source recipe did not reproduce that EIF. The missing piece is upstream AWS Nitro C binary build provenance.
- [`ppq`](ppq): PPQ private model audit. The live PPQ private endpoint verified as a Tinfoil router enclave release with Sigstore-backed provenance, and the router reports verified downstream Tinfoil model enclaves. This is stronger than Maple's source/EIF mismatch, but it is still not a full source-only rebuild of every container/model artifact.

Each provider directory contains the scripts and captured proof summaries for that provider.
