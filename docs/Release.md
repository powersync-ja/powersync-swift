# PowerSync Swift SDK

## Releasing

* Confirm every PR you want in the release has been merged into `main`.
* Update `CHANGELOG.md` with the changes.
* In GitHub actions on GitHub manually run the `Release PowerSync` action. You will be required to update the version and add release notes.
  The version string should have the form `1.0.0-beta.x` for beta releases, there should not be a `v` prefix on the tag name.
* If the release notes are complicated and don't fit on a single line it is easier to rather update those after the release is completed by updating the release notes in the new release.
