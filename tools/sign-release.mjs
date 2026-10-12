#!/usr/bin/env node
// Sign / verify DAppNode release directories (signature.json), matching
// dappmanager's packages/toolkit/dist/repository/releaseSignature.js and
// repository.js exactly: filter out signature.json, sort by name, map each
// entry to `${name} ${cid at signature.cid.version/base}`, join with "\n",
// and verify with ethers' personal_sign recovery.
//
// Run inside a node:22-alpine container attached to the DAppNode `dncore_network` (dependencies: tools/package.json):
//   docker run --rm --network dncore_network -v "$PWD/tools":/app -w /app node:22-alpine \
//     sh -c "npm install --no-audit --no-fund >/dev/null && node sign-release.mjs <cmd> ..."
// The message to sign is printed with a trailing newline for readability; sign it without (tools/sign.html does).

import { ethers } from "ethers";
import { CID } from "multiformats/cid";
import { base58btc } from "multiformats/bases/base58";
import { base32 } from "multiformats/bases/base32";
import { base64, base64url } from "multiformats/bases/base64";

const IPFS_API = process.env.IPFS_API || "http://ipfs.dappnode:5001";
const SIGNATURE_FILE_RE = /^signature\.json$/;
const SIGNATURE_PROTOCOL = "ECDSA_256";

async function ipfsApi(path, init) {
  const res = await fetch(`${IPFS_API}${path}`, { method: "POST", ...init });
  if (!res.ok) {
    throw new Error(`IPFS API ${path} -> ${res.status} ${await res.text()}`);
  }
  return res;
}

/** List a directory CID, returning [{ name, cid: CID }], like dappmanager's listResult.entries. */
async function listDirectory(rootCid) {
  const json = await (await ipfsApi(`/api/v0/ls?arg=${rootCid}`)).json();
  const object = json.Objects?.[0];
  if (!object) throw new Error(`Not a directory CID: ${rootCid}`);
  return object.Links.map((link) => ({ name: link.Name, cid: CID.parse(link.Hash) }));
}

async function catJson(cid) {
  const text = await (await ipfsApi(`/api/v0/cat?arg=${cid}`)).text();
  return JSON.parse(text);
}

function getCidAtVersion(cid, version) {
  switch (version) {
    case 0:
      return cid.toV0();
    case 1:
      return cid.toV1();
    default:
      throw new Error(`Unknown CID version ${version}`);
  }
}

function cidToString(cid, base) {
  switch (base) {
    case "base58btc":
      return cid.toString(base58btc);
    case "base32":
      return cid.toString(base32);
    case "base64":
      return cid.toString(base64);
    case "base64url":
      return cid.toString(base64url);
    default:
      throw new Error(`Unknown CID base ${base}`);
  }
}

/** Exact port of dappmanager's serializeIpfsDirectory. */
function serializeIpfsDirectory(files, opts) {
  return files
    .filter((file) => !SIGNATURE_FILE_RE.test(file.name))
    .sort((a, b) => a.name.localeCompare(b.name))
    .map((file) => `${file.name} ${cidToString(getCidAtVersion(file.cid, opts.version), opts.base)}`)
    .join("\n");
}

async function findSignature(entries) {
  const sigEntry = entries.find((e) => SIGNATURE_FILE_RE.test(e.name));
  if (!sigEntry) return undefined;
  return catJson(sigEntry.cid.toString());
}

function parseCidOpts(args) {
  const version = args.version !== undefined ? Number(args.version) : 0;
  const base = args.base || "base58btc";
  return { version, base };
}

async function cmdMessage(rootCid, args) {
  const opts = parseCidOpts(args);
  const entries = await listDirectory(rootCid);
  const message = serializeIpfsDirectory(entries, opts);
  process.stdout.write(message + "\n");
  console.error(`\n# Sign with: cast wallet sign "$(node sign-release.mjs message ${rootCid})"`);
  console.error(`# (or any personal_sign / eth_sign-compatible signer over the exact bytes above, no trailing newline)`);
}

async function cmdVerify(rootCid, expectedAddress) {
  const entries = await listDirectory(rootCid);
  const signature = await findSignature(entries);
  if (!signature) {
    console.error(`No signature.json found in ${rootCid}`);
    process.exit(1);
  }
  if (signature.signature_protocol !== SIGNATURE_PROTOCOL) {
    console.error(`Unsupported signature_protocol ${signature.signature_protocol}`);
    process.exit(1);
  }
  const message = serializeIpfsDirectory(entries, signature.cid);
  const signer = ethers.verifyMessage(message, signature.signature);
  console.log(signer);
  if (expectedAddress && signer.toLowerCase() !== expectedAddress.toLowerCase()) {
    console.error(`Mismatch: expected ${expectedAddress}, recovered ${signer}`);
    process.exit(1);
  }
}

/** Write `content` as a file into IPFS MFS at `mfsPath` (creating it). Returns the file's own CID. */
async function mfsWriteFile(mfsPath, content) {
  const form = new FormData();
  form.append("file", new Blob([content]), "file");
  const res = await ipfsApi(
    `/api/v0/files/write?arg=${encodeURIComponent(mfsPath)}&create=true&parents=true`,
    { body: form }
  );
  await res.text();
}

async function mfsStatHash(mfsPath) {
  const json = await (await ipfsApi(`/api/v0/files/stat?arg=${encodeURIComponent(mfsPath)}&hash=true`)).json();
  return json.Hash;
}

async function cmdAssemble(rootCid, signatureHex, args) {
  const opts = parseCidOpts(args);
  const entries = await listDirectory(rootCid);
  if (entries.some((e) => SIGNATURE_FILE_RE.test(e.name))) {
    throw new Error(`${rootCid} already contains a signature.json; assemble expects an unsigned release`);
  }
  const message = serializeIpfsDirectory(entries, opts);
  const signature = {
    version: 1,
    cid: opts,
    signature_protocol: SIGNATURE_PROTOCOL,
    signature: signatureHex,
  };

  const mfsDir = `/sign-release-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  await ipfsApi(`/api/v0/files/cp?arg=${encodeURIComponent(`/ipfs/${rootCid}`)}&arg=${encodeURIComponent(mfsDir)}`);
  try {
    await mfsWriteFile(`${mfsDir}/signature.json`, JSON.stringify(signature, null, 2));
    const newRootCid = await mfsStatHash(mfsDir);
    await ipfsApi(`/api/v0/pin/add?arg=${newRootCid}`);

    const newEntries = await listDirectory(newRootCid);
    const newSignature = await findSignature(newEntries);
    const recomputed = serializeIpfsDirectory(newEntries, newSignature.cid);
    const signer = ethers.verifyMessage(recomputed, newSignature.signature);

    console.log(newRootCid);
    console.error(`# signer: ${signer}`);
  } finally {
    await ipfsApi(`/api/v0/files/rm?arg=${encodeURIComponent(mfsDir)}&recursive=true`);
  }
}

function parseFlags(argv) {
  const positional = [];
  const flags = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg.startsWith("--")) {
      flags[arg.slice(2)] = argv[++i];
    } else {
      positional.push(arg);
    }
  }
  return { positional, flags };
}

function usage() {
  console.error(`Usage:
  sign-release.mjs message <rootCid> [--version 0] [--base base58btc]
  sign-release.mjs assemble <rootCid> <signatureHex> [--version 0] [--base base58btc]
  sign-release.mjs verify <rootCid> [expectedAddress]

Env: IPFS_API (default http://ipfs.dappnode:5001)`);
}

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  const { positional, flags } = parseFlags(rest);

  switch (cmd) {
    case "message":
      if (!positional[0]) return usage(), process.exit(1);
      return cmdMessage(positional[0], flags);
    case "assemble":
      if (!positional[0] || !positional[1]) return usage(), process.exit(1);
      return cmdAssemble(positional[0], positional[1], flags);
    case "verify":
      if (!positional[0]) return usage(), process.exit(1);
      return cmdVerify(positional[0], positional[1]);
    default:
      usage();
      process.exit(1);
  }
}

main().catch((err) => {
  console.error(err.stack || err.message || err);
  process.exit(1);
});
