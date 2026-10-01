# Releasing CrossByte

What a release needs, in the order it needs it.

## Before

1. **The hxcpp fork first.** CrossByte's native code calls what the
   `production` branch of `dimensionscape/hxcpp` adds, and CI builds that
   branch from GitHub. Push the fork's `production` before CrossByte, or
   native CI builds against the old fork and fails.
2. **The extensions next**, if they changed: `crossbyte-libuv`,
   `crossbyte-brotli`, `crossbyte-lz4`. The Extensions job builds their
   `main` branches.
3. **CI green on every job**, including the ones that only run there: the
   native suite on Windows, Linux and macOS, the browser suite, the
   database suites. Check each step ran for as long as a real run takes; a
   step that finishes in seconds may have run nothing.

## The release commit

1. `haxelib.json`: `version`, and a `releasenote` of a sentence.
2. `CHANGELOG.md`: rename `## Unreleased` to `## <version> - <yyyy-mm-dd>`
   and start a new, empty `## Unreleased` above it. Keep its Highlights
   and Upgrading sections current; they are what most readers read.
3. `README.md`: the Install section names the hxcpp branch native builds
   need; check it still does.

## Packaging

```sh
haxe ci/package.hxml
```

This writes `dist/crossbyte-<version>.zip` from the committed tree (see
`ci/Package.hx`), and refuses to run over uncommitted changes to what it
packages. Before submitting it, install it into an empty haxelib
repository beside the fork's hxcpp and build a sample with `-lib crossbyte`
alone: that is the check that nothing a user's build reads was left out.

```sh
haxelib submit dist/crossbyte-<version>.zip
git tag v<version>
git push origin v<version>
```

Publish a GitHub release for the tag with the version's changelog section.
