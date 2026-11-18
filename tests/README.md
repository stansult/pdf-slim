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

To verify compatibility with the Bash 3.2 included with macOS, run:

```bash
/bin/bash ./tests/run.sh
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

GitHub Actions runs these syntax, ShellCheck, and complete-suite checks under
the macOS-provided Bash 3.2 on a pinned macOS runner for every push to `master`
and every pull request. The workflow can also be started manually from GitHub.
Subjective visual-quality and performance comparisons remain manual.

## Requirements

The complete suite requires the same macOS command-line environment used by the
commands themselves:

- Bash 3.2 or newer.
- Ghostscript (`gs`).
- ImageMagick (`magick`).
- Poppler commands used by PDF scan cleanup: `pdfinfo`, `pdfimages`,
  `pdftotext`, `pdfdetach`, and `pdftocairo`.
- GNU `timeout`, available as either `timeout` or `gtimeout`.
- Expect (`expect`) for interactive choice coverage.
- One SHA-256 provider: `shasum`, `sha256sum`, or `openssl`.
- `realpath` and the standard macOS command-line tools.
- ShellCheck for the separate lint command above.

The suite fails clearly when a required integration-test dependency is absent;
it does not silently skip that coverage. The `all` metadata checks run only on
macOS when `xattr` is available.

## Coverage by test

| Test | Coverage |
| --- | --- |
| `test-conversion.sh` | Ghostscript argument construction for presets, detailed DPI/JPEG settings, and grayscale; successful output; independently verified recovery-warning fixture and narrow detection; nonzero, partial, empty, and timed-out conversion failures; candidate cleanup. |
| `test-fingerprints.sh` | SHA-256 provider selection through `shasum`, `sha256sum`, and `openssl`, plus clear failure when no provider exists, for both commands. |
| `test-publication.sh` | Exact-file, output-directory, and replacement publication; smaller-only replacement; recovery-warning source preservation, review output, and numbered collision handling; metadata-only `ctime` tolerance with SHA-256 verification; same-size content-change rejection with restored modification time; final replacement checkpoint and metadata refresh; permissions and timestamps; macOS extended metadata and ACLs; interruption cleanup; destination-created-during-conversion races. |
| `test-logging.sh` | Version-2 replacement records and permissions; identity and processing-policy matching; `--reprocess`; successful and kept-not-smaller outcomes; failed and recovery-warning attempt exclusion; malformed/incomplete log refusal; version-1 migration and relocation. |
| `test-concurrent-logging.sh` | Independent READY/RELEASE fixture validation; bounded barrier failure; simultaneous creation of a new log; simultaneous appends to an existing log; complete unique records, permissions, and lock cleanup. |
| `test-performance-metrics.sh` | Versioned private TSV creation; deterministic concurrent appends; permissions and lock cleanup; malformed-file refusal; anonymous failure records; one-warning behavior; metrics/product-status isolation; exclusion of non-concurrent modes. |
| `test-timestamps.sh` | PDF-command date and time prefixes, same-day completion, midnight rollover, unprefixed multiline continuations, labeled errors and warnings, prefix-free verbose-message gating, progress thresholds, fixed start timestamps, monotonic durations across wall-clock changes, redirection suppression, and updater cleanup. |
| `test-scan-clean-timestamps.sh` | Standalone cleanup date and time prefixes, same-day completion, midnight rollover, unprefixed multiline continuations, labeled errors and warnings, prefix-free verbose-message gating, progress thresholds, fixed start timestamps, monotonic durations across wall-clock changes, redirection suppression, and updater cleanup. |
| `test-progress-tty.sh` | Real pseudo-terminal detection and animated foreground-stage output for both commands. |
| `test-cli.sh` | Help, version, parameterless guidance, option validation, quoted globs, unusual filenames, dry runs, recursive and nonrecursive traversal, symlink refusal, output conflicts and collisions, quality controls, default scan-clean mode, verbose CLI reporting, redirected-output control-code suppression, exact-file publication, multi-file progress, success/skipped summaries, and recovered-output failure summaries. |
| `test-real-gs.sh` | Real Ghostscript output for all three quality presets in color and grayscale, detailed quality controls, verbose conversion stages, exact output, and smaller-file replacement; every result is parsed again by Ghostscript. |
| `test-scan-inspection.sh` | Focused PDF scan-cleanup acceptance of a structurally associated soft mask; searchable-text and residual-vector detection; and refusal guards for invalid page counts, encryption, forms, JavaScript, geometry, attachments, links, named destinations, image type/count/DPI, and orphaned or mismatched masks. |
| `test-scan-content-choice.sh` | Independently constructed image-plus-text PDF; safe non-interactive refusal; interactive clean, preserve, and default-Quit choices; text retention/removal; and conditional prior-output wording in a batch. |
| `test-scan-cleanup.sh` | Real PDF scan cleanup at gentle, standard, and strong strengths; real alpha-image/soft-mask input; mixed 0/90/180/270-degree page geometry; singular-page verbose wording and metrics summary; private success/failure metrics; page-size preservation; detailed and lossless quality paths; grayscale multipage output; refusal of non-image page structure; normal and verbose mixed-batch progress, separation, counts, and failure summaries. |
| `test-scan-parallel.sh` | Independently validated controlled-worker overlap; explicit concurrency bounds; automatic `min(page count, 5)` selection; plural-page automatic/explicit worker wording; workload and worker metrics; ordered assembly; failed-page propagation and assembly suppression. |
| `test-scan-clean-delegation.sh` | Discovery of the sibling or `PATH` cleanup engine; delegated mode, timeout, input/output, and metadata arguments; engine failure and timeout propagation; temporary-directory cleanup; missing dependency refusal. |
| `test-image-to-pdf.sh` | Raster-image-to-PDF cleanup; physical sizing from credible or fallback density; detailed quality and grayscale; batch and recursive mapping; destination collisions; animated-image refusal; replacement prohibition. |
| `test-pdf-scan-tones.sh` | Independently validated gray-, bright-, and blue-cast paper fixtures assembled into image-only PDFs; end-to-end grayscale and color cleanup; final paper-tone consistency and neutrality; medium-ink darkening; faint-mark and colored-mark retention. |
| `test-scan-clean-tones.sh` | Independently verified gray-, bright-, and blue-cast paper fixtures; adaptive white-point and white-balance guardrails; gray-paper whitening; bright-paper stability; progressive midtone-ink darkening; faint-mark and colored-mark retention. |
| `test-scan-clean-command.sh` | Standalone image cleanup help and validation; default and all-mode naming; verbose CLI reporting; redirected-output control-code suppression; overwrite behavior; metadata, transparency, background, density, and JPEG quality; directory/glob filtering; metadata-only source churn and real source-change detection; publication races; signal, partial-failure, timeout, and temporary cleanup. |

## Test doubles

- `fake-gs.sh` simulates successful, recovery-warning, harmless-warning,
  failed, partial, empty, and slow Ghostscript runs, plus metadata-only and
  same-size source changes. Its
  optional bounded READY/RELEASE barrier makes concurrent tests deterministic.
- `fake-magick.sh` delegates ordinary work to the real ImageMagick command and
  can simulate partial failure or delay. Its bounded READY/RELEASE barrier makes
  source-change, publication-race, and signal tests deterministic.
- `fake-scan-inspector.sh` supplies intentional PDF-inspection results so
  destructive-flattening detection and refusal paths can be tested
  independently.
- `fake-scan-clean.sh` records delegated arguments and can simulate cleanup
  failure or delay.

Tests that rely on a command double validate the relevant fixture behavior
independently. Real integration tests complement those controlled failure-path
tests.

## Scope

The automated suite verifies file integrity, command behavior, PDF validity,
image properties, and safety invariants. It does not judge subjective visual
quality. Changes to cleanup strength or lossy PDF settings still require
comparison using representative documents. Performance is likewise not an
automated pass/fail property; completed manual experiments are recorded in the
[scan-clean concurrency documentation](../docs/scan-clean-concurrency.md).
