# Tests

Run the local suites on macOS with Xcode, Python 3 and Node.js.

```sh
Tests/run.sh                          # All local suites
Tests/run.sh --list                   # Every available suite
Tests/run.sh SettingsSearch UnlockFlow
Tests/run.sh MultiFace                # Downloads two synthetic face images
```

Run `bash Tests/<Name>/run.sh` directly to pass arguments accepted by an
individual suite, such as a directory for rendered images. AppKit and visual
fixtures need a logged-in desktop session. `Support/` contains shared test helpers.
