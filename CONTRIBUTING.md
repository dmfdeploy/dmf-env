# Contributing to dmf-env

Generic environment tooling for the dmfdeploy platform: `bin/` scripts, `terraform/modules/` + generic per-provider roots, neutral `tasks/`/`templates/`. Per-env state is operator-local and never committed (ADR-0035).

This repo is part of the **dmfdeploy platform**. GitHub is the canonical home and the
single source of truth: all changes land via **Pull Request** against `main`.

## Quick start

1. Read the platform overview in the [dmfdeploy/dmfdeploy](https://github.com/dmfdeploy/dmfdeploy) umbrella repo
   (`docs/architecture/dmfdeploy-platform-plan.md`) and apply any relevant ADRs from
   `docs/decisions/INDEX.md`.
2. Set up your machine and run the checks (see [Develop and test](#develop-and-test)).
3. Fork or branch, make your change on a topic branch, open a PR against `main`.
4. Ensure CI is green, your commits are **signed off** (see DCO below), and the
   PR body links its issue (see [What a pull request needs](#what-a-pull-request-needs)).

## Develop and test

This section is the one place for development and test commands. The README and
`AGENTS.md` point here. One script, `scripts/check.sh`, runs the checks, and CI
runs the same script in `.github/workflows/ci.yml`.

### Prerequisites

You need a Linux or macOS machine with these tools on your `PATH`. CI runs on
Ubuntu, and the checks also pass on macOS with the bash that macOS ships.

| Tool | Used for |
| --- | --- |
| `bash`, `python3`, `jq` | The scripts, the tests and the review-comment check. |
| `sops` and `age` | Encrypting the throwaway secrets bundles that the tests create. The tests also call `age-keygen`, which ships with `age`. |
| [`yq`](https://github.com/mikefarah/yq) v4, the Go version | Reading the manifest in the wizard tests. The [README](README.md#prerequisites) explains how to tell it from the Python `yq`. |
| OpenSSH (`ssh` and `ssh-keygen`) | The tests that create throwaway keys and fake a node login. |
| [`shellcheck`](https://www.shellcheck.net/) | The `shellcheck` step. |
| [OpenTofu](https://opentofu.org/) | The `tofu` step. |
| [gitleaks](https://github.com/gitleaks/gitleaks) (optional) | The commit and push hooks. |

CI pins `sops`, `yq` and OpenTofu to exact releases. If a test fails on your
machine and passes in CI, compare your versions with the ones in `ci.yml`.

You don't need a cluster, a cloud account or a secret. The tests run in
temporary directories, with throwaway keys and fake `ssh` and `hcloud`
commands. The `tofu` step downloads the provider plugins, so it needs
network access to the OpenTofu registry.

### Set up

There is nothing to install in the repository. After you install the tools,
install the hooks once in each clone:

```bash
bin/install-hooks.sh
```

The script sets `core.hooksPath` to `.githooks/`. The `pre-commit` and
`pre-push` hooks scan your changes with gitleaks. They skip the scan with a
warning when gitleaks isn't installed. The `guard` workflow also runs gitleaks,
with a different scope: the hooks scan your staged changes and the commits you
push, and CI scans the checked-out tree.

### Run the checks

Run one script from the repository root before you push:

```bash
scripts/check.sh
```

CI runs the same script, one step per job, on a clean Ubuntu checkout, with
OpenTofu, `sops` and `yq` pinned in `ci.yml`. A green local run is good
evidence that those jobs pass, but your tool versions and platform can differ
from CI's. Before it runs anything, the script checks that the tools for the
steps you chose are installed, and it stops with a message when one is missing.
It does this because a test script that can't find a tool prints `SKIP` and
exits with success. The script also stops at the first failing step.

To run one step, name it:

```bash
scripts/check.sh tests
```

| Step | What it runs | Time |
| --- | --- | --- |
| `shellcheck` | `shellcheck` on `bin/*.sh` and `scripts/*.sh`, failing on errors only | A few seconds |
| `review-comments` | `bin/check-review-comments.sh` and its `--self-test`, which reject code comments that cite review history | About half a minute |
| `tests` | Every script in `tests/`, one after another | About 20 seconds |
| `tofu` | `tofu fmt -check`, then `tofu init -backend=false` and `tofu validate` in the Hetzner root and its module, in a temporary copy so that your lock files stay unchanged | About half a minute, more on a slow connection |

To run one test script, use `bash tests/<name>.sh`.

### What the checks don't cover

A local pass doesn't mean the platform works. Plan for these gaps:

- **Needs a live environment.** No check runs a wrapper against a real cluster.
  The tests replace `ssh` and `hcloud` with fakes, and one test replaces the
  remote `kubectl` call. They check the logic of the wrappers, such as
  `bin/unseal-openbao.sh` and `bin/upgrade-in-place.sh`. They don't check the
  cluster behavior behind them.
- **Needs cloud credentials.** `tofu validate` checks the syntax and types of
  the Hetzner configuration. `bin/tf-apply.sh` with `plan` or `apply` needs a
  Hetzner account and token.
- **Needs an image build.** None. This repository builds no image.
- **Runs in CI only.** The `working-model` job checks the working-model block in
  `AGENTS.md`, `CLAUDE.md` and `QWEN.md` against a template in the umbrella
  repo, which it checks out at a pinned ref. The `guard` workflow scans for
  secrets and vulnerabilities, lints the workflow files, and checks commit
  subjects and the issue link. The `DCO` workflow checks sign-offs. The hooks
  run the secret scan on your machine if gitleaks is installed.

### Pick a task

These tasks show where a change goes and how far you can test it yourself.

| Task | Where | Offline or live |
| --- | --- | --- |
| Change a wizard prompt or an answers-file field | `bin/init-wizard.sh`, `docs/answers-file-schema.md` | Offline. `tests/wizard-noninteractive-parity.sh` covers the sandbox lane. |
| Tighten a guard in a wrapper, such as a refusal in `bin/remove-env.sh` or `bin/upgrade-in-place.sh` | `bin/`, `tests/` | Offline. Add a test that replaces the outside commands with fakes, as the existing tests do. |
| Change the Hetzner OpenTofu configuration | `terraform/` | No live environment for `fmt` and `validate`, though `tofu init` downloads the provider plugins, so `validate` needs network access. Live for `plan` and `apply`, which need a Hetzner account. |
| Change how a wrapper talks to OpenBao | `bin/unseal-openbao.sh`, `bin/bootstrap-secrets.sh` | Offline for the fake-OpenBao tests. Live to confirm against a real OpenBao. |
| Fix or add documentation | `README.md`, `docs/`, `terraform/README.md` | Offline. Run the hooks and check that your links and commands work. |

When part of your change needs a live environment, say in the PR which part you
couldn't test. A maintainer with an environment can run it.

## Branch & PR model

- **GitHub Pull Requests only.** Direct push to `main` is blocked; force-push is
  banned; linear history is required.
- Topic branches: **`<handle>/<short-slug>`** (e.g. `jdoe/fix-probe-path`). One
  logical change per branch; rebase onto `main` rather than long-lived branches.
- A reviewer (per `CODEOWNERS`) and green required checks are needed to merge.

## What a pull request needs

CI checks each of these.

- **An issue link in the PR body.** Write a fully qualified reference to an issue
  in the [dmfdeploy/dmfdeploy](https://github.com/dmfdeploy/dmfdeploy/issues)
  backlog, such as `Refs dmfdeploy/dmfdeploy#912`. Use `Closes dmfdeploy/dmfdeploy#N`
  if the pull request finishes the issue. A bare `#N` doesn't count, because it
  points at this repo. If your change has no issue, such as a typo fix, a
  maintainer can add the `no-issue` label. Only maintainers can add labels, so
  if you open the pull request from a fork, ask in the PR. The check runs when
  you open the pull request, push a commit, reopen it, or edit the PR body.
  Adding a label doesn't run it, so after a maintainer adds `no-issue`, edit the
  PR body or push a commit to run the check again.
- **A DCO sign-off on every commit.** Use `git commit -s`. See the next section.
- **Conventional commit subjects.** Use `type(scope): summary`, with one
  optional scope. The scope may use only `a-z`, `0-9`, `.`, `_` and `-`. The
  types are `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `build`, `ci`,
  `perf`, `revert` and `style`. An `!` before the colon marks a breaking change.
  Other types, such as `wip`, are rejected, and so is a scope list such as
  `(api,ui)`.
- **Passing CI.** The `ci` workflow runs the checks in
  [Develop and test](#develop-and-test). The `guard` workflow adds secret and
  vulnerability scans.

Also leave agent session links out of commit messages and the PR body. The
`guard` workflow rejects one known session-link format, even when the `no-issue`
label is set. It can't recognize every tool's links, so reviewers look for them
too.

### Evidence for your change

Show evidence in proportion to the change.

- **A documentation change** needs no new test. Check that your links, file
  names and commands are correct, and let the hooks and CI run.
- **A code change** in `bin/` or `terraform/` needs a test in `tests/` that
  fails without your change and passes with it. Run `scripts/check.sh` and say in
  the PR which steps you ran.
- **A defect fix** also needs a search for siblings. Search the repository for
  the pattern that caused the defect, and say in the PR what each match shows.
  A fix that leaves an identical defect one directory away isn't finished.
- **A change you can't run offline** needs a note on what you couldn't run, as
  the previous section describes.

## Developer Certificate of Origin (DCO)

We use the [Developer Certificate of Origin](https://developercertificate.org/),
not a CLA. **Every commit must be signed off:**

```bash
git commit -s -m "fix: correct the probe path"
```

This appends a `Signed-off-by: Your Name <you@example.com>` trailer certifying you
have the right to submit the work under the project license. A **DCO check** runs
on every PR and fails if any commit is missing the trailer. Amend with
`git commit --amend -s` or rebase with `git rebase --signoff main` to fix. PRs are
**rebase-merged** by default so your signed-off commits land on `main` unchanged.

## Versioning & releases

This repo carries a `VERSION` file (single semver line). Per **ADR-0005**,
`VERSION` is the single source of truth — any release-tagged change must update it
in the same commit. **No VERSION bump → no release.** Release tags are `v<VERSION>`,
created by release automation, never by hand.

## Secrets & public-safety posture

**Secrets stay in OpenBao.** Never commit, track, or reference credentials, tokens,
keys, kubeconfigs, or Terraform state — not even with a "remove later" TODO. Use
**placeholder syntax** for any IPs, DNS names, or operator identity in code, docs,
PR descriptions, or issues (`<control-node-public-ip>`, `dmf.example.com`,
`<handle>`). A local pre-commit gitleaks hook runs on commit, and CI runs
secret-scanning + scrub gates on every PR — but redaction is your responsibility
first. If you need a secret, ask a maintainer — do not improvise a transport.

## Must / Must not

### MUST
- Open changes as **GitHub PRs against `main`** with **signed-off** commits.
- Use Conventional Commit messages and `<handle>/<short-slug>` topic branches.
- Update `VERSION` in the same commit as any release-tagged change.
- Use **placeholder syntax** for all IPs / DNS / operator identity in every artifact.
- Keep the surface generic — per-env state stays under `~/.dmfdeploy/envs/<env>/`;
  placeholder syntax everywhere.

### MUST NOT
- Commit secrets, tokens, keys, kubeconfigs, or Terraform state.
- Push directly to `main`, force-push, or use `--no-verify` / `--no-gpg-sign`.
- Paste secrets, real IPs/DNS, or operator identity into issues, PRs, or CI logs.
- Commit inventories, tfstate, SOPS bundles, SSH keys, or OpenBao/Shamir material.

## AI agent contract

Much of this platform is built by AI agents. Agents contribute the same way:
**PRs against `main`, signed off, CI green.** Additionally, agents must run cluster
mutation only via `bin/run-playbook.sh` (ADR-0010), must not use
`--no-verify`/`--force`/`--no-gpg-sign`, and must stop and ask before modifying a
sub-repo with uncommitted state.

## Reporting security issues

See [`SECURITY.md`](SECURITY.md). **Do not** open a public issue for a vulnerability.

## License & spec

Contributions are licensed under [Apache 2.0](LICENSE). The canonical governance
model is **ADR-0041 — DMF Release and Contribution Model** in the
[dmfdeploy/dmfdeploy](https://github.com/dmfdeploy/dmfdeploy)
umbrella repo (`docs/decisions/`).
