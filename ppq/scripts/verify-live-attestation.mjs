#!/usr/bin/env node
import { X509Certificate } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { Verifier } from "@tinfoilsh/verifier";

const ATTESTATION_URL = process.env.PPQ_ATTESTATION_URL ?? "https://api.ppq.ai/private/attestation";
const CONFIG_REPO = process.env.TINFOIL_CONFIG_REPO ?? "tinfoilsh/confidential-model-router";

function parseArgs(argv) {
  const args = { out: null, includeBundle: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--out") {
      if (!argv[i + 1]) {
        throw new Error("--out requires a path");
      }
      args.out = argv[++i];
    } else if (arg === "--include-bundle") {
      args.includeBundle = true;
    } else if (arg === "-h" || arg === "--help") {
      console.log(`Usage: npm run verify -- [--out proofs/live-attestation-summary.json] [--include-bundle]

Fetches PPQ's live Tinfoil attestation bundle, verifies it with
@tinfoilsh/verifier, decodes the signed Tinfoil deployment payload, and queries
GHCR anonymously for provenance attached to the pinned router image.

Environment:
  PPQ_ATTESTATION_URL   default ${ATTESTATION_URL}
  TINFOIL_CONFIG_REPO   default ${CONFIG_REPO}`);
      process.exit(0);
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  return args;
}

async function fetchJson(url, options = {}) {
  const res = await fetch(url, options);
  if (!res.ok) {
    throw new Error(`HTTP ${res.status} for ${url}`);
  }
  return res.json();
}

async function fetchText(url, options = {}) {
  const res = await fetch(url, options);
  if (!res.ok) {
    throw new Error(`HTTP ${res.status} for ${url}`);
  }
  return res.text();
}

function decodeDssePayload(bundle) {
  const encoded = bundle?.sigstoreBundle?.dsseEnvelope?.payload;
  if (!encoded) {
    throw new Error("attestation bundle does not contain a DSSE payload");
  }
  return JSON.parse(Buffer.from(encoded, "base64").toString("utf8"));
}

function decodeConfig(payload) {
  const encoded = payload?.predicate?.config;
  if (!encoded) {
    return null;
  }
  return Buffer.from(encoded, "base64").toString("utf8");
}

function extractImageRef(configText) {
  if (!configText) {
    return null;
  }
  const match = configText.match(/image:\s*["']?([^"'\s]+)["']?/);
  return match?.[1] ?? null;
}

function parseGhcrImage(imageRef) {
  const match = imageRef?.match(/^ghcr\.io\/([^@]+)@sha256:([a-f0-9]{64})$/);
  if (!match) {
    return null;
  }
  return {
    repository: match[1],
    indexDigest: `sha256:${match[2]}`,
  };
}

async function ghcrToken(repository) {
  const url = `https://ghcr.io/token?service=ghcr.io&scope=repository:${repository}:pull`;
  const data = await fetchJson(url);
  if (!data.token) {
    throw new Error(`GHCR token response did not include token for ${repository}`);
  }
  return data.token;
}

async function ghcrManifest(repository, reference, token) {
  return fetchJson(`https://ghcr.io/v2/${repository}/manifests/${reference}`, {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.docker.distribution.manifest.v2+json",
      ].join(", "),
    },
  });
}

async function ghcrBlob(repository, digest, token) {
  return fetchText(`https://ghcr.io/v2/${repository}/blobs/${digest}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
}

async function fetchRegistryProvenance(imageRef) {
  const parsed = parseGhcrImage(imageRef);
  if (!parsed) {
    return null;
  }

  const token = await ghcrToken(parsed.repository);
  const index = await ghcrManifest(parsed.repository, parsed.indexDigest, token);
  const imageManifestRef = index.manifests?.find((entry) => (
    entry.platform?.os === "linux" && entry.platform?.architecture === "amd64"
  ));
  const attestationManifestRef = index.manifests?.find((entry) => (
    entry.annotations?.["vnd.docker.reference.type"] === "attestation-manifest"
  ));

  let imageConfig = null;
  let slsa = null;

  if (imageManifestRef?.digest) {
    const imageManifest = await ghcrManifest(parsed.repository, imageManifestRef.digest, token);
    if (imageManifest.config?.digest) {
      imageConfig = JSON.parse(await ghcrBlob(parsed.repository, imageManifest.config.digest, token));
    }
  }

  if (attestationManifestRef?.digest) {
    const attestationManifest = await ghcrManifest(parsed.repository, attestationManifestRef.digest, token);
    const slsaLayer = attestationManifest.layers?.find((layer) => (
      layer.annotations?.["in-toto.io/predicate-type"] === "https://slsa.dev/provenance/v1"
    ));
    if (slsaLayer?.digest) {
      slsa = JSON.parse(await ghcrBlob(parsed.repository, slsaLayer.digest, token));
    }
  }

  return {
    repository: parsed.repository,
    indexDigest: parsed.indexDigest,
    imageManifestDigest: imageManifestRef?.digest ?? null,
    attestationManifestDigest: attestationManifestRef?.digest ?? null,
    imageLabels: imageConfig?.config?.Labels ?? null,
    slsa: slsa ? {
      subject: slsa.subject ?? null,
      buildType: slsa.predicate?.buildDefinition?.buildType ?? null,
      resolvedDependencies: slsa.predicate?.buildDefinition?.resolvedDependencies ?? null,
      buildArgs: slsa.predicate?.buildDefinition?.externalParameters?.request?.args ?? null,
      vcs: slsa.predicate?.runDetails?.metadata?.buildkit_metadata?.vcs ?? null,
      builder: slsa.predicate?.runDetails?.builder ?? null,
      startedOn: slsa.predicate?.runDetails?.metadata?.startedOn ?? null,
      finishedOn: slsa.predicate?.runDetails?.metadata?.finishedOn ?? null,
      buildkitCompleteness: slsa.predicate?.runDetails?.metadata?.buildkit_completeness ?? null,
    } : null,
  };
}

async function fetchRouterStatus(domain) {
  if (!domain) {
    return null;
  }
  const status = await fetchJson(`https://${domain}/.well-known/tinfoil-proxy`);
  const models = {};
  for (const [name, model] of Object.entries(status.models ?? {})) {
    models[name] = {
      repo: model.repo ?? null,
      tag: model.tag ?? null,
      measurement: model.measurement ?? null,
      enclaves: Object.keys(model.enclaves ?? {}).sort(),
    };
  }
  return {
    version: status.version ?? null,
    updated: status.updated ?? null,
    errors: status.errors ?? null,
    models,
  };
}

function extractSigstoreCert(bundle) {
  const raw = bundle?.sigstoreBundle?.verificationMaterial?.certificate?.rawBytes;
  if (!raw) {
    return null;
  }
  const cert = new X509Certificate(Buffer.from(raw, "base64"));
  return {
    issuer: cert.issuer,
    subjectAltName: cert.subjectAltName,
    validFrom: cert.validFrom,
    validTo: cert.validTo,
    fingerprint256: cert.fingerprint256,
  };
}

function extractReleaseTag(subjectAltName) {
  const match = subjectAltName?.match(/@refs\/tags\/([^,\s]+)/);
  return match?.[1] ?? null;
}

function integratedTime(bundle) {
  const raw = bundle?.sigstoreBundle?.verificationMaterial?.tlogEntries?.[0]?.integratedTime;
  if (!raw) {
    return null;
  }
  const seconds = Number(raw);
  return Number.isFinite(seconds) ? new Date(seconds * 1000).toISOString() : raw;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const checkedAt = new Date().toISOString();

  const bundle = await fetchJson(ATTESTATION_URL);
  const verifier = new Verifier({ configRepo: CONFIG_REPO });
  await verifier.verifyBundle(bundle);
  const document = verifier.getVerificationDocument();
  const payload = decodeDssePayload(bundle);
  const configText = decodeConfig(payload);
  const imageRef = extractImageRef(configText);
  const sigstoreCert = extractSigstoreCert(bundle);
  const routerStatus = await fetchRouterStatus(bundle.domain);
  const registry = await fetchRegistryProvenance(imageRef);

  const summary = {
    checkedAt,
    attestationUrl: ATTESTATION_URL,
    configRepo: CONFIG_REPO,
    verified: document?.securityVerified === true,
    verificationSteps: document?.steps ?? null,
    live: {
      domain: bundle.domain,
      releaseDigest: bundle.digest,
      codeFingerprint: document?.codeFingerprint ?? null,
      enclaveFingerprint: document?.enclaveFingerprint ?? null,
      measurement: document?.enclaveMeasurement?.measurement ?? null,
    },
    sigstore: {
      subject: payload.subject ?? null,
      predicateType: payload.predicateType ?? null,
      certificate: sigstoreCert,
      releaseTag: extractReleaseTag(sigstoreCert?.subjectAltName),
      integratedTime: integratedTime(bundle),
    },
    deployment: {
      image: imageRef,
      cmdline: payload.predicate?.cmdline ?? null,
      hashes: payload.predicate?.hashes ?? null,
      config: configText,
    },
    routerStatus,
    registry,
  };

  if (args.includeBundle) {
    summary.attestationBundle = bundle;
  }

  const json = `${JSON.stringify(summary, null, 2)}\n`;
  if (args.out) {
    const out = resolve(args.out);
    await mkdir(dirname(out), { recursive: true });
    await writeFile(out, json);
    console.log(`wrote ${out}`);
  } else {
    process.stdout.write(json);
  }
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exit(1);
});
