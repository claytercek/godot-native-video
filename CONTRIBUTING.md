# Contributing

## Writing release notes

Release notes come from [Changie](https://changie.dev/) fragments, not commit
messages. Install the standalone Changie v1.26.0 binary using its
[installation guide](https://changie.dev/guide/installation/), then run:

```bash
changie new
```

Commit the generated `.changes/unreleased/*.yaml` file with your PR. Describe
what changes for someone using the addon: new behavior, fixes, requirements,
and any steps needed to upgrade. Markdown and multiple paragraphs are supported.
Internal refactors, tests, and CI-only changes don't need a fragment. There's
no required fragment check in CI. Commit messages and rebase-and-merge remain
independent of release notes.

Choose `Fixed` or `Security` for a patch release; `Added`, `Changed`, or
`Deprecated` for a minor release. Put incompatible changes under `Breaking
Changes` or `Removed` and explain the migration. While the addon is pre-1.0,
these also bump the minor version; revisit that policy before releasing 1.0.
When several fragments are pending, the highest bump wins.

Preview pending release notes without modifying any files:

```bash
changie batch auto --dry-run --allow-no-changes=false
```

With no fragments, that command fails rather than producing an empty release.
Check that the generated changelog matches the committed version files with:

```bash
changie merge --dry-run | diff -u CHANGELOG.md -
```

## Publishing a release

Every push to `main` updates a single `release/changie` PR with the batched
notes and generated `CHANGELOG.md`. Review and merge that PR when ready to
release; GitHub's rebase-and-merge is supported. The Release workflow creates
the `vX.Y.Z` tag and GitHub release, then calls the existing binary build to
attach the addon ZIP. With no pending fragments, no release PR is needed.
The history through `v0.3.1` is preserved in `.changes/v0.3.1.md`; subsequent
releases each have their own `.changes/v*.md` file.

Edit fragments in the originating PR rather than editing generated release-PR
files: the next update regenerates those files from `main`. Do not batch
fragments manually in feature PRs; batching is the release bot's job.

In **Settings > Actions > General > Workflow permissions**, enable **Allow
GitHub Actions to create and approve pull requests**. The workflow uses the
default `GITHUB_TOKEN`; no extra secret is needed. Workflows triggered by the
bot-created PR may require approval before running. No changelog or fragment
check is required.

To refresh the release PR, manually run **Release** on `main`. Publication and
PR refresh run independently, so a failed PR update won't block a release's
binary build. New tags point to the commit checked out by the Release run.
The imported `v0.3.1` baseline and existing tags are skipped.

For a failed build, rerun the failed jobs or manually run **Build & Release**
with that release tag. Every build and packaging checkout uses the tag, not
the current `main`. If a tag exists without a GitHub release, create the release
for that tag using its `.changes/vX.Y.Z.md` notes before running the build.
