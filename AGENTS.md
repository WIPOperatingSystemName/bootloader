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
- Submit only intended files on a feature branch, push to the contributor's
  personal fork and target the organization repository's default branch.
  Keep component changes in their owning repository. Do not merge the PR
  or update distro submodule pins without separate authorization.
