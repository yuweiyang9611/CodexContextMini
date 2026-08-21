#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const emergencyEmailPattern = /[^\s<>"']+@[^\s<>"']+\.[A-Za-z]{2,}/gu;
function emergencyRedact(value) {
  return String(value).replace(emergencyEmailPattern, (address) => {
    const separator = address.indexOf("@");
    if (separator < 0) return "<redacted>";
    const local = address.slice(0, separator);
    return `${local.length <= 1 ? "*" : `${local[0]}***`}${address.slice(separator)}`;
  });
}
process.on("uncaughtException", (error) => {
  console.error(`Email privacy policy could not initialize: ${emergencyRedact(error?.message ?? error)}`);
  process.exit(2);
});
process.on("unhandledRejection", (error) => {
  console.error(`Email privacy policy could not initialize: ${emergencyRedact(error?.message ?? error)}`);
  process.exit(2);
});

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const policy = JSON.parse(readFileSync(resolve(scriptDirectory, "email-policy.json"), "utf8"));
const allowedLocal = compilePatterns(policy.allowedLocalGitEmailPatterns, "allowedLocalGitEmailPatterns");
const allowedCommit = compilePatterns(policy.allowedCommitEmailPatterns, "allowedCommitEmailPatterns");
const allowedContent = compilePatterns(policy.allowedContentEmailPatterns, "allowedContentEmailPatterns");
const maxBlobBytes = Number(policy.maxBlobBytes ?? 33_554_432);

const emailSource = String.raw`[A-Za-z0-9.!#$%&'*+/=?^_` + "`" + String.raw`{|}~\-\[\]]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+`;
const emailPattern = new RegExp(emailSource, "g");
const fullEmailPattern = new RegExp(`^(?:${emailSource})$`);
const zeroObjectPattern = /^0+$/u;
const objectIdPattern = /^[0-9a-f]{40,64}$/u;
const findings = new Map();
const scannedBlobs = new Set();
const scannedCommits = new Set();
const scannedTags = new Map();

const options = parseArguments(process.argv.slice(2));
const repositoryRoot = options.root ? resolve(options.root) : discoverRepositoryRoot();

function parseArguments(args) {
  const parsed = { mode: "repository", root: undefined, messageFile: undefined };
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index];
    if (value === "--mode") parsed.mode = requireValue(args, ++index, value).toLowerCase();
    else if (value === "--root") parsed.root = requireValue(args, ++index, value);
    else if (value === "--message-file") parsed.messageFile = requireValue(args, ++index, value);
    else throw new Error(`Unknown argument: ${value}`);
  }
  if (!["staged", "commit-message", "pre-push", "repository"].includes(parsed.mode)) {
    throw new Error(`Unsupported mode: ${parsed.mode}`);
  }
  return parsed;
}

function requireValue(args, index, flag) {
  if (index >= args.length || !args[index]) throw new Error(`${flag} requires a value.`);
  return args[index];
}

function compilePatterns(values, label) {
  if (!Array.isArray(values) || values.length === 0) throw new Error(`${label} must be a non-empty array.`);
  return values.map((value) => new RegExp(String(value), "iu"));
}

function discoverRepositoryRoot() {
  const result = spawnSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" });
  if (result.status !== 0) throw new Error("Email policy must run inside a Git worktree.");
  return resolve(result.stdout.trim());
}

function git(args, { allowed = [0], encoding = "utf8", maxBuffer = 64 * 1024 * 1024 } = {}) {
  const result = spawnSync("git", ["-C", repositoryRoot, ...args], { encoding, maxBuffer });
  if (result.error) throw result.error;
  if (!allowed.includes(result.status)) {
    const stderr = Buffer.isBuffer(result.stderr) ? result.stderr.toString("utf8") : String(result.stderr ?? "");
    throw new Error(`git ${args.join(" ")} failed with exit code ${result.status}: ${stderr.trim()}`);
  }
  return result;
}

function isAllowed(address, patterns) {
  return patterns.some((pattern) => pattern.test(address));
}

function redactEmails(value) {
  return String(value).replace(new RegExp(emailSource, "g"), (address) => maskEmail(address));
}

function addFinding(scope, location, address) {
  const safeLocation = redactEmails(location);
  findings.set(`${scope}\0${safeLocation}\0${address}`, { scope, location: safeLocation, address });
}

function scanText(text, scope, location, patterns = allowedContent) {
  emailPattern.lastIndex = 0;
  const addresses = new Set();
  for (const match of text.matchAll(emailPattern)) addresses.add(match[0]);
  for (const address of addresses) {
    if (!isAllowed(address, patterns)) addFinding(scope, location, address);
  }
}

function swapUtf16Bytes(buffer) {
  const evenLength = buffer.length - (buffer.length % 2);
  const swapped = Buffer.allocUnsafe(evenLength);
  for (let index = 0; index < evenLength; index += 2) {
    swapped[index] = buffer[index + 1];
    swapped[index + 1] = buffer[index];
  }
  return swapped;
}

function scanBuffer(buffer, scope, location) {
  scanText(buffer.toString("latin1"), scope, location);
  if (buffer.includes(0)) {
    scanText(buffer.toString("utf16le"), scope, `${location} (UTF-16LE)`);
    scanText(swapUtf16Bytes(buffer).toString("utf16le"), scope, `${location} (UTF-16BE)`);
  }
}

function assertIdentity(address, scope, location, patterns) {
  if (!address || !fullEmailPattern.test(address)) {
    addFinding(scope, location, "<missing-or-invalid>");
  } else if (!isAllowed(address, patterns)) {
    addFinding(scope, location, address);
  }
}

function objectType(objectId, allowedMissing = false) {
  const result = git(["cat-file", "-t", objectId], { allowed: allowedMissing ? [0, 1, 128] : [0] });
  return result.status === 0 ? result.stdout.trim() : undefined;
}

function scanBlob(objectId, location) {
  if (scannedBlobs.has(objectId)) return;
  scannedBlobs.add(objectId);
  const size = Number(git(["cat-file", "-s", objectId]).stdout.trim());
  if (!Number.isSafeInteger(size) || size < 0 || size > maxBlobBytes) {
    addFinding("content", location, `<blob-not-scanned:${size}>`);
    return;
  }
  const result = git(["cat-file", "blob", objectId], { encoding: null, maxBuffer: maxBlobBytes + 1024 });
  scanBuffer(result.stdout, "content", location);
}

function parseIdentityHeader(header, label, objectId) {
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  const match = header.match(new RegExp(`^${escaped} .* <([^<>\\r\\n]+)> \\d+ [+-]\\d+$`, "mu"));
  if (!match) {
    addFinding(label, objectId.slice(0, 7), "<missing-or-invalid>");
    return;
  }
  assertIdentity(match[1], label, objectId.slice(0, 7), allowedCommit);
  scanText(match[0], `${label}-header`, objectId.slice(0, 7));
}

function splitObject(raw) {
  const separator = Buffer.from("\n\n");
  const index = raw.indexOf(separator);
  if (index < 0) return { header: raw.toString("latin1"), headerBuffer: raw, body: Buffer.alloc(0) };
  const headerBuffer = raw.subarray(0, index);
  return { header: headerBuffer.toString("latin1"), headerBuffer, body: raw.subarray(index + separator.length) };
}

function scanCommit(objectId) {
  if (scannedCommits.has(objectId)) return;
  scannedCommits.add(objectId);
  const raw = git(["cat-file", "commit", objectId], { encoding: null }).stdout;
  const { header, headerBuffer, body } = splitObject(raw);
  parseIdentityHeader(header, "author", objectId);
  parseIdentityHeader(header, "committer", objectId);
  scanBuffer(headerBuffer, "commit-header", objectId.slice(0, 7));
  scanBuffer(body, "commit-message", objectId.slice(0, 7));

  const paths = git(["ls-tree", "-r", "-z", "--name-only", objectId], { encoding: null }).stdout;
  for (const pathBuffer of splitNull(paths)) {
    scanText(pathBuffer.toString("utf8"), "path", objectId.slice(0, 7));
  }
}

function scanTree(objectId) {
  const entries = git(["ls-tree", "-r", "-z", objectId], { encoding: null }).stdout;
  for (const entryBuffer of splitNull(entries)) {
    const entry = entryBuffer.toString("utf8");
    const match = entry.match(/^(\d+) ([a-z]+) ([0-9a-f]{40,64})\t([\s\S]*)$/u);
    if (!match) throw new Error("Unable to parse a Git tree entry while enforcing email privacy.");
    scanText(match[4], "path", `tree:${objectId.slice(0, 7)}`);
    if (match[2] === "blob") scanBlob(match[3], `tree:${objectId.slice(0, 7)}`);
  }
}

function scanTag(objectId) {
  if (scannedTags.has(objectId)) return scannedTags.get(objectId);
  const raw = git(["cat-file", "tag", objectId], { encoding: null }).stdout;
  const { header, headerBuffer, body } = splitObject(raw);
  parseIdentityHeader(header, "tagger", objectId);
  scanBuffer(headerBuffer, "tag-header", objectId.slice(0, 7));
  scanBuffer(body, "tag-message", objectId.slice(0, 7));

  const targetObject = header.match(/^object ([0-9a-f]{40,64})$/mu)?.[1];
  const declaredType = header.match(/^type ([a-z]+)$/mu)?.[1];
  if (!targetObject || !declaredType) throw new Error("Annotated tag is missing its target object metadata.");
  const actualType = objectType(targetObject);
  if (actualType !== declaredType) throw new Error("Annotated tag target type does not match the referenced Git object.");
  if (actualType === "tag") {
    const nestedTarget = scanTag(targetObject);
    scannedTags.set(objectId, nestedTarget);
    return nestedTarget;
  }
  if (actualType === "blob") scanBlob(targetObject, `tag:${objectId.slice(0, 7)}`);
  if (actualType === "tree") scanTree(targetObject);
  const target = { objectId: targetObject, type: actualType };
  scannedTags.set(objectId, target);
  return target;
}

function splitNull(buffer) {
  const parts = [];
  let start = 0;
  for (let index = 0; index < buffer.length; index += 1) {
    if (buffer[index] === 0) {
      if (index > start) parts.push(buffer.subarray(start, index));
      start = index + 1;
    }
  }
  if (start < buffer.length) parts.push(buffer.subarray(start));
  return parts;
}

function commitsFor(revisions) {
  const lines = git(["rev-list", ...revisions]).stdout.split(/\r?\n/u);
  return lines.map((line) => line.trim()).filter((line) => objectIdPattern.test(line));
}

function scanReachableObjects(revisions) {
  const lines = git(["rev-list", "--objects", "--no-object-names", ...revisions]).stdout.split(/\r?\n/u);
  for (const objectId of new Set(lines.map((line) => line.trim()).filter((line) => objectIdPattern.test(line)))) {
    if (objectType(objectId) === "blob") scanBlob(objectId, `blob:${objectId.slice(0, 7)}`);
  }
}

function scanCommitSet(commits) {
  for (const commit of commits) scanCommit(commit);
}

function scanStaged() {
  const configured = git(["config", "--get", "user.email"], { allowed: [0, 1] });
  assertIdentity(configured.status === 0 ? configured.stdout.trim() : "", "git-config", "user.email", allowedLocal);

  for (const [variable, scope] of [["GIT_AUTHOR_IDENT", "effective-author"], ["GIT_COMMITTER_IDENT", "effective-committer"]]) {
    const identity = git(["var", variable], { allowed: [0, 1] });
    const match = identity.stdout.match(/<([^<>\r\n]+)>/u);
    assertIdentity(match?.[1] ?? "", scope, variable, allowedCommit);
    scanText(identity.stdout, `${scope}-identity`, variable);
  }

  const index = git(["ls-files", "--cached", "--stage", "-z"], { encoding: null }).stdout;
  for (const entryBuffer of splitNull(index)) {
    const entry = entryBuffer.toString("utf8");
    const match = entry.match(/^(\d+) ([0-9a-f]{40,64}) ([0-3])\t([\s\S]*)$/u);
    if (!match || match[3] !== "0" || match[1] === "160000") continue;
    scanText(match[4], "path", `index:${match[4]}`);
    scanBlob(match[2], `index:${match[4]}`);
  }
}

function scanCommitMessage() {
  if (!options.messageFile) throw new Error("commit-message mode requires --message-file.");
  scanBuffer(readFileSync(options.messageFile), "commit-message", options.messageFile);
}

function scanPrePush() {
  const input = readFileSync(0, "utf8");
  const revisions = [];
  const commits = new Set();
  for (const line of input.split(/\r?\n/u)) {
    if (!line.trim()) continue;
    const fields = line.trim().split(/\s+/u);
    if (fields.length !== 4) throw new Error("Unexpected pre-push input format.");
    const localObject = fields[1];
    const remoteObject = fields[3];
    if (zeroObjectPattern.test(localObject)) continue;
    scanText(fields[0], "ref", "pre-push local ref");
    scanText(fields[2], "ref", "pre-push remote ref");

    const type = objectType(localObject);
    let localCommit;
    if (type === "commit") localCommit = localObject;
    else if (type === "tag") {
      const target = scanTag(localObject);
      if (target?.type === "commit") localCommit = target.objectId;
    } else if (type === "blob") scanBlob(localObject, `ref-object:${localObject.slice(0, 7)}`);
    else if (type === "tree") scanTree(localObject);
    else throw new Error("A pushed ref points to an unsupported Git object type.");

    if (!localCommit) continue;
    let range = [localCommit];
    if (!zeroObjectPattern.test(remoteObject)) {
      const remoteCommitResult = git(["rev-parse", `${remoteObject}^{commit}`], { allowed: [0, 1, 128] });
      if (remoteCommitResult.status === 0) {
        const remoteCommit = remoteCommitResult.stdout.trim();
        range = [localCommit, `^${remoteCommit}`];
      }
    }
    revisions.push(range);
    for (const commit of commitsFor(range)) commits.add(commit);
  }
  scanCommitSet(commits);
  for (const range of revisions) scanReachableObjects(range);
}

function scanRepository() {
  const commitHeads = new Set();
  const headResult = git(["rev-parse", "HEAD^{commit}"], { allowed: [0, 1, 128] });
  if (headResult.status === 0) commitHeads.add(headResult.stdout.trim());
  const refLines = git(["for-each-ref", "--format=%(objectname)%09%(objecttype)%09%(refname)"]).stdout.split(/\r?\n/u);
  for (const line of refLines) {
    if (!line.trim()) continue;
    const fields = line.split("\t");
    if (fields.length !== 3 || !objectIdPattern.test(fields[0])) {
      throw new Error("Unable to parse a Git ref while enforcing email privacy.");
    }
    const [objectId, type, refName] = fields;
    scanText(refName, "ref", "repository ref");
    if (type === "commit") commitHeads.add(objectId);
    else if (type === "tag") {
      const target = scanTag(objectId);
      if (target?.type === "commit") commitHeads.add(target.objectId);
    } else if (type === "blob") scanBlob(objectId, `ref-object:${objectId.slice(0, 7)}`);
    else if (type === "tree") scanTree(objectId);
    else throw new Error("A repository ref points to an unsupported Git object type.");
  }

  const commits = new Set();
  for (const head of commitHeads) {
    for (const commit of commitsFor([head])) commits.add(commit);
    scanReachableObjects([head]);
  }
  scanCommitSet(commits);
}

function maskEmail(address) {
  if (address.startsWith("<")) return address;
  const separator = address.indexOf("@");
  if (separator < 0) return "<redacted>";
  const local = address.slice(0, separator);
  return `${local.length <= 1 ? "*" : `${local[0]}***`}${address.slice(separator)}`;
}

try {
  if (options.mode === "staged") scanStaged();
  else if (options.mode === "commit-message") scanCommitMessage();
  else if (options.mode === "pre-push") scanPrePush();
  else scanRepository();

  if (findings.size > 0) {
    console.error("EMAIL PRIVACY POLICY BLOCKED THIS OPERATION");
    for (const finding of [...findings.values()].sort((left, right) => JSON.stringify(left).localeCompare(JSON.stringify(right)))) {
      console.error(`- ${finding.scope} at ${finding.location}: ${maskEmail(finding.address)}`);
    }
    console.error("Use a GitHub-provided users.noreply.github.com address and remove personal addresses from content/history.");
    process.exitCode = 1;
  } else {
    console.log(`Email privacy policy passed: ${options.mode}`);
  }
} catch (error) {
  console.error(`Email privacy policy could not complete: ${redactEmails(error.message)}`);
  process.exitCode = 2;
}
