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
   database suites. Check that each step ran for as long as a real run
   takes; a step that finishes in seconds may have run nothing. "Reading a
   CI failure" below says how a failure reads.

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
alone: that checks that nothing a user's build reads was left out.

```sh
haxelib submit dist/crossbyte-<version>.zip
git tag v<version>
git push origin v<version>
```

Publish a GitHub release for the tag with the version's changelog section.
`haxelib submit` needs lib.haxe.org; CI does not (below), but a release
waits for the registry.

## How CI gets its libraries

- **The Haxe libraries** (utest, hxjava, hxnodejs, dox) are listed in
  `ci/haxelibs.txt`, each with its exact version, its GitHub repository and
  the commit of that version. `.github/actions/haxelibs` installs them from
  a cache keyed on that list; on a miss, from GitHub at the commit
  (`haxelib git`); and only if GitHub cannot supply the commit, from
  lib.haxe.org. So CI keeps working while the registry is down.
- **To change a version**, find the commit of that release and check that
  it is the registry's release (`ci/haxelibs.txt` says how each was
  checked), then edit the list. The next run on each OS installs that one
  library, and every run after takes it from the cache. Adding or dropping
  a library installs all of them, once. GitHub drops a cache unused for
  seven days.
- **hxcpp** comes from the fork's git repository on GitHub, through
  `.github/actions/hxcpp`. `haxelib git` asks the registry only for a
  library's dependencies, and hxcpp has none.

## Reading a CI failure

The step that fails is the step whose command failed. A step that runs
several commands names the one that failed in an error annotation. bash
steps stop at the first command that fails. pwsh steps do not stop at a
failing native command, so each runs one; and because the runner reports
any failing pwsh step as exit code 1, a step that runs a test or a sample
prints the code in full: `0xC0000005` is an access violation, `0xC0000409`
a fail-fast abort, `0xC00000FD` a stack overflow.
