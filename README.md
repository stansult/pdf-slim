# pdf-slim

`pdf-slim` provides two safe, configurable Bash commands: `pdf-slim.sh` reduces
PDF file sizes with Ghostscript, while `scan-clean.sh` improves photographed or
scanned document images with ImageMagick. PDF scan cleanup remains available
through `pdf-slim.sh`; the standalone command applies the same cleanup concept
directly to raster images.

Use `pdf-slim.sh` when the output should be a PDF. Use `scan-clean.sh` when the
output should remain an image.

Current versions: `pdf-slim.sh` 1.2.0 and `scan-clean.sh` 1.0.0.

## Current capabilities

### `pdf-slim.sh`

- Accepts multiple PDF files, raster images with `--clean-scan`, and directories
  through repeatable `--input`.
- Expands quoted input glob patterns while rejecting accidental unquoted
  multi-match expansion.
- Matches `.pdf` extensions case-insensitively.
- Supports optional recursive directory traversal.
- Handles spaces, tabs, glob characters, and leading hyphens safely.
- Skips symlinks with a warning and never follows them.
- Requires an explicit output mode: `--output FILE`, `--output-dir DIR`, or
  `--replace`.
- Supports a one-off exact PDF output filename for a single PDF or raster-image
  input.
- Preserves paths relative to each supplied directory in output mode.
- Refuses existing output files and collisions between supplied roots.
- Plans operations without running Ghostscript or writing output when using
  `--dry-run`.
- Records successful replacement outcomes and skips only unchanged files with
  matching identity and processing settings.
- Offers gentle, standard, and strong contrast cleanup for safely detected
  image-only scans while retaining their page size, resolution, and color.
- Delegates PDF page pixel cleanup to the companion `scan-clean.sh` engine so
  image and PDF cleanup use the same adaptive behavior.
- Accepts a raster scan directly and creates a cleaned PDF in one command when
  `--clean-scan` is selected.

### `scan-clean.sh`

- Cleans JPEG, PNG, TIFF, and other single-frame raster images directly.
- Offers gentle, standard, and strong cleanup plus `--all-modes` for comparison.
- Supports exact output filenames, automatic collision-safe naming, and
  nonrecursive directory or quoted-glob batches.
- Converts between raster formats based on the output extension, such as PNG to
  JPEG.
- Preserves supported metadata and transparency, with explicit options to strip
  metadata or choose the background used when flattening to JPEG.
- Publishes outputs atomically and refuses symlinks, vector documents,
  animations, and multi-frame images.

## Usage

```text
pdf-slim.sh [options]
```

Input paths are explicit and repeatable. Raster images are accepted when
`--clean-scan` is selected:

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

Quality selection has two mutually exclusive approaches:

```text
Quality -- choose one approach:
  Preset:
    --quality MODE       Use preserve, balanced, or small
                         (default when no quality options are given: preserve)
  Detailed:
    --max-dpi DPI        Downsample color/grayscale images above DPI
                         (default: no color/grayscale DPI cap)
    --jpeg-recompress Q  JPEG-encode color/grayscale images at QFactor Q,
                         0.0-1.0; lower values preserve more quality
                         (default: existing eligible JPEGs pass through)
  --grayscale            Convert colors to grayscale; independent of either
                         quality approach

Do not combine --quality with --max-dpi or --jpeg-recompress.

Scan cleanup:
  --clean-scan MODE      Improve an image-only scan using gentle, standard, or
                         strong contrast cleanup while retaining color
                         (default with no quality options: source DPI and JPEG
                         QFactor 0.10; --grayscale remains independent)
```

Current options:

```text
  --recursive         Descend into supplied directories
  --reprocess         Reprocess files that match the replacement log; all safety
                      checks remain enabled (requires --replace)
  --timeout DURATION  Per-file conversion timeout (default: 1h)
  --dry-run           Print planned actions; run no Ghostscript and write nothing
  --preserve-metadata MODE
                      Preserve none, basic, standard (default), or all metadata
  -h, --help          Show this help and exit
  --version           Show the version and exit
```

PDF scan cleanup uses the executable `scan-clean.sh` beside `pdf-slim.sh`, or
falls back to one available through `PATH`. It also requires ImageMagick and
Poppler. It safely refuses PDFs with detectable text, forms, attachments,
links, vector content, or other layouts that cannot be flattened as image-only
scans without losing content.

## Use cases

Show command help using either conventional spelling:

```bash
pdf-slim.sh -h
pdf-slim.sh --help
```

Process PDFs in the current directory, writing converted copies into `slimmed`:

```bash
pdf-slim.sh --input . --output-dir slimmed
```

Convert one PDF to an exact output filename:

```bash
pdf-slim.sh --input annual-report.pdf --output annual-report-slim.pdf
```

The exact output mode accepts one regular PDF, or one raster image when
`--clean-scan` is selected. Raster input requires a `.pdf` output filename. The
output parent directory must already exist. Exact output refuses directory
inputs, multiple inputs, recursive traversal, symlink destinations, and existing
destinations.

Preview a replacement run without starting Ghostscript or changing anything:

```bash
./pdf-slim.sh --input draft-proposal.pdf --dry-run --replace
```

Create a converted copy while leaving the original untouched:

```bash
./pdf-slim.sh --input scanned-contract.pdf --output-dir ./slimmed
```

Convert several individual PDFs into one output directory:

```bash
./pdf-slim.sh --input invoice.pdf --input handbook.PDF \
  --input "meeting-notes.pdf" --output-dir ./slimmed
```

Select matching inputs with a quoted glob pattern:

```bash
pdf-slim.sh --input '../test/doc*.pdf' --output-dir ./slimmed
```

Quote patterns containing `*`, `?`, or bracket expressions so `pdf-slim`
receives the pattern as one argument. An unquoted pattern that the shell expands
to multiple paths is rejected before conversion or writes, with a hint showing
the quoted form. A path that already exists is treated literally, even when its
filename contains glob metacharacters.

Recursively convert a directory while preserving its internal structure:

```bash
./pdf-slim.sh --input ./documents --output-dir ./slimmed --recursive
```

Replace an original only when the validated conversion is strictly smaller:

```bash
./pdf-slim.sh --input research-paper.pdf --replace
```

Process every PDF beneath an archive. Successfully handled, unchanged files
recorded in `processed_pdfs.log` are skipped on later runs:

```bash
./pdf-slim.sh --input ./archive --replace --recursive
```

Retry files even when their current identity and processing settings match the
replacement history:

```bash
./pdf-slim.sh --input ./archive --replace --reprocess --recursive
```

Preserve permissions and timestamps using the default `standard` policy:

```bash
./pdf-slim.sh --input signed-agreement.pdf --replace \
  --preserve-metadata standard
```

On macOS, also require ownership, file flags, ACLs, and extended attributes such
as Finder tags to be preserved:

```bash
./pdf-slim.sh --input tagged-document.pdf --replace --preserve-metadata all
```

Create output without copying source metadata, letting the new file retain its
naturally created metadata:

```bash
./pdf-slim.sh --input archived-statement.pdf --output-dir ./slimmed \
  --preserve-metadata none
```

Explicitly create a grayscale PDF:

```bash
./pdf-slim.sh --input color-brochure.pdf --output-dir ./grayscale --grayscale
```

Clean an image-only scan while preserving its page size, source DPI, and color.
With no quality options, cleanup uses the high-quality JPEG default
`QFactor 0.10` because changed pixels cannot reuse the original JPEG encoding:

```bash
pdf-slim.sh --input employment-form-scan.pdf \
  --output employment-form-cleaned.pdf --clean-scan standard
```

The selected cleanup strength is passed directly to `scan-clean.sh`. PDF pages
are rendered to temporary lossless PNG images, cleaned by the shared engine,
and reassembled before the existing PDF quality and optional grayscale stages.

Clean a JPG and create a PDF in one command:

```bash
pdf-slim.sh --input phone-scan.jpg --output phone-scan-cleaned.pdf \
  --clean-scan standard
```

Raster-image input requires `--clean-scan`. Exact output must have a `.pdf`
extension, and `--replace` is refused because replacing an image with a PDF
would change its file type. In output-directory mode, image extensions are
changed to `.pdf`, while directory structure is preserved:

```bash
pdf-slim.sh --input ./incoming-scans --output-dir ./cleaned-pdfs \
  --clean-scan standard
```

For PDF page sizing, recorded image density of at least 150 DPI is preserved.
Missing or lower density—common for phone photos—is treated as 300 DPI. This
sets physical PDF page dimensions without adding, removing, or resampling
pixels; the selected PDF quality policy may downsample afterward.

Compare all three cleanup strengths:

```bash
for mode in gentle standard strong; do
  pdf-slim.sh --input employment-form-scan.pdf \
    --output "employment-form-$mode.pdf" --clean-scan "$mode"
done
```

Cleanup remains independent of grayscale and the two quality-selection
approaches. For example, clean, convert to grayscale, cap resolution, and select
an explicit JPEG encoding:

```bash
pdf-slim.sh --input archived-form-scan.pdf \
  --output archived-form-cleaned.pdf --clean-scan standard --grayscale \
  --max-dpi 200 --jpeg-recompress 0.15
```

Explicit `--quality preserve` requests lossless encoding after cleanup. It does
not downsample, but its output can be considerably larger than the practical
default above:

```bash
pdf-slim.sh --input archival-scan.pdf --output archival-cleaned-lossless.pdf \
  --clean-scan gentle --quality preserve
```

Set a shorter per-file conversion limit for a batch:

```bash
./pdf-slim.sh --input ./incoming --replace --recursive --timeout 10m
```

Input and output paths beginning with a hyphen are consumed explicitly as
option values:

```bash
./pdf-slim.sh --input -leading-hyphen.pdf --output -slimmed.pdf
```

Exit statuses are `0` for success, `1` when one or more conversions fail, and
`2` for invalid or unsafe requests.

## Standalone image cleanup

Use `scan-clean.sh` for image-to-image cleanup. Use `pdf-slim.sh` when the
desired output is PDF, whether the input is a PDF or raster image:

```text
scan-clean.sh -i PATH [output options] [cleanup options]
```

`--input` accepts exactly one image, quoted basic glob, or nonrecursive
directory. With one selected image and no output option, the default `standard`
mode creates `NAME-standard.EXT` beside the source:

```bash
scan-clean.sh --input phone-photo.jpg
```

Choose a cleanup strength explicitly and an exact output filename:

```bash
scan-clean.sh --input phone-photo.jpg --mode gentle \
  --output phone-photo-cleaned.jpg
```

Generate all three strengths for visual comparison:

```bash
scan-clean.sh --input phone-photo.jpg --all-modes
```

This creates `phone-photo-gentle.jpg`, `phone-photo-standard.jpg`, and
`phone-photo-strong.jpg`. If any name is unavailable, all three use the same
next group index—for example `phone-photo-2-gentle.jpg` through
`phone-photo-2-strong.jpg`—so the variants stay together when sorted.

The exact output extension selects the output format, including PNG-to-JPEG:

```bash
scan-clean.sh --input form-scan.png --output form-scan-cleaned.jpg \
  --jpeg-quality 95 --background white
```

Alpha is preserved when the output format supports transparency. JPEG cannot,
so transparent pixels are flattened onto `--background` (`white` by default).

Clean all supported images immediately inside a directory, without descending
into subdirectories:

```bash
scan-clean.sh --input ./incoming-scans --output-dir ./cleaned
```

Or use one quoted glob:

```bash
scan-clean.sh --input './incoming-scans/*.jpg' --output-dir ./cleaned
```

Multiple selected images require `--output-dir`. The exact directory supplied,
including missing parent directories, is created; no extra nesting is added.
Broad directory and glob selections skip non-images with warnings. Explicit
unsupported inputs fail. Symlinks, vector/document formats, animations, and
multi-frame images are never processed.

Existing outputs receive an automatic numeric index unless overwrite is
explicitly requested:

```bash
scan-clean.sh --input phone-photo.jpg --overwrite
```

`-O` is the short form of `--overwrite`; replacement is atomic. Preview planned
names without writing outputs:

```bash
scan-clean.sh --input phone-photo.jpg --all-modes --dry-run
```

Image metadata is preserved when the output format supports it, including ICC,
EXIF, capture date, GPS, and resolution. Orientation is applied to the pixels
and normalized. Use `--strip-metadata` to remove metadata instead. The default
JPEG output quality is 95 and the per-image command timeout is 1 hour.

## Safety model

`--replace` replaces an original only after a successful, validated conversion
is strictly smaller. It never removes the original first. Exact-file and
output-directory modes never silently overwrite a destination or publish a
partial conversion.

Scan cleanup intentionally rebuilds pixels, so it first verifies that every
page is an image-only scan. It refuses encrypted PDFs and detectable searchable
text, forms, JavaScript, attachments, links, named destinations, visible vector
content, or pages that do not contain exactly one ordinary image. A rejected
file is left untouched; other files in a batch continue, and the command exits
with status `1`. Cleanup temporary files are removed on success, failure,
timeout, or interruption.

`--dry-run` reports the intended cleanup but defers content inspection until a
real run so it can remain write-free and avoid Ghostscript. In `--replace` mode,
the existing strictly-smaller rule still applies: if the cleaned PDF is not
smaller, the original is retained and the candidate is discarded.

Metadata preservation is strict: if the selected metadata cannot be preserved,
the candidate is discarded and the original remains untouched. `standard`
preserves permissions plus access and modification timestamps. On macOS, `all`
also preserves and verifies ownership, file flags, ACLs, and extended attributes
such as Finder tags.

For replacement runs, `pdf-slim.sh` creates or reuses private processing
history at:

```text
macOS:  ~/Library/Application Support/pdf-slim/processed_pdfs.log
Linux:  ${XDG_STATE_HOME:-$HOME/.local/state}/pdf-slim/processed_pdfs.log
```

Set `PDF_SLIM_STATE_DIR` to an absolute directory to override that location.
The directory uses mode `700` and the log uses mode `600`.

The version-2 null-delimited log records canonical path, current byte size,
modification time, resolved processing signature, outcome, processing time,
and an optional related artifact. An unchanged file is skipped only when its
processing signature also matches; quality, detailed image settings,
grayscale, scan cleanup, and metadata policy therefore remain independent
replacement attempts. The history is loaded once for each batch.

Processing history created by earlier versions is migrated automatically. A
failed, timed-out, interrupted, or invalid conversion never adds a record.
`--reprocess` bypasses matching records without erasing history or disabling
safety checks.

## Quality policies

- `preserve` keeps source image resolution and uses lossless Flate image
  encoding. It may produce a file that is not smaller; `--replace` retains the
  original in that case.
- `balanced` never upscales, caps images above 300 DPI using bicubic
  downsampling, and uses `QFactor 0.15` when JPEG encoding is required. Eligible
  existing JPEGs pass through unchanged.
- `small` never upscales, caps images above 250 DPI using bicubic downsampling,
  and uses `QFactor 0.4` when JPEG encoding is required. Eligible existing JPEGs
  pass through unchanged.

Detailed controls define a custom quality policy:

- `--max-dpi DPI` caps color and grayscale images at a positive integer DPI.
  Omitting it leaves their resolution uncapped. Monochrome line art retains the
  existing 600-DPI cap.
- `--jpeg-recompress Q` forces color and grayscale images through JPEG encoding,
  including existing JPEGs below the DPI cap. `Q` is Ghostscript's QFactor from
  `0.0` to `1.0`; lower values preserve more quality and usually produce larger
  files.
- Without `--jpeg-recompress`, eligible existing JPEGs pass through. Any image
  that must be JPEG-encoded uses the detailed-mode default `QFactor 0.15`.

The quality approaches behave as follows:

| Arguments | Effective behavior |
| --- | --- |
| No quality arguments | Implicit `preserve` preset |
| `--quality MODE` | Named preset |
| `--max-dpi DPI` | Detailed mode with a DPI cap |
| `--jpeg-recompress Q` | Detailed recompression without a color/grayscale DPI cap |
| Both detailed options | Detailed control of recompression and DPI |
| Preset plus either detailed option | Invalid; choose one approach |

Combining preset and detailed controls fails with an explanation:

```text
pdf-slim.sh: error: choose one quality approach: use --quality MODE or detailed options (--max-dpi and --jpeg-recompress), not both
```

`--grayscale` is independent and can be combined with either approach.
JPEG recompression and downsampling are lossy and do not guarantee a smaller
result.

`--clean-scan` is also independent of the quality approach. With no quality
arguments, it retains source page dimensions and resolution and uses
`QFactor 0.10`. An explicit named preset uses that preset instead. Detailed
values override the corresponding cleanup defaults; supplying only `--max-dpi`
keeps the cleanup default `QFactor 0.10`.

Recompress without changing color/grayscale resolution:

```bash
pdf-slim.sh --input original.pdf --output q015.pdf \
  --jpeg-recompress 0.15
```

Downsample only images above 275 DPI:

```bash
pdf-slim.sh --input original.pdf --output 275dpi.pdf --max-dpi 275
```

Control both dimensions:

```bash
pdf-slim.sh --input original.pdf --output q020-275dpi.pdf \
  --jpeg-recompress 0.20 --max-dpi 275
```

Generate several closely spaced recompression candidates for comparison:

```bash
for q in 0.10 0.15 0.20 0.25 0.30; do
  pdf-slim.sh --input original.pdf --output "qfactor-$q.pdf" \
    --jpeg-recompress "$q"
done
```

## Requirements

Both commands use Bash, GNU `timeout` (available as `timeout` or `gtimeout`),
`find`, and `realpath`. `scan-clean.sh` requires ImageMagick (`magick`).
`pdf-slim.sh` requires Ghostscript. Its `--clean-scan` feature also requires the
companion `scan-clean.sh` and ImageMagick. Cleaning PDF input additionally uses
Poppler (`pdfinfo`, `pdfimages`, `pdftotext`, `pdfdetach`, and `pdftocairo`);
direct raster-image to PDF cleanup does not. `pdf-slim.sh` prefers an executable
`scan-clean.sh` beside itself, then searches `PATH`. Optional commands are
checked only when their features are requested. The scripts are tested with
macOS Bash 3.2 and newer Bash versions. The `all` PDF metadata mode additionally
uses macOS `xattr`.

## Installation

Make the script executable and add its directory to `PATH`, or invoke it by its
path:

```bash
chmod +x pdf-slim.sh scan-clean.sh
export PATH="/path/to/pdf-slim:$PATH"
pdf-slim.sh --version
scan-clean.sh --version
```

For a persistent installation, add the `export PATH=...` line to the profile
file used by your shell.

## Testing

Run the complete automated suite with:

```bash
./tests/run.sh
```

The suite uses disposable files plus Ghostscript and ImageMagick command doubles
to cover CLI validation and traversal, conversion failures and timeouts, atomic
publication, metadata preservation, interruption cleanup, and replacement
logging. It runs on macOS Bash 3.2 and newer Bash versions. Cleanup tests cover
all three strengths, PDF page-size preservation, standalone batch filtering,
automatic naming, transparency, metadata behavior, and safe input refusal.
Image-to-PDF coverage includes physical page density, detailed quality and
grayscale, batch extension mapping, recursive layout, collisions, animated
input refusal, and protection against image replacement.

## Project layout

```text
pdf-slim.sh                 Active command
scan-clean.sh               Standalone raster-image cleanup command
README.md                   User documentation
INSTRUCTIONS.md             Development handoff and implementation plan
tests/                       Automated conversion, publication, logging, and CLI tests
.gitignore                   Generated-file exclusions
```

## Release status

`pdf-slim.sh` version 1.2.0 delegates guarded PDF scan pixel cleanup to the
companion `scan-clean.sh` engine while retaining PDF-specific inspection,
metadata, quality, publication, replacement, and logging safeguards.
It also accepts raster scans directly and creates cleaned PDFs through the same
engine and PDF quality pipeline.
`scan-clean.sh` version 1.0.0 applies the shared adaptive cleanup directly to
single-frame raster images with safe standalone and batch publication. Future
changes should remain backward-compatible or be released as a new major
version.
