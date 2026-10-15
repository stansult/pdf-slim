# PDF scan-cleanup concurrency

This page is the authoritative design and evidence record for concurrent PDF
page cleanup in `pdf-slim.sh`. It documents implemented worker safety, measured
performance, the automatic policy, and the anonymous metrics needed to
improve that policy after broader real-world use.

## Scope and current status

PDF scan cleanup renders and cleans independent pages before reassembling them
in original order. Version 1.4.0 selects workers automatically using:

```text
effective workers = min(PDF page count, 5)
```

An explicit `--jobs N`, accepting values from 1 through 11, overrides the
automatic value; `--jobs 1` forces serial cleanup. Version 1.4.0 also records
the performance metrics documented below.

## Implemented worker behavior and safety

- Only page rendering and delegated `scan-clean.sh` processing run concurrently.
- Each worker has isolated rendered, cleaned, diagnostic, and command-output
  paths inside the conversion's private temporary directory.
- Final page-geometry inspection and PDF assembly remain ordered.
- Assembly begins only after every page succeeds.
- One failed or timed-out page suppresses assembly and publication.
- A failure stops new page launches while already active workers are drained.
- Interruption terminates active worker commands before removing temporary
  files.
- Worker diagnostics are captured separately and replayed as intact blocks to
  prevent partial-line interleaving.
- The outer loop over separate input PDFs remains serial. Concurrency is within
  one PDF only.
- Worker count affects execution only. It does not alter the processing-policy
  signature used by replacement history.

Automated coverage is described in [`tests/README.md`](../tests/README.md),
primarily under `test-scan-parallel.sh`.

## Concurrency benchmark — 2026-10-14/15

### Purpose

Measure whether concurrent page rendering and cleanup reduces elapsed time
without changing resulting PDF pages, and identify where additional workers
stop providing useful returns.

### Environment and fixture

- macOS computer with 6 physical and 12 logical CPUs and 16 GiB RAM.
- One anonymized 11-page, image-only PDF; source size 8,672,773 bytes.
- Ten pages contained 2164 × 1699 RGB JPEG images at 200 DPI.
- One page contained a 3245 × 2547 RGB JPEG image at 300 DPI.
- Cleanup used `--clean-scan strong --quality balanced` with metadata
  preservation disabled to exclude metadata work from the comparison.
- The same SHA-256-verified local source copy was used for every run.
- The candidate worktree was based on commit
  `c51c273a731313cd0b91356cd67214c753ddc317`. The measured explicit-concurrency
  implementation was subsequently retained in commit
  `ebcfdfee14a84887c5ecde70ae9a82e9b3b1daf4`.

### Method

The candidate ran twice at every worker count from 1 through 11. Round one used
ascending order; round two used descending order to reduce warm-cache,
ordering, and temperature bias. Runs were sequential and never overlapped.

Each sweep run used the equivalent of:

```bash
pdf-slim.sh --input source.pdf --output result.pdf \
  --clean-scan strong --quality balanced --preserve-metadata none --jobs N
```

Wall-clock, user CPU, system CPU, and sampled resident memory for the complete
conversion process tree were recorded. Time values below are the mean of two
runs. Peak RSS is the larger sampled value from either run; process-tree RSS
was sampled approximately every 0.25 seconds.

Before the full sweep, a separate two-run comparison measured the baseline
commit at 93.60s, the candidate with one worker at 91.55s, and the candidate
with two workers at 64.95s. That preliminary check found identical extracted
page images and no material serial-refactor penalty.

### Results

| Workers | Average wall time | User CPU | System CPU | Speedup vs. 1 | Peak process-tree RSS (MiB) |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 99.33s | 90.91s | 4.90s | — | 567 |
| 2 | 57.49s | 88.93s | 4.58s | 42.1% | 569 |
| 3 | 51.01s | 92.33s | 4.70s | 48.6% | 569 |
| 4 | 45.41s | 91.43s | 4.64s | 54.3% | 569 |
| 5 | 40.45s | 94.03s | 4.89s | 59.3% | 569 |
| 6 | 43.48s | 96.08s | 4.80s | 56.2% | 569 |
| 7 | 41.34s | 101.12s | 5.32s | 58.4% | 602 |
| 8 | 42.01s | 107.12s | 5.55s | 57.7% | 702 |
| 9 | 40.21s | 111.23s | 5.56s | 59.5% | 812 |
| 10 | 35.33s | 115.88s | 5.61s | 64.4% | 911 |
| 11 | 34.59s | 119.54s | 5.68s | 65.2% | 915 |

Five workers captured approximately 91% of the maximum observed wall-time
savings while retaining the same sampled peak memory as the serial run. Ten and
eleven workers were fastest, but used more CPU time and roughly 60% more sampled
peak memory than five workers.

### Output verification

All 22 outputs:

- completed successfully and passed Ghostscript PDF parsing;
- had the same 11-page count, order, and page geometry;
- had one common file size; and
- produced identical manifests of SHA-256 hashes for every image extracted by
  `pdfimages -all`.

Whole-PDF hashes were intentionally not used as image-equivalence evidence
because independently generated PDF containers can include run-specific data.

### Interpretation and limitations

The experiment establishes that serial cleanup leaves substantial capacity
unused for this workload. Two workers produced a large low-resource gain. Five
workers were the strongest balanced point, while ten or eleven prioritized
minimum elapsed time.

Five is not a universal optimum. This experiment covers one document on one
computer. Results can change with page count, pixel dimensions, page-cost
imbalance, available memory, CPU topology, storage, other system load, and
internal threading by Poppler or ImageMagick. RSS sampling can also miss brief
memory spikes.

The initial automatic cap of five therefore favors a simple, explainable
starting policy rather than claiming an optimal value. Real-world metrics will
be used to evaluate whether page characteristics or machine capacity justify a
different rule.

## Anonymous performance metrics

One record is written after every processed PDF scan-cleanup attempt, including
failures and attempts inside a larger batch. Ordinary PDF conversion and
single-raster-image input are excluded because they do not use PDF page-worker
concurrency. Records contain no path, filename, content hash, extracted text,
or document content.

### Human-readable completion line

A concise summary is shown only with `--verbose`, for example:

```text
metrics: success pages=11 workers=5(auto) pixels=44.9MP page-time=8/10/13s cleanup=31s total=40s output=6.5MiB
```

Failed attempts show their failure stage and whichever measurements are
available. Normal non-verbose output remains unchanged. Each summary is one
logical timestamped output block.

### Persistent record

The full machine-readable record uses one tab-separated line per attempted PDF
in a versioned private file:

```text
macOS:  ~/Library/Application Support/pdf-slim/performance.tsv
Linux:  ${XDG_STATE_HOME:-$HOME/.local/state}/pdf-slim/performance.tsv
```

`PDF_SLIM_STATE_DIR` overrides the parent state directory consistently with
replacement history. The existing state directory uses mode `700`; the metrics
file uses mode `600`. Creation and append operations use an independent
directory lock. A malformed or unknown header is never overwritten or
appended. Recording failure emits at most one warning per invocation and never
affects conversion safety, publication, or exit status.

### Version 1 fields

Identity and outcome:

- metrics schema version and recording timestamp;
- `pdf-slim.sh` version and operating system;
- success/failure outcome and failure stage;
- cleanup mode and resolved PDF quality policy;
- source and output byte sizes.

Workload shape:

- page count;
- total page-image pixels;
- minimum, median, and maximum page-image pixels;
- color and grayscale page counts.

Concurrency:

- automatic or explicit selection;
- requested value when explicit;
- effective worker count;
- maximum simultaneously active workers;
- detected logical and physical CPU counts when available;
- installed memory when available.

Timing uses Bash's integer-second `SECONDS` counter, avoiding another runtime
dependency. Unavailable TSV fields contain `-`; unavailable values are omitted
from verbose summaries.

Timing fields:

- total elapsed time;
- PDF inspection time;
- concurrent render-and-clean phase time;
- sum of individual page times;
- minimum, median, and maximum page time;
- ordered page-time values for later scheduling simulation;
- PDF assembly time; and
- final Ghostscript optimization time.

Derived values such as size ratio, pixel throughput, concurrency efficiency,
and page-batch shape can be calculated during later analysis instead of being
duplicated in every record.

## What accumulated metrics can answer

The records can show:

- whether page count or pixel volume better predicts elapsed time;
- whether five workers are regularly underutilized;
- whether one unusually slow page dominates completion;
- when assembly or final Ghostscript optimization becomes the bottleneck;
- whether high-resolution workloads need a lower concurrency cap; and
- whether different machine classes need different policies.

If every automatic run always selects the same cap, observational data cannot
prove that a neighboring worker count would have been faster for the identical
document. Explicit `--jobs` runs provide useful natural variation. Ordered
per-page timings can approximately simulate schedules with fewer workers, but
cannot reliably predict contention at higher concurrency.

Any future automatic exploration of neighboring worker counts must be an
explicitly approved, opt-in tuning feature. Ordinary runs must remain
predictable and must not silently vary worker count for experimentation.

Metrics collection has no disable option and the file is not initially rotated.
The full retained history is useful for analysis; rotation or an opt-out can be
reconsidered only if a concrete need appears.
