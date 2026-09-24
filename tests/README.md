# Test suite

The automated suite exercises `pdf-slim.sh`, `scan-clean.sh`, their shared
workflows, and the safety behavior around conversion and publication. Tests use
disposable temporary directories and do not read or modify the active
replacement history in the user state directory.

## Running tests

From the project root, run the complete suite:

```bash
./tests/run.sh
```

Run one test directly when working on a focused area:

```bash
./tests/test-logging.sh
./tests/test-scan-clean-command.sh
```

Before committing executable or test changes, also run syntax checks and
ShellCheck:

```bash
bash -n pdf-slim.sh scan-clean.sh tests/*.sh
shellcheck pdf-slim.sh scan-clean.sh tests/*.sh
```

## Requirements

The complete suite requires the same macOS command-line environment used by the
commands themselves:

- Bash 3.2 or newer.
- Ghostscript (`gs`).
- ImageMagick (`magick`).
- Poppler commands used by PDF scan cleanup: `pdfinfo`, `pdfimages`,
  `pdftotext`, `pdfdetach`, and `pdftocairo`.
- GNU `timeout`, available as either `timeout` or `gtimeout`.
- `realpath` and the standard macOS command-line tools.
- ShellCheck for the separate lint command above.

The suite fails clearly when a required integration-test dependency is absent;
it does not silently skip that coverage. The `all` metadata checks run only on
macOS when `xattr` is available.

## Coverage by test

| Test | Coverage |
| --- | --- |
| `test-conversion.sh` | Ghostscript argument construction for presets, detailed DPI/JPEG settings, and grayscale; successful output; nonzero, partial, empty, and timed-out conversion failures; candidate cleanup. |
| `test-publication.sh` | Exact-file, output-directory, and replacement publication; smaller-only replacement; permissions and timestamps; macOS extended metadata and ACLs; interruption cleanup; destination-created-during-conversion races. |
| `test-logging.sh` | Version-2 replacement records and permissions; identity and processing-policy matching; `--reprocess`; successful and kept-not-smaller outcomes; failed-attempt exclusion; malformed/incomplete log refusal; version-1 migration and relocation. |
| `test-concurrent-logging.sh` | Independent READY/RELEASE fixture validation; bounded barrier failure; simultaneous creation of a new log; simultaneous appends to an existing log; complete unique records, permissions, and lock cleanup. |
| `test-timestamps.sh` | Date and time prefixes, same-day completion, midnight rollover, and multiline operational diagnostics. |
| `test-cli.sh` | Help, version, parameterless guidance, option validation, quoted globs, unusual filenames, dry runs, recursive and nonrecursive traversal, symlink refusal, output conflicts and collisions, quality controls, default scan-clean mode, and exact-file publication. |
| `test-real-gs.sh` | Real Ghostscript output for all three quality presets in color and grayscale, detailed quality controls, exact output, and smaller-file replacement; every result is parsed again by Ghostscript. |
| `test-scan-cleanup.sh` | Real PDF scan cleanup at gentle, standard, and strong strengths; page-size preservation; detailed and lossless quality paths; grayscale multipage output; refusal of visible vector/text content; mixed-batch behavior. |
| `test-scan-clean-delegation.sh` | Discovery of the sibling or `PATH` cleanup engine; delegated mode, timeout, input/output, and metadata arguments; engine failure and timeout propagation; temporary-directory cleanup; missing dependency refusal. |
| `test-image-to-pdf.sh` | Raster-image-to-PDF cleanup; physical sizing from credible or fallback density; detailed quality and grayscale; batch and recursive mapping; destination collisions; animated-image refusal; replacement prohibition. |
| `test-scan-clean-command.sh` | Standalone image cleanup help and validation; default and all-mode naming; overwrite behavior; metadata, transparency, background, density, and JPEG quality; directory/glob filtering; output safety; partial failure, timeout, and temporary cleanup. |

## Test doubles

- `fake-gs.sh` simulates successful, failed, partial, empty, and slow
  Ghostscript runs. Its optional bounded READY/RELEASE barrier makes concurrent
  tests deterministic.
- `fake-magick.sh` delegates ordinary work to the real ImageMagick command and
  can simulate partial failure or delay.
- `fake-scan-clean.sh` records delegated arguments and can simulate cleanup
  failure or delay.

Tests that rely on a command double validate the relevant fixture behavior
independently. Real integration tests complement those controlled failure-path
tests.

## Scope

The automated suite verifies file integrity, command behavior, PDF validity,
image properties, and safety invariants. It does not judge subjective visual
quality. Changes to cleanup strength or lossy PDF settings still require
comparison using representative documents.
