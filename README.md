# pdf-slim

`pdf-slim` is becoming a safe, configurable Bash command for reducing PDF file
sizes with Ghostscript. Its default policy will preserve the visible appearance
of the source; grayscale and lossy compression will always require explicit
options.

> **Development status:** file discovery, validation, destination mapping,
> Ghostscript conversion, atomic output publication, and strictly-smaller
> replacement are implemented. Replacement logging and lossy quality modes are
> still pending.

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
--output-dir DIR   Write output beneath DIR, preserving relative paths
--replace          Replace originals only when converted files are smaller
```

Current options:

```text
--recursive         Descend into supplied directories
--force             Bypass replacement-log checks (requires --replace)
--reprocess         Alias for --force
--timeout DURATION  Per-file timeout; defaults to 1h
--dry-run           Print the plan without Ghostscript or output writes
--quality MODE      Currently accepts only preserve
--grayscale         Explicitly convert output to grayscale
--preserve-metadata MODE
                    Preserve none, basic, standard (default), or all metadata
--help              Show command help
--version           Show the development version
--                  End option parsing
```

Examples:

```bash
./pdf-slim.sh --output-dir ./slimmed report.pdf
./pdf-slim.sh --output-dir ./slimmed --recursive ./documents
./pdf-slim.sh --replace --recursive ./archive
./pdf-slim.sh --replace --preserve-metadata all tagged-report.pdf
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

## Requirements

The command uses Bash, Ghostscript, GNU `timeout` (available as `timeout` or
`gtimeout`), `find`, and `realpath`. It is tested with macOS Bash 3.2 and newer
Bash versions. The `all` metadata mode additionally uses macOS `xattr`.

## Project layout

```text
pdf-slim.sh                 Active command
legacy/pdf_low.sh           Preserved original output-directory script
legacy/pdf_low_replace.sh   Preserved original replacement script
INSTRUCTIONS.md             Development handoff and implementation plan
processed_pdfs.log          Ignored legacy runtime history
```

The files under `legacy/` remain usable reference tools during development. The
existing `processed_pdfs.log` is intentionally ignored and is not treated as
reliable proof that a file was successfully processed.

## Roadmap

The next phases add null-delimited replacement logging with file identity data,
broader tests, and finally explicit lossy quality modes.
