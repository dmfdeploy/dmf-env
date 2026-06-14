# QWEN.md — dmf-env

<!-- WORKING-MODEL-BLOCK-START — generated from umbrella docs/templates/working-model-block.md; do not edit copies, edit the template and run bin/check-working-model-sync.sh -->
## Working model (mandatory)

Canonical: [docs/WORKING-MODEL.md](https://github.com/dmfdeploy/dmfdeploy/blob/main/docs/WORKING-MODEL.md)
in the umbrella repo. The three rules that matter mid-task:

1. **Work starts at an issue** in the canonical backlog
   ([dmfdeploy/dmfdeploy issues](https://github.com/dmfdeploy/dmfdeploy/issues);
   milestone + `component:*`/`workstream:*` labels). Non-trivial work gets a
   plan doc in umbrella `docs/plans/` with `tracking_issue` frontmatter.
2. **The completing PR closes the issue and flips the plan frontmatter in the
   same change.** From a component repo, reference umbrella issues **fully
   qualified** — `Closes dmfdeploy/dmfdeploy#N`; bare `#N` targets the wrong repo.
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
2. the umbrella `QWEN.md` — full boot ritual + skills index + Qwen-specific rules
3. `docs/decisions/INDEX.md` — ADRs applicable to your task
4. the most recent file under `docs/handoffs/`

Qwen doesn't have a `/skill-name` invocation — read the relevant `SKILL.md` under
`.claude/skills/` as documentation and apply its sections like instructions. If
you change cross-repo state, update the `<!-- HUMAN-START -->` section of
`STATUS.md` before ending the session.

---

## Repo-specific notes

**Generic environment provisioning + bootstrap tooling** (per ADR-0002/ADR-0035):
`bin/` wrappers, `terraform/` (Hetzner root + modules), neutral
`tasks/`/`templates/`. No environment data is committed — every env is
operator-local under `~/.dmfdeploy/envs/<env>/`.

**Handle with care:**
- `bin/run-playbook.sh` — sanctioned Ansible entry point (ADR-0010); writes
  secrets to `/tmp/openbao-vars-*` (mktemp + cleanup). Use it for all ansible runs.
- `bin/get-admin-cred.sh` — prints app credentials to stdout. **Do NOT invoke
  through Qwen**; run it in your own terminal (ADR-0007 §1).
- `bin/unseal-openbao.sh` — strict Shamir unseal. `--status` to check; a full
  unseal needs a human for the share/keychain prompt.

For routine ops: `bin/run-playbook.sh <env> <playbook>` — the wrapper handles
secret injection and timeouts. Deeper guidance is in `CLAUDE.md`; the boot
ritual above supersedes anything that conflicts.
