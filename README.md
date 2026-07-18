# pdf-slim

`pdf-slim` is becoming a safe, configurable Bash command for reducing PDF file
sizes with Ghostscript. Its default policy will preserve the visible appearance
of the source; grayscale and lossy compression will always require explicit
options.

> **Development status:** file discovery, validation, destination mapping,
> dry-run planning, and the tested Ghostscript conversion engine are implemented.
> Safe output publication and replacement are not implemented yet, so processing
> currently requires `--dry-run`.

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

## Usage

```text
pdf-slim.sh [options] [--] FILE_OR_DIRECTORY ...
```

Exactly one output mode is required:

```text
--output-dir DIR   Plan output beneath DIR, preserving relative paths
--replace          Plan replacement of originals when converted files are smaller
```

Current options:

```text
--recursive         Descend into supplied directories
--force             Bypass replacement-log checks (requires --replace)
--reprocess         Alias for --force
--timeout DURATION  Per-file timeout; defaults to 1h
--dry-run           Print the plan without Ghostscript or output writes
--quality MODE      Currently accepts only preserve
--grayscale         Request explicit grayscale conversion in a future conversion
--help              Show command help
--version           Show the development version
--                  End option parsing
```

Examples that work in the current dry-run phase:

```bash
./pdf-slim.sh --dry-run --output-dir ./slimmed report.pdf
./pdf-slim.sh --dry-run --output-dir ./slimmed --recursive ./documents
./pdf-slim.sh --dry-run --replace --recursive ./archive
./pdf-slim.sh --dry-run --replace -- -leading-hyphen.pdf
```

Exit statuses are `0` for success, `2` for invalid or unsafe requests, and `3`
when a real conversion is requested before the conversion layer is available.

## Safety model

The eventual `--replace` implementation will replace an original only after a
successful, validated conversion is strictly smaller. It will never remove the
original first. Output mode will never silently overwrite a destination or
publish a partial conversion.

Those conversion and publication guarantees describe the planned next phases;
the current implementation performs planning only.

## Requirements

The current traversal layer uses Bash, `find`, and `realpath`. It is tested with
macOS Bash 3.2 and newer Bash versions. Ghostscript will be required once the
conversion phase is implemented.

## Project layout

```text
pdf-slim.sh                 Active command
legacy/pdf_low.sh           Preserved original output-directory script
legacy/pdf_low_replace.sh   Preserved original replacement script
INSTRUCTIONS.md             Development handoff and implementation plan
processed_pdfs.log          Ignored legacy runtime history
```

The files under `legacy/` remain untouched reference material. The existing
`processed_pdfs.log` is intentionally ignored and is not treated as reliable
proof that a file was successfully processed.

## Roadmap

The next phases add safe temporary output publication, atomic replacement,
metadata preservation, corrected replacement logging, broader tests, and
finally explicit lossy quality modes.
