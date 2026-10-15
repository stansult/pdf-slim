# `pdf-slim.sh` examples

These examples supplement the short quick start in the main README. Exactly one
output mode is required for every invocation.

## Output modes

Convert one PDF to an exact output filename:

```bash
pdf-slim.sh --input annual-report.pdf --output annual-report-slim.pdf
```

Exact output accepts one regular PDF, or one raster image with `--clean-scan`.
It refuses directory or multiple inputs, recursive traversal, existing or
symlink destinations, and missing output-parent directories. Raster input
requires a `.pdf` output filename.

Convert several files into one output directory:

```bash
pdf-slim.sh --input invoice.pdf --input handbook.PDF \
  --input "meeting-notes.pdf" --output-dir ./slimmed
```

Recursively convert a directory while preserving its internal structure:

```bash
pdf-slim.sh --input ./documents --output-dir ./slimmed --recursive
```

Replace an original only when the validated conversion is strictly smaller:

```bash
pdf-slim.sh --input research-paper.pdf --replace
```

Process an archive and skip unchanged files already recorded with the same
processing policy:

```bash
pdf-slim.sh --input ./archive --replace --recursive
```

Retry matching replacement-history entries without erasing history or
disabling safety checks:

```bash
pdf-slim.sh --input ./archive --replace --reprocess --recursive
```

Preview a run without launching Ghostscript or writing output:

```bash
pdf-slim.sh --input draft-proposal.pdf --dry-run --replace
```

## Input selection

Use a quoted glob so `pdf-slim.sh` receives the pattern as one argument:

```bash
pdf-slim.sh --input '../test/doc*.pdf' --output-dir ./slimmed
```

An unquoted pattern that expands to multiple shell arguments is rejected. An
existing literal filename containing glob characters is treated literally.

Input and output paths beginning with a hyphen are consumed as explicit option
values:

```bash
pdf-slim.sh --input -leading-hyphen.pdf --output -slimmed.pdf
```

## Metadata

The default `standard` policy preserves permissions and access/modification
timestamps:

```bash
pdf-slim.sh --input signed-agreement.pdf --replace \
  --preserve-metadata standard
```

On macOS, request strict preservation of ownership, file flags, ACLs, and
extended attributes such as Finder tags:

```bash
pdf-slim.sh --input tagged-document.pdf --replace --preserve-metadata all
```

Create output without copying source metadata:

```bash
pdf-slim.sh --input archived-statement.pdf --output-dir ./slimmed \
  --preserve-metadata none
```

## Scan cleanup

Clean an image-only PDF scan with the default `standard` strength:

```bash
pdf-slim.sh --input employment-form-scan.pdf \
  --output employment-form-cleaned.pdf --clean-scan
```

Clean a raster image and create a PDF:

```bash
pdf-slim.sh --input phone-scan.jpg --output phone-scan-cleaned.pdf \
  --clean-scan standard
```

In output-directory mode, raster-image extensions become `.pdf` while relative
directory structure is preserved:

```bash
pdf-slim.sh --input ./incoming-scans --output-dir ./cleaned-pdfs \
  --clean-scan standard
```

Compare all three PDF cleanup strengths:

```bash
for mode in gentle standard strong; do
  pdf-slim.sh --input employment-form-scan.pdf \
    --output "employment-form-$mode.pdf" --clean-scan "$mode"
done
```

Clean several PDF pages concurrently:

```bash
pdf-slim.sh --input monthly-statements.pdf \
  --output monthly-statements-cleaned.pdf --clean-scan --jobs 5
```

`--jobs 1` forces serial page cleanup. See the
[scan-clean concurrency record](scan-clean-concurrency.md)
for measured tradeoffs.

## Quality combinations

Create an explicitly grayscale PDF:

```bash
pdf-slim.sh --input color-brochure.pdf --output-dir ./grayscale --grayscale
```

Clean, convert to grayscale, cap resolution, and choose JPEG encoding:

```bash
pdf-slim.sh --input archived-form-scan.pdf \
  --output archived-form-cleaned.pdf --clean-scan standard --grayscale \
  --max-dpi 200 --jpeg-recompress 0.15
```

Request lossless PDF encoding after cleanup:

```bash
pdf-slim.sh --input archival-scan.pdf --output archival-cleaned-lossless.pdf \
  --clean-scan gentle --quality preserve
```

Set a shorter conversion limit for a batch:

```bash
pdf-slim.sh --input ./incoming --replace --recursive --timeout 10m
```

See [Quality policies](quality.md) for detailed controls and additional
comparison examples.
