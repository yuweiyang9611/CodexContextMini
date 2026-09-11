import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cpSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const checker = path.join(repositoryRoot, ".githubhooks", "check-email-policy.mjs");
const safeEmail = "123456+privacy-test@users.noreply.github.com";
const allowedExample = "release-test@example.invalid";
const blockedEmail = ["private.person", "mail.example"].join("@");
const maskedBlockedEmail = ["p***", "mail.example"].join("@");

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    encoding: "utf8",
    env: { ...process.env, ...(options.env ?? {}) },
    input: options.input,
  });
  if (result.error) throw result.error;
  return result;
}

function git(root, ...args) {
  const result = run("git", ["-C", root, ...args]);
  assert.equal(result.status, 0, `git ${args.join(" ")} failed: ${result.stderr}`);
  return result.stdout.trim();
}

function createRepository(t) {
  const root = mkdtempSync(path.join(tmpdir(), "context-email-policy-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  git(root, "init", "-b", "main");
  git(root, "config", "user.name", "Privacy Test");
  git(root, "config", "user.email", safeEmail);
  return root;
}

function check(root, mode, options = {}) {
  const args = [checker, "--mode", mode, "--root", root];
  if (options.messageFile) args.push("--message-file", options.messageFile);
  return run(process.execPath, args, { cwd: root, input: options.input });
}

function commit(root, filename, content, message = "test commit", env = {}) {
  writeFileSync(path.join(root, filename), content);
  git(root, "add", "--", filename);
  const result = run("git", ["-C", root, "commit", "--no-verify", "-m", message], { env });
  assert.equal(result.status, 0, result.stderr);
  return git(root, "rev-parse", "HEAD");
}

test("email privacy policy", async (t) => {
  await t.test("redacts initialization errors before policy setup completes", () => {
    const unknownArgument = run(process.execPath, [checker, `--${blockedEmail}`], { cwd: repositoryRoot });
    assert.equal(unknownArgument.status, 2);
    assert.equal(unknownArgument.stderr.includes(blockedEmail), false);

    const root = createRepository(t);
    const hookDirectory = path.join(root, ".githubhooks");
    mkdirSync(hookDirectory, { recursive: true });
    cpSync(checker, path.join(hookDirectory, "check-email-policy.mjs"));
    const invalidPolicy = {
      maxBlobBytes: 1024,
      allowedLocalGitEmailPatterns: [`^${blockedEmail}($`],
      allowedCommitEmailPatterns: ["^noreply@github\\.com$"],
      allowedContentEmailPatterns: ["^noreply@github\\.com$"],
    };
    writeFileSync(path.join(hookDirectory, "email-policy.json"), JSON.stringify(invalidPolicy));
    const invalidResult = run(process.execPath, [
      path.join(hookDirectory, "check-email-policy.mjs"), "--mode", "repository", "--root", root,
    ]);
    assert.equal(invalidResult.status, 2);
    assert.equal(invalidResult.stderr.includes(blockedEmail), false);
  });

  await t.test("allows GitHub noreply identity and reserved test addresses", () => {
    const root = createRepository(t);
    writeFileSync(path.join(root, "safe.txt"), `fixture: ${allowedExample}\n`);
    git(root, "add", "--", "safe.txt");
    const result = check(root, "staged");
    assert.equal(result.status, 0, result.stderr);
  });

  await t.test("rejects a personal repository-local Git identity without echoing it", () => {
    const root = createRepository(t);
    git(root, "config", "user.email", blockedEmail);
    writeFileSync(path.join(root, "safe.txt"), "safe\n");
    git(root, "add", "--", "safe.txt");
    const result = check(root, "staged");
    assert.equal(result.status, 1);
    assert.equal(result.stderr.includes(blockedEmail), false);
    assert.equal(result.stderr.includes(maskedBlockedEmail), true);
  });

  await t.test("rejects personal addresses in staged ASCII and UTF-16 blobs", () => {
    for (const [name, buffer] of [
      ["ascii.bin", Buffer.from(`secret=${blockedEmail}\n`, "utf8")],
      ["utf16.bin", Buffer.from(`secret=${blockedEmail}\n`, "utf16le")],
    ]) {
      const root = createRepository(t);
      writeFileSync(path.join(root, name), buffer);
      git(root, "add", "--", name);
      const result = check(root, "staged");
      assert.equal(result.status, 1, `${name} should be rejected`);
      assert.equal(result.stderr.includes(blockedEmail), false);
    }
  });

  await t.test("rejects a personal address in a staged path without echoing it", () => {
    const root = createRepository(t);
    const filename = `private-${blockedEmail}.txt`;
    writeFileSync(path.join(root, filename), "safe\n");
    git(root, "add", "--", filename);
    const result = check(root, "staged");
    assert.equal(result.status, 1);
    assert.equal(result.stderr.includes(blockedEmail), false);
  });

  await t.test("rejects a personal address in a commit message", () => {
    const root = createRepository(t);
    const messageFile = path.join(root, "message.txt");
    writeFileSync(messageFile, `Co-authored-by: Private <${blockedEmail}>\n`);
    const result = check(root, "commit-message", { messageFile });
    assert.equal(result.status, 1);
    assert.equal(result.stderr.includes(blockedEmail), false);
  });

  await t.test("rejects raw author and committer metadata in repository history", () => {
    const root = createRepository(t);
    commit(root, "baseline.txt", "safe\n", "baseline");
    commit(root, "unsafe.txt", "safe content\n", "unsafe metadata", {
      GIT_AUTHOR_EMAIL: blockedEmail,
      GIT_COMMITTER_EMAIL: blockedEmail,
    });
    const result = check(root, "repository");
    assert.equal(result.status, 1);
    assert.equal(result.stderr.includes(blockedEmail), false);
  });

  await t.test("rejects a personal address in a raw commit header", () => {
    const root = createRepository(t);
    const parent = commit(root, "baseline.txt", "safe\n", "baseline");
    const tree = git(root, "show", "-s", "--format=%T", parent);
    const rawCommit = [
      `tree ${tree}`,
      `parent ${parent}`,
      `author Privacy Test <${safeEmail}> 1700000000 +0000`,
      `committer Privacy Test <${safeEmail}> 1700000000 +0000`,
      `x-privacy-note ${blockedEmail}`,
      "",
      "safe message",
      "",
    ].join("\n");
    const object = run("git", ["-C", root, "hash-object", "-t", "commit", "-w", "--stdin"], { input: rawCommit });
    assert.equal(object.status, 0, object.stderr);
    const objectId = object.stdout.trim();
    git(root, "update-ref", "refs/heads/header-test", objectId);
    const result = check(root, "repository");
    assert.equal(result.status, 1);
    assert.equal(result.stderr.includes(blockedEmail), false);
  });

  await t.test("head mode excludes unrelated fetched refs but checks them after merging", () => {
    const root = createRepository(t);
    const baseline = commit(root, "baseline.txt", "safe\n", "baseline");
    git(root, "checkout", "-b", "other-change");
    const unrelated = commit(root, "other.txt", "safe\n", "contact " + blockedEmail);
    git(root, "update-ref", "refs/remotes/origin/other-change", unrelated);
    git(root, "tag", "other-tag", unrelated);
    git(root, "checkout", "main");
    git(root, "branch", "-D", "other-change");
    const clean = check(root, "head");
    assert.equal(clean.status, 0, clean.stderr);
    assert.equal(check(root, "repository").status, 1);
    git(root, "checkout", "--detach", baseline);
    assert.equal(check(root, "head").status, 0);
    git(root, "checkout", "main");
    git(root, "merge", "--no-ff", "-m", "merge other change", unrelated);
    const merged = check(root, "head");
    assert.equal(merged.status, 1);
    assert.equal(merged.stderr.includes(blockedEmail), false);
  });

  await t.test("head mode rejects historical metadata and blobs removed from the current tree", () => {
    const root = createRepository(t);
    commit(root, "baseline.txt", "safe\n", "baseline");
    commit(root, "old.txt", "contact " + blockedEmail + "\n", "old content", {
      GIT_AUTHOR_EMAIL: blockedEmail,
      GIT_COMMITTER_EMAIL: blockedEmail,
    });
    git(root, "rm", "old.txt");
    git(root, "commit", "-m", "remove old file");
    const result = check(root, "head");
    assert.equal(result.status, 1);
    assert.match(result.stderr, /author at/u);
    assert.match(result.stderr, /content at/u);
    assert.equal(result.stderr.includes(blockedEmail), false);
  });

  await t.test("head mode refuses a shallow checkout", () => {
    const root = createRepository(t);
    commit(root, "baseline.txt", "safe\n", "baseline");
    const head = commit(root, "latest.txt", "safe\n", "latest");
    writeFileSync(path.join(root, ".git", "shallow"), head + "\n");
    const result = check(root, "head");
    assert.equal(result.status, 2);
    assert.match(result.stderr, /requires complete history/u);
  });

  await t.test("pre-push scans only the commits and blobs being introduced", () => {
    const root = createRepository(t);
    const remoteCommit = commit(root, "baseline.txt", "safe\n", "baseline");
    const localCommit = commit(root, "leak.txt", `secret=${blockedEmail}\n`, "new commit");
    const input = `refs/heads/main ${localCommit} refs/heads/main ${remoteCommit}\n`;
    const result = check(root, "pre-push", { input });
    assert.equal(result.status, 1);
    assert.equal(result.stderr.includes(blockedEmail), false);
  });

  await t.test("pre-push permits a ref deletion", () => {
    const root = createRepository(t);
    const remoteCommit = commit(root, "baseline.txt", "safe\n", "baseline");
    const zero = "0".repeat(remoteCommit.length);
    const input = `(delete) ${zero} refs/heads/${blockedEmail} ${remoteCommit}\n`;
    const result = check(root, "pre-push", { input });
    assert.equal(result.status, 0, result.stderr);
  });

  await t.test("pre-push accepts a lightweight tag that points to a safe blob", () => {
    const root = createRepository(t);
    const blob = run("git", ["-C", root, "hash-object", "-w", "--stdin"], { input: "safe blob\n" });
    assert.equal(blob.status, 0, blob.stderr);
    const objectId = blob.stdout.trim();
    const zero = "0".repeat(objectId.length);
    const input = `refs/tags/blob ${objectId} refs/tags/blob ${zero}\n`;
    const result = check(root, "pre-push", { input });
    assert.equal(result.status, 0, result.stderr);
    git(root, "update-ref", "refs/tags/blob", objectId);
    const repositoryResult = check(root, "repository");
    assert.equal(repositoryResult.status, 0, repositoryResult.stderr);
  });

  await t.test("committed hook wrappers invoke the shared policy", () => {
    const root = createRepository(t);
    const head = commit(root, "baseline.txt", "safe\n", "baseline");
    git(root, "config", "core.hooksPath", path.join(repositoryRoot, ".githubhooks"));

    writeFileSync(path.join(root, "staged.txt"), "safe\n");
    git(root, "add", "--", "staged.txt");
    const preCommit = run("git", ["-C", root, "hook", "run", "pre-commit"]);
    assert.equal(preCommit.status, 0, preCommit.stderr);

    const inputFile = path.join(root, "pre-push-input.txt");
    const zero = "0".repeat(head.length);
    writeFileSync(inputFile, `(delete) ${zero} refs/heads/old ${head}\n`);
    const prePush = run("git", [
      "-C", root, "hook", "run", `--to-stdin=${inputFile}`, "pre-push", "--", "origin", "https://example.invalid/repository.git",
    ]);
    assert.equal(prePush.status, 0, prePush.stderr);
  });

  await t.test("installer refuses to replace default hooks", () => {
    const root = createRepository(t);
    cpSync(path.join(repositoryRoot, ".githubhooks"), path.join(root, ".githubhooks"), { recursive: true });
    const defaultHooks = path.join(root, ".git", "hooks");
    mkdirSync(defaultHooks, { recursive: true });
    writeFileSync(path.join(defaultHooks, "post-checkout"), "#!/bin/sh\nexit 0\n");
    const result = run("powershell.exe", [
      "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path.join(root, ".githubhooks", "install.ps1"),
    ], { cwd: root });
    assert.notEqual(result.status, 0);
    const configured = run("git", ["-C", root, "config", "--local", "--get", "core.hooksPath"]);
    assert.equal(configured.status, 1);
  });

  await t.test("installer rolls back configuration when policy validation fails", () => {
    const root = createRepository(t);
    cpSync(path.join(repositoryRoot, ".githubhooks"), path.join(root, ".githubhooks"), { recursive: true });
    git(root, "config", "user.email", blockedEmail);
    const result = run("powershell.exe", [
      "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", path.join(root, ".githubhooks", "install.ps1"),
    ], { cwd: root });
    assert.notEqual(result.status, 0);
    assert.equal(result.stderr.includes(blockedEmail), false);
    assert.equal(run("git", ["-C", root, "config", "--local", "--get", "core.hooksPath"]).status, 1);
    assert.equal(run("git", ["-C", root, "config", "--local", "--get", "user.useConfigOnly"]).status, 1);
    assert.equal(git(root, "config", "--local", "--get", "user.email"), blockedEmail);
  });
});
