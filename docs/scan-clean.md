# Standalone image cleanup

Use `scan-clean.sh` when cleaned output should remain a raster image. Use
`pdf-slim.sh` when output should be PDF, whether input is a PDF or raster image.

```text
scan-clean.sh -i PATH [output options] [cleanup options]
```

Run `scan-clean.sh --help` for the authoritative option list.

## Input and cleanup modes

`--input` accepts exactly one explicitly named image, quoted basic glob, or
nonrecursive directory. It is not repeatable, and directory traversal is not
recursive.

With one selected image and no output option, the default `standard` mode
creates `NAME-standard.EXT` beside the source:

```bash
scan-clean.sh --input phone-photo.jpg
```

Choose a cleanup strength and exact output filename:

```bash
scan-clean.sh --input phone-photo.jpg --mode gentle \
  --output phone-photo-cleaned.jpg
```

Generate all three strengths for visual comparison:

```bash
scan-clean.sh --input phone-photo.jpg --all-modes
```

This creates `phone-photo-gentle.jpg`, `phone-photo-standard.jpg`, and
`phone-photo-strong.jpg`. If any name is unavailable, the group receives one
shared numeric index, such as `phone-photo-2-gentle.jpg` through
`phone-photo-2-strong.jpg`, so variants stay together when sorted.

## Output selection

An exact output extension selects the raster format, including PNG-to-JPEG:

```bash
scan-clean.sh --input form-scan.png --output form-scan-cleaned.jpg \
  --jpeg-quality 95 --background white
```

Clean supported images immediately inside one directory:

```bash
scan-clean.sh --input ./incoming-scans --output-dir ./cleaned
```

Or select one quoted glob:

```bash
scan-clean.sh --input './incoming-scans/*.jpg' --output-dir ./cleaned
```

Multiple selected images require `--output-dir`. The exact requested directory,
including missing parents, is created without extra nesting. Broad directory
and glob selections warn and skip non-images. Explicit unsupported inputs fail.
Symlinks, vector/document formats, animations, and multi-frame inputs are never
processed.

Existing automatic outputs receive the next numeric index. Exact and
output-directory destinations are never silently overwritten. Atomic overwrite
is available only when explicitly requested:

```bash
scan-clean.sh --input phone-photo.jpg --overwrite
```

`-O` is the short form of `--overwrite`. Preview planned names without writing:

```bash
scan-clean.sh --input phone-photo.jpg --all-modes --dry-run
```

## Metadata, orientation, and transparency

Supported metadata is preserved by default, including ICC, EXIF, capture date,
GPS, and resolution. Orientation is applied to pixels and normalized. Use
`--strip-metadata` to remove metadata.

Transparency is preserved when the output format supports it. JPEG cannot
represent alpha, so transparent pixels are flattened onto `--background`
(`white` by default). Default JPEG quality is 95.

## Diagnostics and safety

Use verbose output to show resolved settings, batch position, cleanup stages,
validation, and atomic publication:

```bash
scan-clean.sh --verbose --input phone-photo.jpg \
  --output phone-photo-cleaned.jpg
```

The per-image timeout defaults to one hour. Each result is validated and
published atomically. The command verifies that source bytes remain unchanged
before publication, tolerating filesystem metadata activity only after a
matching SHA-256 check. Batches continue after individual failures and return
status `1` if any conversion fails.

See [Safety and replacement history](safety.md) for shared safety principles.
