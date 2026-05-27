#!/usr/bin/env node
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

const DEFAULT_SUMMARY = "proofs/live-attestation-summary.json";
const DEFAULT_ROUTER_REBUILD = "proofs/router-container-rebuild.json";
const DEFAULT_OUT = "proofs/tinfoil-chain-summary.json";

function parseArgs(argv) {
  const args = { summary: DEFAULT_SUMMARY, routerRebuild: DEFAULT_ROUTER_REBUILD, out: DEFAULT_OUT };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--summary") {
      if (!argv[i + 1]) throw new Error("--summary requires a path");
      args.summary = argv[++i];
    } else if (arg === "--router-rebuild") {
      if (!argv[i + 1]) throw new Error("--router-rebuild requires a path");
      args.routerRebuild = argv[++i];
    } else if (arg === "--out") {
      if (!argv[i + 1]) throw new Error("--out requires a path");
      args.out = argv[++i];
    } else if (arg === "-h" || arg === "--help") {
      console.log(`Usage: npm run audit:tinfoil -- [--summary ${DEFAULT_SUMMARY}] [--router-rebuild ${DEFAULT_ROUTER_REBUILD}] [--out ${DEFAULT_OUT}]

Reads the live PPQ router verification summary, then inventories the Tinfoil
router release, CVM image release, and downstream model/tool enclave releases.
The output classifies each link in the chain by what this audit can prove.`);
      process.exit(0);
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  return args;
}

async function fetchOk(url, options = {}) {
  const headers = { ...(options.headers ?? {}) };
  if (process.env.GITHUB_TOKEN && url.startsWith("https://api.github.com/")) {
    headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  }
  const res = await fetch(url, { ...options, headers });
  if (!res.ok) {
    throw new Error(`HTTP ${res.status} for ${url}`);
  }
  return res;
}

async function fetchJson(url, options = {}) {
  return (await fetchOk(url, {
    ...options,
    headers: {
      Accept: "application/vnd.github+json",
      ...(options.headers ?? {}),
    },
  })).json();
}

async function fetchText(url, options = {}) {
  return (await fetchOk(url, options)).text();
}

async function readJsonIfExists(path) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

async function githubRelease(repo, tag) {
  const data = await fetchJson(`https://api.github.com/repos/${repo}/releases/tags/${tag}`);
  return {
    repo,
    tag,
    url: data.html_url,
    targetCommitish: data.target_commitish,
    publishedAt: data.published_at,
    assets: (data.assets ?? []).map((asset) => ({
      name: asset.name,
      digest: asset.digest ?? null,
      size: asset.size,
      url: asset.browser_download_url,
    })),
  };
}

async function githubAttestationCount(repo, sha256) {
  if (!sha256) return 0;
  const digest = sha256.startsWith("sha256:") ? sha256 : `sha256:${sha256}`;
  try {
    const data = await fetchJson(`https://api.github.com/repos/${repo}/attestations/${digest}`);
    return data.attestations?.length ?? 0;
  } catch (error) {
    if (String(error.message).includes("HTTP 404")) return 0;
    throw error;
  }
}

function assetByName(release, name) {
  return release.assets.find((asset) => asset.name === name) ?? null;
}

async function fetchReleaseTextAsset(release, name) {
  const asset = assetByName(release, name);
  if (!asset?.url) return null;
  return fetchText(asset.url);
}

function decodeDeploymentConfig(deployment) {
  if (!deployment?.config) return null;
  return Buffer.from(deployment.config, "base64").toString("utf8");
}

function allMatches(text, regex) {
  if (!text) return [];
  return [...text.matchAll(regex)].map((match) => match[1]).filter(Boolean);
}

function extractConfigRefs(configText) {
  const containerImages = allMatches(configText, /^\s*image:\s*["']?([^"'\s]+)["']?/gm);
  const modelRefs = allMatches(configText, /^\s*repo:\s*["']?([^"'\n]+)["']?/gm);
  const cvmVersion = configText?.match(/^cvm-version:\s*([^\s]+)/m)?.[1] ?? null;
  return {
    cvmVersion: cvmVersion ? (cvmVersion.startsWith("v") ? cvmVersion : `v${cvmVersion}`) : null,
    containerImages,
    modelRefs,
  };
}

function modelRefClassification(ref) {
  if (!ref) return null;
  if (ref.includes("@")) return "MODEL-HASH";
  return "OPAQUE";
}

function uniqueModelReleases(routerStatus) {
  const seen = new Set();
  const entries = [];
  for (const [name, model] of Object.entries(routerStatus?.models ?? {})) {
    const key = `${model.repo}@${model.tag}`;
    if (!seen.has(key)) {
      seen.add(key);
      entries.push({ name, repo: model.repo, tag: model.tag });
    }
  }
  return entries.sort((a, b) => `${a.repo}@${a.tag}`.localeCompare(`${b.repo}@${b.tag}`));
}

function parseGhcrImage(imageRef) {
  const match = imageRef?.match(/^ghcr\.io\/([^@]+?)(?::[^/@]+)?@sha256:([a-f0-9]{64})$/);
  if (!match) return null;
  return {
    repository: match[1],
    digest: `sha256:${match[2]}`,
  };
}

async function ghcrToken(repository) {
  const data = await fetchJson(`https://ghcr.io/token?service=ghcr.io&scope=repository:${repository}:pull`);
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

async function auditContainerImage(imageRef) {
  if (!imageRef?.includes("@sha256:")) {
    return {
      image: imageRef,
      registry: imageRef?.split("/")[0] ?? null,
      classification: "OPAQUE",
      reason: "image is not pinned by digest",
    };
  }

  const ghcr = parseGhcrImage(imageRef);
  if (!ghcr) {
    return {
      image: imageRef,
      registry: imageRef.split("/")[0],
      classification: "HASH-ONLY",
      reason: "digest-pinned non-GHCR image; provenance not queried by this script",
    };
  }

  try {
    const token = await ghcrToken(ghcr.repository);
    const rootManifest = await ghcrManifest(ghcr.repository, ghcr.digest, token);
    const manifests = rootManifest.manifests ?? [];
    const imageManifest = manifests.find((entry) => (
      entry.platform?.os === "linux" && entry.platform?.architecture === "amd64"
    ));
    const attestationManifest = manifests.find((entry) => (
      entry.annotations?.["vnd.docker.reference.type"] === "attestation-manifest"
    ));

    let slsa = null;
    if (attestationManifest?.digest) {
      const attestation = await ghcrManifest(ghcr.repository, attestationManifest.digest, token);
      const slsaLayer = attestation.layers?.find((layer) => (
        layer.annotations?.["in-toto.io/predicate-type"] === "https://slsa.dev/provenance/v1"
      ));
      if (slsaLayer?.digest) {
        const statement = JSON.parse(await ghcrBlob(ghcr.repository, slsaLayer.digest, token));
        slsa = {
          subject: statement.subject ?? null,
          buildType: statement.predicate?.buildDefinition?.buildType ?? null,
          vcs: statement.predicate?.runDetails?.metadata?.buildkit_metadata?.vcs ?? null,
          builder: statement.predicate?.runDetails?.builder ?? null,
          buildkitCompleteness: statement.predicate?.runDetails?.metadata?.buildkit_completeness ?? null,
        };
      }
    }

    return {
      image: imageRef,
      registry: "ghcr.io",
      repository: ghcr.repository,
      digest: ghcr.digest,
      imageManifestDigest: imageManifest?.digest ?? (rootManifest.config ? ghcr.digest : null),
      attestationManifestDigest: attestationManifest?.digest ?? null,
      classification: slsa ? "BINARY-PROVENANCE" : "HASH-ONLY",
      reason: slsa ? "attached SLSA provenance found" : "no attached SLSA provenance found",
      slsa,
    };
  } catch (error) {
    return {
      image: imageRef,
      registry: "ghcr.io",
      repository: ghcr.repository,
      digest: ghcr.digest,
      classification: "HASH-ONLY",
      reason: `GHCR provenance query failed: ${error.message}`,
    };
  }
}

async function auditModelRelease(entry) {
  const release = await githubRelease(entry.repo, entry.tag);
  const hashText = await fetchReleaseTextAsset(release, "tinfoil.hash");
  const releaseDigest = hashText?.trim() ?? null;
  const deploymentText = await fetchReleaseTextAsset(release, "tinfoil-deployment.json");
  const deployment = deploymentText ? JSON.parse(deploymentText) : null;
  const configText = decodeDeploymentConfig(deployment);
  const refs = extractConfigRefs(configText);
  const attestationCount = await githubAttestationCount(entry.repo, releaseDigest);

  return {
    repo: entry.repo,
    tag: entry.tag,
    releaseUrl: release.url,
    releaseDigest,
    releaseAttestationCount: attestationCount,
    classification: attestationCount > 0 ? "BINARY-PROVENANCE" : "HASH-ONLY",
    measurement: {
      snp: deployment?.snp_measurement ?? null,
      tdx: deployment?.tdx_measurement ?? null,
      hashes: deployment?.hashes ?? null,
    },
    cvmVersion: refs.cvmVersion,
    containerImages: refs.containerImages.map((image) => ({
      image,
      classification: image?.includes("@sha256:") ? "HASH-ONLY" : "OPAQUE",
    })),
    modelRefs: refs.modelRefs.map((ref) => ({
      ref,
      classification: modelRefClassification(ref),
    })),
  };
}

async function auditCvmRelease(version) {
  const release = await githubRelease("tinfoilsh/cvmimage", version);
  const manifestAsset = release.assets.find((asset) => asset.name.endsWith("-manifest.json")) ?? null;
  const manifestText = manifestAsset ? await fetchText(manifestAsset.url) : null;
  const manifest = manifestText ? JSON.parse(manifestText) : null;
  const manifestSha = manifestAsset?.digest?.replace(/^sha256:/, "") ?? null;
  const attestationCount = await githubAttestationCount("tinfoilsh/cvmimage", manifestSha);

  return {
    repo: "tinfoilsh/cvmimage",
    tag: version,
    releaseUrl: release.url,
    manifestAsset,
    releaseAttestationCount: attestationCount,
    classification: attestationCount > 0 ? "BINARY-PROVENANCE" : "HASH-ONLY",
    manifest,
  };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const liveSummary = JSON.parse(await readFile(args.summary, "utf8"));
  const routerRebuild = await readJsonIfExists(args.routerRebuild);

  const routerReleaseTag = liveSummary.sigstore?.releaseTag;
  const routerRelease = await githubRelease("tinfoilsh/confidential-model-router", routerReleaseTag);
  const routerAttestations = await githubAttestationCount(
    "tinfoilsh/confidential-model-router",
    liveSummary.live?.releaseDigest,
  );
  const cvmVersion = liveSummary.deployment?.hashes?.version;
  const cvm = await auditCvmRelease(cvmVersion);

  const modelEntries = uniqueModelReleases(liveSummary.routerStatus);
  const modelReleases = [];
  for (const entry of modelEntries) {
    modelReleases.push(await auditModelRelease(entry));
  }

  const allContainerImages = new Map();
  for (const release of modelReleases) {
    for (const image of release.containerImages) {
      allContainerImages.set(image.image, image.classification);
    }
  }

  const allModelRefs = new Map();
  for (const release of modelReleases) {
    for (const ref of release.modelRefs) {
      allModelRefs.set(ref.ref, ref.classification);
    }
  }

  const containerImageAudits = [];
  for (const image of [...allContainerImages.keys()].sort()) {
    containerImageAudits.push(await auditContainerImage(image));
  }
  const containerClassifications = new Map(
    containerImageAudits.map((entry) => [entry.image, entry.classification]),
  );
  for (const release of modelReleases) {
    for (const image of release.containerImages) {
      image.classification = containerClassifications.get(image.image) ?? image.classification;
    }
  }

  const output = {
    checkedAt: new Date().toISOString(),
    sourceSummary: args.summary,
    classifications: {
      "SOURCE-REPRO": "rebuilt from source and matched the live hash",
      "SOURCE-BINARY-REPRO": "rebuilt the main executable from source, but container metadata/layer hash did not match",
      "BINARY-PROVENANCE": "signed/pinned artifact with provenance, not source-rebuilt here",
      "HASH-ONLY": "pinned digest/ref but no source rebuild/provenance verified here",
      "MODEL-HASH": "model weights accepted by immutable repo/ref, not rebuildable as source",
      "OPAQUE": "no useful public identity found",
      "BROKEN": "claimed source recipe was tried and did not reproduce",
    },
    router: {
      repo: "tinfoilsh/confidential-model-router",
      tag: routerReleaseTag,
      releaseUrl: routerRelease.url,
      releaseDigest: liveSummary.live?.releaseDigest,
      releaseAttestationCount: routerAttestations,
      sourceCommitFromImageProvenance: liveSummary.registry?.slsa?.vcs?.revision ?? null,
      image: liveSummary.deployment?.image ?? null,
      imageManifestDigest: liveSummary.registry?.imageManifestDigest ?? null,
      build: liveSummary.registry?.slsa?.builder ?? null,
      sourceRebuild: routerRebuild,
      classification: routerRebuild?.classification ?? (routerAttestations > 0 ? "BINARY-PROVENANCE" : "HASH-ONLY"),
    },
    cvm,
    downstreamModelReleases: modelReleases,
    downstreamContainerImages: containerImageAudits,
    downstreamModelRefs: [...allModelRefs.entries()].sort().map(([ref, classification]) => ({
      ref,
      classification,
    })),
  };

  const out = resolve(args.out);
  await mkdir(dirname(out), { recursive: true });
  await writeFile(out, `${JSON.stringify(output, null, 2)}\n`);
  console.log(`wrote ${out}`);
}

main().catch((error) => {
  console.error(error.stack || error.message || String(error));
  process.exit(1);
});
