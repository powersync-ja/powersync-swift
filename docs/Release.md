# PowerSync Swift SDK

## Pre-release checks

* Confirm every PR you want in the release has been merged into `main`.
* Update `CHANGELOG.md` with the changes.
* Update `libraryVersion` variable in `Sources/PowerSync/CurrentVersion.swift` with the latest version in `CHANGELOG.md` (if a new version is being specified).

## Release

Given that the Swift SDK has no additional release assets and just consists of a tag, release it by creating a release
on the [GitHub website](https://github.com/powersync-ja/powersync-swift/releases/new).

Under the `Tag` option, enter the name of the version without a `v` prefix (e.g. `1.16.0`) and select "Create new tag".
Use the version as a release title and `main` as a target ref.

To generate release notes, select the previous tag and use the "Generate release notes" feature.
