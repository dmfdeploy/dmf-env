# CLAUDE.md — dmf-env

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
   Discussions first); STATUS.md = committed notes; STATUS.local.md = live repo snapshot.
<!-- WORKING-MODEL-BLOCK-END -->

## DMF Platform context — read first

This repo is a component of the **DMF Platform**. Cross-cutting state (status,
decisions, plans, skills) lives in the umbrella workspace, referenced here as
`$DMFDEPLOY_UMBRELLA`, not in this repo.

Before any non-trivial change:

```bash
cd "$DMFDEPLOY_UMBRELLA"
git fetch && git pull
bin/generate-status.sh --no-fetch    # refreshes STATUS.md
```

Then read, in order:
1. `STATUS.md` — current cross-repo state
2. the umbrella `CLAUDE.md` — full boot ritual + workspace map
3. `docs/decisions/INDEX.md` — ADRs applicable to your task
4. the most recent file under `docs/handoffs/`

For cluster ops, secrets, or releases, also read §0 of the relevant skill under
`.claude/skills/`. If you change cross-repo state, update the
`<!-- HUMAN-START -->` section of `STATUS.md` before ending the session.

---

## What this repo is

**Generic environment provisioning + bootstrap tooling** for the DMF Platform:
`bin/` wrappers, `terraform/` (Hetzner root + modules), and neutral
`tasks/`/`templates/`. Providers in v0.1: **sandbox** + **hetzner**.

**No environment data lives here.** Per ADR-0035 every env is operator-local
under `~/.dmfdeploy/envs/<env>/` (inventory, manifest, encrypted bundle, per-env
SSH key, OpenTofu state). The resolver `bin/lib/_resolve_env_paths.sh` locates an
env from its id alone. See the repo `README.md`.

## Sanctioned entry points

- `bin/run-playbook.sh <env> <playbook>` — the only sanctioned Ansible entry
  point (ADR-0010). Injects secrets to a `mktemp` vars file and cleans up; never
  run `ansible-playbook` directly from an agent session.
- `bin/init-wizard.sh` — greenfield env bootstrap; renders the env under
  `~/.dmfdeploy/envs/<env>/`.
- `bin/tf-apply.sh` / `bin/tf-destroy.sh` — OpenTofu wrappers (**hetzner only**;
  they refuse sandbox).
- `bin/bootstrap-secrets.sh` — `doctor` / `seed-bao` / `export-vars`.
- `bin/unseal-openbao.sh` — Shamir-quorum OpenBao unseal; full unseal needs a
  human (keychain/share prompt).

## Secrets discipline

- Secrets stay in OpenBao; the wrappers fetch/generate them at runtime. Never
  commit, track, or echo credentials (ADR-0007).
- `bin/get-admin-cred.sh` prints app credentials to stdout — **do not invoke it
  through an agent**; run it in your own terminal.
- Placeholder syntax only in any docs you add — no real IPs, DNS names, or
  operator identifiers.
