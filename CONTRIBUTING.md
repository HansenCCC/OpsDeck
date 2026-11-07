# Contributing

Focused bug fixes, documentation improvements, and translations are welcome. For substantial behavior changes, open an issue describing the problem and proposed scope first.

1. Build using the README. Use a separate `OPSDECK_BUNDLE_IDENTIFIER` for development and tests.
2. Keep changes focused. Add or update a regression test for changed behavior when appropriate.
3. Run the relevant tests. For visible changes, review the running app and include screenshots made with fictional data.
4. Keep user-facing strings in `OpsDeck/Resources/Localizable.xcstrings`; update all supported locale entries and preserve format placeholders.
5. Preserve host-key checks, credential boundaries, command previews, cancellation, and redaction. Remote integration tests must use servers you are authorized to operate.
6. Do not commit signing identities, provisioning profiles, credentials, local databases, build output, or personal server information.

`gen_project.rb` generates the checked-in Xcode project and shared scheme. Run it after adding source/resources; commit the resulting project changes and preserve `Package.resolved`. Dependency updates should be deliberate and include updated license notices.

The app contains opt-in Debug smoke modes. Several perform remote writes; never invoke them against a production server merely to check a build. The README unit-test command does not require a remote server.

By submitting a contribution, you agree that your contribution is provided under this project's MIT license. Existing third-party notices must be retained.
