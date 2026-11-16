# Safety and replacement history

Both commands treat source preservation as the primary invariant. This page
documents details behind the concise safety summary in the main README.

## Publication and replacement

`pdf-slim.sh --replace` replaces an original only after conversion succeeds,
the candidate is a validated nonempty PDF, source bytes remain unchanged, and
the candidate is strictly smaller. It never removes the original first.

Exact-file and output-directory modes publish atomically and never silently
overwrite a destination. They recheck destinations immediately before
publication to catch files created during conversion. Temporary candidates are
removed after success, failure, timeout, or interruption.

`scan-clean.sh` follows the same source checks and atomic-publication rules.
Image overwrite requires explicit `-O` / `--overwrite`.

## Ghostscript recovery warnings

Ghostscript can exit successfully and produce a nonempty PDF while reporting
that errors in the input were repaired or ignored. `pdf-slim.sh` treats that
specific diagnostic as requiring manual review rather than as an ordinary
success. Other Ghostscript warnings do not trigger this policy.

With `--replace`, the original remains untouched. The converted candidate is
published atomically beside it as `NAME-recovered.pdf`; if that name exists,
the command chooses `NAME-recovered-2.pdf`, then the next available number,
without overwriting any existing file.

With exact-file or output-directory mode, the source is already separate from
the requested destination, so the candidate is published there. The command
reports that the output carries a recovery warning.

Both cases return status `1`, include the file in batch failure summaries, and
show Ghostscript's complete diagnostic for review. A recovered candidate is
not recorded as a successful replacement-history outcome.

## Concurrent source activity

Both commands inspect the source again after conversion. Changes to device,
inode, size, or modification time stop publication. A `ctime`-only change can
result from Dropbox File Provider or other filesystem metadata activity, so it
is accepted only when SHA-256 proves that source bytes are unchanged. Real
content changes remain failures even if file size and modification time were
preserved.

## Scan-cleanup eligibility

PDF scan cleanup intentionally rebuilds pixels. Before flattening, it refuses:

- encrypted PDFs;
- forms or JavaScript;
- attachments, links, or named destinations;
- pages without exactly one primary image.

One grayscale, single-component soft mask is accepted only when its PDF object,
generation, pixel dimensions, and X/Y resolution match the primary image.
Independent, multiple, or mismatched masks remain unsafe.

A rejected source is untouched. Other files in a batch continue, and the
command returns status `1` when any conversion fails. Dry-run reports planned
cleanup but defers destructive-flattening inspection so it remains write-free
and does not launch Ghostscript.

When a PDF otherwise qualifies for scan cleanup but contains detectable
searchable text or visible vector content, an interactive run asks whether to:

- clean and rasterize the pages, removing searchable/vector content;
- preserve that content by continuing without scan cleanup while applying all
  other selected options; or
- quit immediately, leaving the current file untouched. If earlier batch
  outputs were already saved, the Quit choice says that they remain saved.

The default choice is Quit. A run without an interactive terminal fails safely
instead of choosing on the user's behalf. Quitting returns status `2`; it does
not roll back outputs that were successfully published earlier in the batch.
The Preserve choice keeps the resolved PDF quality, grayscale, and metadata
settings. With no explicit quality option, the scan-clean default remains
source resolution with JPEG `QFactor 0.10`.
With `--replace`, choosing Clean permits the smaller validated rasterized
result to replace the searchable original under the normal replacement checks.

## Metadata policies

Metadata preservation is strict: if selected metadata cannot be preserved, the
candidate is discarded. Policies are:

- `none`: copy no source metadata.
- `basic`: preserve permissions.
- `standard` (default): preserve permissions and access/modification times.
- `all` (macOS): also preserve and verify ownership, file flags, ACLs, and
  extended attributes such as Finder tags.

## Replacement history

Replacement runs create or reuse private processing history at:

```text
macOS:  ~/Library/Application Support/pdf-slim/processed_pdfs.log
Linux:  ${XDG_STATE_HOME:-$HOME/.local/state}/pdf-slim/processed_pdfs.log
```

`PDF_SLIM_STATE_DIR` accepts an absolute override. The state directory uses
mode `700`; the log uses mode `600`.

PDF scan-clean performance records use `performance.tsv` in the same private
state directory. They contain workload, concurrency, timing, machine-capacity,
size, and outcome fields, but no paths, filenames, hashes, extracted text, or
document content. The metrics file uses mode `600`. Recording failure produces
at most one warning per invocation and never changes conversion or publication
results.

The version-2 null-delimited log records canonical path, byte size,
modification time, resolved processing signature, outcome, processing time, and
an optional related artifact. An unchanged file is skipped only when its
processing signature also matches, so quality, detailed image settings,
grayscale, scan cleanup, and metadata policy remain independent attempts.

Only terminal successful outcomes are recorded: replacement, or a valid
candidate rejected because it was not smaller. Failures, timeouts,
interruptions, and invalid outputs never add records. `--reprocess` bypasses
matching history without erasing it or disabling safety checks. Earlier log
formats are migrated automatically.
