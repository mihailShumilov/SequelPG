---
name: release
description: Prepare a SequelPG release — set the version in project.pbxproj, move CHANGELOG.md's Unreleased section under the new version, update the README, and explain what the GitHub Actions release workflow will do on merge. Use when the user asks to cut, prepare, or bump a release, or to ship a feature branch.
---

# Prepare a SequelPG release

## How releases work

`.github/workflows/release.yml` runs on every push to `main` (skipped when the head commit contains `[skip ci]`):

1. Reads `MARKETING_VERSION` from `SequelPG.xcodeproj/project.pbxproj`.
2. If no tag `v<version>` exists, it ships that version **as-is**. Otherwise it bumps the patch and `CURRENT_PROJECT_VERSION`, and commits `Bump version to X.Y.Z [skip ci]`.
3. Builds a Release archive, packages `SequelPG-vX.Y.Z.dmg`, and creates the GitHub release + tag.

So a patch release needs no manual bump; a minor/major (or a deliberate patch) is done by setting the version inside the PR.

## Steps

1. Confirm the target version with the user (patch auto-bump vs. explicit version). Check the latest tag: `git tag --sort=-v:refname | head -3`.
2. For an explicit version, update **both** `MARKETING_VERSION` entries (Debug and Release) and increment both `CURRENT_PROJECT_VERSION` entries in `project.pbxproj`:
   ```bash
   grep -n 'MARKETING_VERSION\|CURRENT_PROJECT_VERSION' SequelPG.xcodeproj/project.pbxproj
   ```
3. `CHANGELOG.md` (Keep a Changelog): rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` and add a fresh empty `## [Unreleased]` above it. Order subsections Added / Changed / Fixed / Removed; write entries from the user's point of view.
4. Update `README.md` feature list / known limitations if the release changes them.
5. Run the full test suite (`build-and-test` skill) and report the result.
6. Commit with a Conventional Commit message, e.g. `chore: release 0.4.0`. Don't push, tag, or open a PR without the user's go-ahead; the workflow creates the tag itself — never create `v<version>` by hand.

## After the release

The marketing site at `/Users/mihailshumilov/sites/my/sequelpg.com` gets a post per version: `app/blog/sequelpg-v0XY-<slug>/page.tsx`, an index card, an RSS entry, and the `releaseVersion` constant. Offer to draft it; it's a separate repo and a separate commit.
