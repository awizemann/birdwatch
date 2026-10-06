# releases/

One directory per shipped version, named `v<MARKETING_VERSION>` (e.g. `v0.1.0`).

## Convention

```
releases/
  v0.1.0/
    RELEASE_NOTES.md              # tracked — REQUIRED before release.sh will run
    Birdwatch-v0.1.0-Universal.zip # NOT tracked (gitignored) — built + notarized artifact
    appcast.xml                    # tracked — generated + committed (locally) by scripts/appcast.sh, published to gh-pages
```

## RELEASE_NOTES.md

Write the notes **before** running the release, and commit them. `scripts/release.sh`
refuses to start without `releases/v<VERSION>/RELEASE_NOTES.md`, and uses the file
verbatim as the GitHub release body.

The first line is a `#` heading and becomes the summary line of the release commit
message, so make it a real one-line description:

```markdown
# Faster iCloud scans and honest diagnostics rows

- Diagnostics: iCloud roots that can't be trashed now say so instead of failing silently.
- Sync status refreshes ~3x faster on large libraries.
```

## Why the zips are not tracked

The `.zip` is a signed, notarized, stapled build artifact — reproducible from the tag
and hosted on the GitHub release. Tracking it would bloat the repo for no benefit.
`.gitignore` keeps `releases/**/*.zip` out while leaving the notes tracked.

## Publishing

```sh
export DEVELOPMENT_TEAM=XXXXXXXXXX
./scripts/release.sh 0.1.0 --draft   # rehearsal: builds, notarizes, draft release, no tag/push
./scripts/release.sh 0.1.0           # the real thing: tag, push, release, publish appcast
```

What the script enforces:

- The version is `X.Y.Z` and greater than the newest `vX.Y.Z` tag, counting tags fetched from
  `origin` (`git fetch --tags origin` must succeed).
- `BW_BUNDLE_ID_SUFFIX` (the dev-build bundle id hook) must not be set.
- `CURRENT_PROJECT_VERSION` is bumped to the last tag's + 1 only if `project.yml` isn't
  already above it. A `--draft` rehearsal's local release commit therefore isn't bumped a
  second time by the real run (v0.1.3 shipped build 7 after a 6-then-7 double bump).
- `project.yml` and the regenerated `Birdwatch.xcodeproj` are committed together.
- The full test suite runs before archiving; any failure before the release commit restores
  `project.yml` and the project to `HEAD`, so a fixed re-run starts from a clean tree.
- `BW_STATS_WRITE_KEY` reaches only the archive step.
- `main` is pushed before the tag is created. If the main push fails, nothing is tagged
  and re-running is safe. If the tag push fails, the script prints the exact commands to
  finish by hand.
- `scripts/appcast.sh` refuses to publish unless the Keychain EdDSA key matches the
  `SUPublicEDKey` inside the release zip's app, and `sign_update --verify` accepts the
  signature written into `appcast.xml`. It then commits `releases/v<VER>/appcast.xml`
  locally (that file only, message `release: v<VER> appcast`) and does not push it.
  The next release's `git push origin main` carries it, or you can push it yourself.
  Nothing is left untracked to trip the next run's clean-tree check.
