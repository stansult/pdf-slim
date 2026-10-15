# pdf-slim

`pdf-slim` provides two safe, configurable Bash commands:

- `pdf-slim.sh` reduces PDF file sizes and creates cleaned PDFs from PDF or
  raster-image scans.
- `scan-clean.sh` improves photographed or scanned documents while keeping
  raster-image output.

Use `pdf-slim.sh` when output should be PDF. Use `scan-clean.sh` when output
should remain an image.

Current versions: `pdf-slim.sh` 1.4.0 and `scan-clean.sh` 1.0.1.

## Quick start

Convert one PDF to an exact output filename:

```bash
pdf-slim.sh --input annual-report.pdf --output annual-report-slim.pdf
```

Convert PDFs into another directory while preserving relative paths:

```bash
pdf-slim.sh --input ./documents --output-dir ./slimmed --recursive
```

Replace an original only when the validated result is strictly smaller:

```bash
pdf-slim.sh --input research-paper.pdf --replace
```

Clean an image-only PDF scan using the default `standard` cleanup strength:

```bash
pdf-slim.sh --input employment-form-scan.pdf \
  --output employment-form-cleaned.pdf --clean-scan
```

Clean a raster image and create a PDF:

```bash
pdf-slim.sh --input phone-scan.jpg --output phone-scan-cleaned.pdf \
  --clean-scan standard
```

Clean an image while keeping image output:

```bash
scan-clean.sh --input form-scan.png --output form-scan-cleaned.jpg
```

See [additional PDF examples](docs/examples.md) and the
[standalone image-cleanup guide](docs/scan-clean.md).

## Current capabilities

### `pdf-slim.sh`

- Accepts repeatable PDF, directory, and quoted-glob inputs; raster images are
  accepted with `--clean-scan`.
- Matches `.pdf` case-insensitively and supports optional recursive traversal.
- Handles spaces, tabs, glob characters, and leading hyphens safely.
- Skips symlinks rather than following them.
- Requires one explicit output mode: exact file, output directory, or safe
  replacement.
- Preserves paths relative to supplied directories and refuses destination
  collisions or existing output files.
- Supports dry-run planning, configurable quality, grayscale conversion,
  metadata policies, per-file timeouts, and verbose diagnostics.
- Records successful replacement outcomes and skips only unchanged files with
  matching identity and processing policy.
- Provides gentle, standard, and strong cleanup for safely detected image-only
  scans while preserving visible page geometry, resolution, and color by
  default.
- Delegates page-pixel cleanup to `scan-clean.sh` and automatically processes
  up to five PDF pages concurrently; `--jobs N` provides an explicit override.
- Privately records anonymous PDF scan-clean performance metrics for future
  concurrency tuning; verbose mode prints a one-line summary.
- Accepts raster scans directly and produces PDF output through the same
  cleanup and PDF-quality pipeline.

### `scan-clean.sh`

- Cleans supported single-frame raster images directly.
- Provides gentle, standard, and strong cleanup plus `--all-modes` comparison.
- Supports exact output, automatic collision-safe naming, and nonrecursive
  directory or quoted-glob batches.
- Converts raster formats according to the requested output extension.
- Preserves supported metadata and transparency, with explicit controls for
  metadata stripping, JPEG background, and JPEG quality.
- Refuses symlinks, vector documents, animations, and multi-frame images.
- Validates source stability and publishes atomically; overwrite requires
  explicit `-O` / `--overwrite`.

## `pdf-slim.sh` usage

```text
pdf-slim.sh [options]
```

Input paths are explicit and repeatable:

```text
-i, --input PATH    Input PDF, raster image with --clean-scan, directory,
                    or quoted glob pattern; repeat for multiple inputs
```

Exactly one output mode is required:

```text
-o, --output FILE   Write one input as PDF to exactly FILE
--output-dir DIR    Preserve input-relative paths beneath DIR
--replace           Replace originals only when safe conversion is smaller
```

Quality has two mutually exclusive approaches:

```text
Preset:
  --quality MODE       Use preserve, balanced, or small
                       (default when no quality options are given: preserve)
Detailed:
  --max-dpi DPI        Downsample color/grayscale images above DPI
                       (default: no color/grayscale DPI cap)
  --jpeg-recompress Q  JPEG-encode color/grayscale images at QFactor Q,
                       0.0-1.0; lower values preserve more quality
                       (default: existing eligible JPEGs pass through)
--grayscale            Convert colors to grayscale independently
```

Do not combine `--quality` with `--max-dpi` or `--jpeg-recompress`. See
[Quality policies](docs/quality.md) for preset values and detailed behavior.

Scan cleanup options:

```text
--clean-scan [MODE]  Improve an image-only scan using gentle, standard, or
                     strong cleanup (default mode: standard)
--jobs N             Clean up to N PDF pages concurrently, 1-11
                     (default: automatic, up to 5; requires --clean-scan)
```

With no quality option, scan cleanup retains source resolution and uses JPEG
`QFactor 0.10`. `--grayscale` remains independent. Raster-image input has one
page, so a `--jobs` value above one provides no benefit. See the
[scan-clean concurrency record](docs/scan-clean-concurrency.md)
for measured performance and resource tradeoffs.

Other options:

```text
--recursive               Descend into supplied directories
--reprocess               Bypass matching replacement history; requires
                          --replace and retains all safety checks
--timeout DURATION        Per-file conversion timeout (default: 1h)
--dry-run                 Print planned actions without conversion or writes
-v, --verbose             Show resolved settings, stages, and scan performance
--preserve-metadata MODE  Preserve none, basic, standard (default), or all
-h, --help                Show command help
--version                 Show the version
```

Run `pdf-slim.sh --help` for the authoritative command summary. Exit status is
`0` for success, `1` when one or more conversions fail, and `2` for an invalid
or unsafe request.

## Safety summary

`--replace` never deletes an original first. Replacement occurs only after a
successful, validated conversion is strictly smaller and the source is proven
unchanged. Exact-file and output-directory modes do not silently overwrite
destinations. Temporary candidates are removed after success, failure, timeout,
or interruption.

Scan cleanup first verifies that flattening will not discard detectable text,
forms, JavaScript, attachments, links, named destinations, visible vector
content, or unsupported page-image structures. Refused input remains untouched.

Both commands distinguish real source changes from metadata-only filesystem
activity by confirming identical bytes with SHA-256 when necessary. Metadata
preservation is strict: failure to preserve the selected policy discards the
candidate.

See [Safety and replacement history](docs/safety.md) for scan eligibility,
metadata policies, concurrent source activity, state locations, permissions,
and replacement-log semantics.

## Requirements

Both commands use Bash, GNU `timeout` (available as `timeout` or `gtimeout`),
`find`, `realpath`, and one SHA-256 provider: `shasum`, `sha256sum`, or
`openssl`.

- `scan-clean.sh` requires ImageMagick (`magick`).
- `pdf-slim.sh` requires Ghostscript (`gs`).
- PDF scan cleanup also requires the companion `scan-clean.sh`, ImageMagick,
  and Poppler (`pdfinfo`, `pdfimages`, `pdftotext`, `pdfdetach`, and
  `pdftocairo`).
- Direct raster-image-to-PDF cleanup does not require Poppler.
- The `all` PDF metadata mode additionally requires macOS `xattr`.

Optional commands are checked only when requested features need them. The
scripts are tested with macOS Bash 3.2 and newer Bash versions.

## Installation

Make both commands executable and add their directory to `PATH`, or invoke them
by path:

```bash
chmod +x pdf-slim.sh scan-clean.sh
export PATH="/path/to/pdf-slim:$PATH"
pdf-slim.sh --version
scan-clean.sh --version
```

For persistent use, add the `PATH` export to the profile file loaded by your
shell.

## Testing

Run the complete automated suite with:

```bash
./tests/run.sh
```

See the [detailed testing guide](tests/README.md) for prerequisites, focused
commands, fixtures, and test coverage. Subjective quality and performance still
require representative-document comparisons; concurrency evidence and tuning
plans are in [PDF scan-cleanup concurrency](docs/scan-clean-concurrency.md).

## Documentation

- [PDF command examples](docs/examples.md)
- [Standalone image cleanup](docs/scan-clean.md)
- [PDF quality policies](docs/quality.md)
- [Safety and replacement history](docs/safety.md)
- [PDF scan-cleanup concurrency](docs/scan-clean-concurrency.md)
- [Automated test suite](tests/README.md)
- [Development handoff](INSTRUCTIONS.md)

## Project layout

```text
pdf-slim.sh       PDF reduction and PDF-output scan cleanup
scan-clean.sh     Standalone raster-image cleanup
README.md         Project overview and core interface
docs/             Focused user, safety, quality, and design documentation
INSTRUCTIONS.md   Development handoff and retained design constraints
tests/            Automated suites, fixtures, and test doubles
```
