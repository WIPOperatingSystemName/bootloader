# Bootloader agent instructions

## Commit and pull request handoff

Read the [shared organization contribution instructions](https://github.com/WIPOperatingSystemName/.github/blob/main/AGENTS.md)
before the final handoff. In the standard contributor workspace, the local
copy is `~/wip-os/.github/AGENTS.md`. If neither copy is available, follow this
minimum workflow:

- After completing requested edits and relevant verification, summarize the
  changes and suggest a commit message. Ask once whether the user wants a
  commit and PR to `WIPOperatingSystemName/bootloader`'s default branch.
- Honor explicit submission authorization or a prior decline without asking
  again. Otherwise wait for approval before committing, pushing or opening
  a PR; leave the changes local if the user declines.
- Before starting or resuming work, verify the canonical organization remote and
  fetch it and the personal fork. Integrate the organization's latest default
  branch into the contribution checkout, preserving local work and history.
  In the standard setup, use `git pull --ff-only origin main` on a clean
  `main`; if branches diverge, inspect and merge instead of resetting or
  force-pushing. Do not advance distro's pinned submodules as build setup.
- Fetch the organization again immediately before submission and require
  `git merge-base --is-ancestor origin/main HEAD` to pass, adapting remote and
  branch names to the verified setup. Integrate missing upstream changes and
  rerun affected checks. Report the verified upstream commit or any sync blocker.
- Submit only intended files, normally from the personal fork's existing
  `main` for one active contribution per repository; do not create a new branch
  for every PR. Preserve the source branch of an existing PR and update it for
  the same work. Push to the personal fork and target the organization's default
  branch. After a merge, synchronize from the organization before the next task.
  Keep component changes in their owning repository. Do not merge the PR
  or update distro submodule pins without separate authorization.
