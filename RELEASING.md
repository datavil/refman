# Releasing Refman

Refman uses semantic, three-part tags: `vX.Y.Z` (for example, `v0.12.0`). A tag
push triggers [`.github/workflows/ci.yml`](.github/workflows/ci.yml), which tests
the project and publishes the app ZIP, DMG, and Chrome extension ZIP.

## 1. Prepare the version

Update the Chrome extension version in all three places:

- `extension/package.json`
- `extension/package-lock.json` (both top-level occurrences)
- `extension/public/manifest.json`

The app version is not stored in source. The release workflow removes the
leading `v` from the tag and passes the result to `scripts/build_app.sh`.

## 2. Verify the release candidate

Run:

```sh
swift test
npm test --prefix extension
npm run package --prefix extension
unzip -p extension/refman-chrome-extension.zip manifest.json
git diff --check
ARCHITECTURES="arm64 x86_64" VERSION=0.12.0 scripts/build_app.sh
lipo dist/Refman.app/Contents/MacOS/Refman -verify_arch arm64 x86_64
lipo dist/Refman.app/Contents/MacOS/refman-agent -verify_arch arm64 x86_64
dist/Refman.app/Contents/MacOS/Refman --check-resources
plutil -extract CFBundleShortVersionString raw dist/Refman.app/Contents/Info.plist
codesign --verify --deep --strict dist/Refman.app
```

Replace `0.12.0` with the intended version. If CSL resources changed, also run
`xmllint --noout` on every added or modified `.csl` and locale XML file.

After a successful code change, close the running Refman and open the verified
build:

```sh
pkill -x Refman
open dist/Refman.app
```

## 3. Commit and tag

Review and stage only the intended files, then create an annotated tag on the
verified commit:

```sh
git status --short --branch
git diff --cached --check
git commit -m "Describe the release change"
git tag -a v0.12.0 -m "Refman v0.12.0"
git push --atomic origin master v0.12.0
```

The atomic push prevents `master` and the release tag from being updated
separately.

## 4. Monitor publication

An atomic branch-and-tag push starts two CI runs. Monitor the run whose branch
is the version tag; that run contains both the `build` and `release` jobs. Wait
for every step to succeed, including packaged-resource verification and
`Create release`.

The release must contain these assets:

- `Refman-vX.Y.Z.dmg`
- `Refman-vX.Y.Z.zip`
- `RefmanChrome-Extension-vX.Y.Z.zip`

Finally, confirm that the release is public, not a draft or prerelease, and
that <https://github.com/datavil/refman/releases/latest> resolves to the new
version. Confirm the working tree is clean and synchronized with
`origin/master`.

If CI fails, fix the cause and rerun the failed workflow when the commit does
not need to change. Do not move a published tag; use a patch release for source
changes after publication.
