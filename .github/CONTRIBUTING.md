# Contributing

Thanks for wanting to help.

## Issues

When you open an issue, say what happened, what you expected and how to get
there, along with your macOS version and Mac model. For anything visual, a
screenshot or a short recording helps a lot. Please report security problems
privately, as described in [SECURITY.md](SECURITY.md).

## Code

1. Fork the repository and branch from `main`.
2. Keep each pull request to one fix or feature.
3. Follow the style of the code around your change.
4. Try the change in the running app first. Add a unit test only for things
   the app can't show you, like calculations checked against reference data,
   parsing, files written outside the app or input from other apps. Make sure
   the test fails without your fix. [ARCHITECTURE.md](../docs/ARCHITECTURE.md#build-and-test)
   explains how to run the tests. They run inside the app and use an installed
   Underbrim's settings and folder, so quit it and back up its settings first.
5. For changes to the interface, include before and after screenshots, and
   check VoiceOver and Reduce Motion.

## Translations

The strings are in `Underbrim/Localizable.xcstrings`, with English as the key
and a translation for each of the app's languages (the list is in
[ARCHITECTURE.md](../docs/ARCHITECTURE.md)). A new string needs all of them, or it
shows up in English. `python3 scripts/check-translations.py` lists anything
missing, or any translation whose placeholders don't match the English, and CI
runs it too. Xcode's String Catalog editor works well for editing them.
Please keep translation changes in their own pull request.

## License

By contributing, you agree that your contributions are licensed under the
[GNU GPL v3](../LICENSE), like the rest of the project.
