# pdf-slim

`pdf-slim` is a safe, configurable Bash command for reducing PDF file
sizes with Ghostscript. Its default policy preserves the visible appearance
of the source; grayscale and lossy compression will always require explicit
options.

Current stable version: `1.0.0`.

## Current capabilities

- Accepts multiple PDF files and directories.
- Matches `.pdf` extensions case-insensitively.
- Supports optional recursive directory traversal.
- Handles spaces, tabs, glob characters, and leading hyphens safely.
- Skips symlinks with a warning and never follows them.
- Requires an explicit output mode: `--output-dir DIR` or `--replace`.
- Preserves paths relative to each supplied directory in output mode.
- Refuses existing output files and collisions between supplied roots.
- Plans operations without running Ghostscript or writing output when using
  `--dry-run`.
- Records successful replacement outcomes and skips only unchanged files with
  matching canonical path, size, and modification time.

## Usage

```text
pdf-slim.sh [options] [--] FILE_OR_DIRECTORY ...
```

Exactly one output mode is required:

```text
--output-dir DIR   Write output beneath DIR, preserving relative paths
--replace          Replace originals only when converted files are smaller
```

Current options:

```text
  --recursive        Descend into supplied directories
  --reprocess        Reprocess files that match the replacement log; all safety
                      checks remain enabled (requires --replace)
  --timeout DURATION Per-file conversion timeout (default: 1h)
  --dry-run          Print planned actions; run no Ghostscript and write nothing
  --quality MODE     Image policy: preserve (default), balanced, or small
  --grayscale        Request explicit grayscale conversion
  --preserve-metadata MODE
                      Preserve none, basic, standard (default), or all metadata
  --help              Show this help and exit
  --version           Show the version and exit
  --                  End option parsing
```

## Use cases

Preview a replacement run without starting Ghostscript or changing anything:

```bash
./pdf-slim.sh --dry-run --replace report.pdf
```

Create a converted copy while leaving the original untouched:

```bash
./pdf-slim.sh --output-dir ./slimmed report.pdf
```

Convert several individual PDFs into one output directory:

```bash
./pdf-slim.sh --output-dir ./slimmed invoice.pdf handbook.PDF "meeting notes.pdf"
```

Recursively convert a directory while preserving its internal structure:

```bash
./pdf-slim.sh --output-dir ./slimmed --recursive ./documents
```

Replace an original only when the validated conversion is strictly smaller:

```bash
./pdf-slim.sh --replace large-report.pdf
```

Process every PDF beneath an archive. Successfully handled, unchanged files
recorded in `processed_pdfs.log` are skipped on later runs:

```bash
./pdf-slim.sh --replace --recursive ./archive
```

Retry files even when their current path, size, and modification time match the
replacement log:

```bash
./pdf-slim.sh --replace --reprocess --recursive ./archive
```

Preserve permissions and timestamps using the default `standard` policy:

```bash
./pdf-slim.sh --replace --preserve-metadata standard report.pdf
```

On macOS, also require ownership, file flags, ACLs, and extended attributes such
as Finder tags to be preserved:

```bash
./pdf-slim.sh --replace --preserve-metadata all tagged-report.pdf
```

Create output without copying source metadata, letting the new file retain its
naturally created metadata:

```bash
./pdf-slim.sh --output-dir ./slimmed --preserve-metadata none report.pdf
```

Explicitly create a grayscale PDF:

```bash
./pdf-slim.sh --output-dir ./grayscale --grayscale color-report.pdf
```

Set a shorter per-file conversion limit for a batch:

```bash
./pdf-slim.sh --replace --recursive --timeout 10m ./incoming
```

Use `--` before a filename beginning with a hyphen:

```bash
./pdf-slim.sh --dry-run --replace -- -leading-hyphen.pdf
```

Exit statuses are `0` for success, `1` when one or more conversions fail, and
`2` for invalid or unsafe requests.

## Safety model

`--replace` replaces an original only after a successful, validated conversion
is strictly smaller. It never removes the original first. Output mode never
silently overwrites a destination or publishes a partial conversion.

Metadata preservation is strict: if the selected metadata cannot be preserved,
the candidate is discarded and the original remains untouched. `standard`
preserves permissions plus access and modification timestamps. On macOS, `all`
also preserves and verifies ownership, file flags, ACLs, and extended attributes
such as Finder tags.

The replacement log starts with a null-terminated format marker. Each successful
replacement outcome then appends three null-terminated fields: canonical path,
current byte size, and modification time. A failed, timed-out, interrupted, or
invalid conversion never adds a record.

## Quality policies

- `preserve` keeps source image resolution and uses lossless Flate image
  encoding. It may produce a file that is not smaller; `--replace` retains the
  original in that case.
- `balanced` never upscales, caps images above 300 DPI using bicubic
  downsampling, and uses high-fidelity JPEG compression (`QFactor 0.15`).
- `small` never upscales, caps images above 250 DPI using bicubic downsampling,
  and uses stronger JPEG compression (`QFactor 0.4`).

`--grayscale` is independent and can be combined with any quality policy.

## Requirements

The command uses Bash, Ghostscript, GNU `timeout` (available as `timeout` or
`gtimeout`), `find`, and `realpath`. It is tested with macOS Bash 3.2 and newer
Bash versions. The `all` metadata mode additionally uses macOS `xattr`.

## Installation

Make the script executable and add its directory to `PATH`, or invoke it by its
path:

```bash
chmod +x pdf-slim.sh
export PATH="/path/to/pdf-slim:$PATH"
pdf-slim.sh --version
```

For a persistent installation, add the `export PATH=...` line to the profile
file used by your shell.

## Testing

Run the complete automated suite with:

```bash
./tests/run.sh
```

The suite uses disposable files and a Ghostscript command double to cover CLI
validation and traversal, conversion failures and timeouts, atomic publication,
metadata preservation, interruption cleanup, and replacement logging. It runs
on macOS Bash 3.2 and newer Bash versions.

## Project layout

```text
pdf-slim.sh                 Active command
legacy/pdf_low.sh           Preserved original output-directory script
legacy/pdf_low_replace.sh   Preserved original replacement script
INSTRUCTIONS.md             Development handoff and implementation plan
processed_pdfs.log          Ignored active replacement history (created on demand)
tests/                       Automated conversion, publication, logging, and CLI tests
```

The files under `legacy/` remain usable reference tools during development. The
preexisting local runtime history is archived (and remains excluded from Git)
as `legacy/processed_pdfs.log`. The active script creates or reuses an ignored
root-level `processed_pdfs.log` in its null-delimited versioned format.
`--reprocess` bypasses matching records without erasing history or disabling
safety checks.

## Release status

Version `1.0.0` implements the agreed interface, safety model, metadata modes,
quality policies, replacement logging, and automated test coverage. Future
changes should remain backward-compatible or be released as a new major version.
