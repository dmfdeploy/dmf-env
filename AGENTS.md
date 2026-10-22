# AGENTS.md — dmf-env

This repo holds the generic environment tooling of the dmfdeploy platform:
the init wizard, OpenTofu modules (`terraform/`), `bin/` wrappers, and neutral
`tasks/` and `templates/`. Providers are sandbox and hetzner. No environment
data lives here: every env is operator-local (ADR-0035; see `README.md`).
Cross-repo status, decisions and plans live in the
[dmfdeploy umbrella repo](https://github.com/dmfdeploy/dmfdeploy).

## Boot steps

1. In the umbrella repo, run `git pull` and `bin/generate-status.sh`, then read
   `STATUS.digest.local.md`.
2. Skim the umbrella `docs/decisions/INDEX.md` and apply any ADR that fits.
3. Post notes that others need to the pinned umbrella issue
   [#618](https://github.com/dmfdeploy/dmfdeploy/issues/618).

## Build and test

- Shell lint: `shellcheck -S error bin/*.sh`
- OpenTofu: `tofu fmt -check -recursive terraform/hetzner terraform/modules/hetzner/cluster`, then `tofu init -backend=false && tofu validate` in each of those two directories.
- Tests: `bash tests/<name>.sh` for each script in `tests/`. They are hermetic and skip when `sops`, `age` or `jq` is missing.

## Rules that are easy to miss

- Run Ansible only through `bin/run-playbook.sh <env> <playbook>` (ADR-0010).
  It injects secrets through a temporary vars file and removes it. Never run
  `ansible-playbook` directly from an agent session.
- Do not run `bin/get-admin-cred.sh` through an agent. It prints credentials to
  stdout, so run it in your own terminal (ADR-0007).
- `bin/tf-apply.sh` and `bin/tf-destroy.sh` work for hetzner only and refuse sandbox.
- `bin/unseal-openbao.sh --status` checks state. A full unseal needs a human for the share prompt.
- Secrets stay in OpenBao. Never commit, track or echo credentials.
- Use placeholder values in docs you add: no real IPs, DNS names or operator identifiers.
- Before you retrieve secrets, run cluster operations or release, read section 0 of the matching skill in the umbrella `.agents/skills/`.

<!-- WORKING-MODEL-BLOCK-START — generated from umbrella docs/templates/working-model-block.md; do not edit copies, edit the template and run bin/check-working-model-sync.sh -->
## Working model (mandatory)

Canonical: [docs/WORKING-MODEL.md](https://github.com/dmfdeploy/dmfdeploy/blob/main/docs/WORKING-MODEL.md)
in the umbrella repo. The three rules that matter mid-task:

1. **Work starts at an issue** in the canonical backlog
   ([dmfdeploy/dmfdeploy issues](https://github.com/dmfdeploy/dmfdeploy/issues)):
   `component:*`/`workstream:*` labels **always**, plus a milestone **only if
   the work is scheduled** — unscheduled work gets `platform-debt` and no
   milestone (§2). Non-trivial work gets a plan doc in umbrella `docs/plans/`
   with `tracking_issue` frontmatter.
2. **The completing PR auto-closes its issue; you still flip the plan
   frontmatter by hand in that PR.** Reference umbrella issues **fully
   qualified** — `Closes dmfdeploy/dmfdeploy#N` (bare `#N` targets the wrong
   repo); the daily issue-close reconciler honors that ref, cross-repo
   included. Manual close is a fallback.
3. **Never invent a local backlog** (TODO files, ad-hoc trackers). Issues =
   liveness; plan frontmatter = design state; ADRs = decisions (RFC in
   Discussions first); STATUS.md = pointer file (operator notes live in pinned issue dmfdeploy/dmfdeploy#618);
   STATUS.local.md = live repo snapshot.
<!-- WORKING-MODEL-BLOCK-END -->
