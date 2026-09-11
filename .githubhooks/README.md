# Repository email privacy hooks

These committed hooks prevent non-approved email addresses from entering Git metadata, commit messages, tracked content, or pushed commits. The shared Node.js checker reads staged and historical Git blobs as raw bytes, including ASCII inside binary files and UTF-16 text.

## Enable locally

```powershell
.\.githubhooks\install.ps1
```

If this repository does not already use your GitHub-provided private address:

```powershell
.\.githubhooks\install.ps1 -NoreplyEmail "<your GitHub noreply address>"
```

The installer sets the repository-local `core.hooksPath` to `.githubhooks`. Git does not activate committed hooks automatically after cloning, so every contributor must run the installer once.

The installer refuses to replace an existing hooks path unless `-Force` is supplied, because replacing Husky, Git LFS, or another hook manager without migration could disable its checks. It also enables repository-local `user.useConfigOnly` so Git cannot silently invent an identity.

## Enforcement

- `pre-commit` checks repository-local `user.email` and all staged text.
- `commit-msg` checks the proposed commit message.
- `pre-push` checks author/committer metadata, messages, and trees for every commit being pushed.
- GitHub CI uses `--mode head` to scan the tested commit and every reachable ancestor, including historical file contents and paths. It requires a complete, non-shallow checkout and excludes unrelated fetched branches and tags.
- `--mode repository` remains available for an explicit audit of all local refs, remote-tracking refs, tags, and their reachable history.

Allowed by default:

- GitHub-provided `users.noreply.github.com` commit addresses.
- GitHub's system `noreply` committer address.
- Reserved `.invalid` addresses used only in tests and examples.

Any intentional public address must be reviewed and explicitly added to `email-policy.json`. Failed checks mask the local part of rejected addresses so CI logs do not repeat the secret.

Local hooks can be bypassed with Git's `--no-verify` option. The CI check remains mandatory for review, but CI runs only after objects have reached GitHub; the installed `pre-push` hook is the layer that prevents the initial upload. For commit-metadata protection at the account level, also enable GitHub's **Block command line pushes that expose my email** setting.

References: [Git hooks and `pre-push` input](https://git-scm.com/docs/githooks), [`core.hooksPath`](https://git-scm.com/docs/git-config#Documentation/git-config.txt-corehooksPath), and [GitHub commit-email privacy](https://docs.github.com/en/account-and-profile/concepts/email-addresses).
