# pdf-slim project handoff

## Objective

Maintain one reliable, configurable Bash command for reducing PDF file sizes
with Ghostscript. The default quality policy must prioritize preserving the
visible appearance of the source PDF. More aggressive, lossy compression must
be available only through explicit options.

The active project and primary command are named **pdf-slim**. The companion
`scan-clean.sh` command owns standalone raster-image cleanup. The former
`pdf_low` scripts have been retired and removed from the repository.

## Project location and access requirement

The project root is:

```text
/Users/stansult/dev/pdf-slim
```

Direct patch-based access to this directory was verified. The temporary
compatibility symlink at `/Users/stansult/dev/pdf_low` was resolved, checked, and
removed without affecting the project.

## Repository state

This is a standalone Git repository with a public GitHub remote:

```text
origin  https://github.com/stansult/pdf-slim.git
```

Repository page:

```text
https://github.com/stansult/pdf-slim
```

The current branch is `master`, tracking `origin/master`. The standalone
`scan-clean.sh` command was committed first; the `pdf-slim.sh` 1.2.0 integration,
raster-image-to-PDF path, tests, and documentation followed as a separate
logical phase. Policy-aware replacement history and retirement of the legacy
scripts were subsequently committed and pushed.

The implementation was developed through small logical commits. Do not rewrite
this history.

## Current files

```text
pdf-slim.sh                    Active functional consolidated script
scan-clean.sh                  Standalone raster-image scan cleanup command
README.md                      User documentation
INSTRUCTIONS.md                This handoff
.gitignore                     Runtime/temp exclusions
tests/                         Automated suite and command doubles
```

`pdf-slim.sh` 1.2.0 implements safe traversal, dry-run planning, reliable
Ghostscript conversion, atomic output publication, strictly-smaller replacement,
metadata preservation, policy-aware versioned replacement history in the user
state directory, guarded image-only scan cleanup, and timestamped operational
output.

`scan-clean.sh` 1.0.0 implements adaptive gentle, standard,
and strong cleanup for single-frame raster images. It accepts one image, quoted
glob, or nonrecursive directory; supports exact, automatic, and output-directory
publication; preserves image metadata and transparency where supported; and
provides atomic overwrite only through explicit `-O` / `--overwrite`.

## Standalone image-cleanup decisions

The user explicitly approved these choices for `scan-clean.sh`:

1. Accept exactly one `-i PATH` / `--input PATH`; it may select one raster
   image, one quoted basic glob, or one nonrecursive directory. Do not support
   repeatable inputs or recursive traversal.
2. Default to `standard` cleanup when no mode is supplied. Accept
   `--mode gentle|standard|strong` and the explicit comparison option
   `--all-modes`.
3. Support `-o FILE` / `--output FILE` for exactly one selected image and
   `--output-dir DIR` for batches. Do not support in-place replacement.
4. When no output is named for one image, create `NAME-MODE.EXT` beside the
   source. On collision, put a shared numeric group before the mode, such as
   `NAME-2-GENTLE.EXT` through `NAME-2-STRONG.EXT`.
5. Use `-O` / `--overwrite` for explicit atomic overwriting. Without it,
   preserve existing outputs and select the next automatic group index.
6. Let an exact output extension select the raster output format. Preserve the
   source format/extension for automatic and output-directory naming.
7. Preserve supported image metadata by default; offer `--strip-metadata`.
   Auto-orient pixels and normalize the orientation tag.
8. Preserve transparency in formats that support it. For JPEG, flatten onto
   white by default and allow `--background COLOR`.
9. Use JPEG quality 95 by default and expose `--jpeg-quality 1-100`.
10. Create exactly the requested output-directory path, including missing
    parents, while refusing symlink or non-directory components. Add no extra
    nesting.
11. Broad directory/glob discovery filters by actual readable raster content,
    warns and skips non-images, and refuses symlinks, vector/document formats,
    animations, and multi-frame inputs. An explicitly named invalid input is an
    error.
12. Keep the timeout default in an easy-to-find `DEFAULT_TIMEOUT` constant,
    expose `--timeout`, support `--dry-run`, preflight the batch, publish each
    output atomically, continue after per-image failures, and return status 1 if
    any conversion fails.

The standalone engine was committed first. The subsequent PDF integration keeps
the public `--clean-scan gentle|standard|strong` interface and all PDF-specific
inspection, rendering, assembly, metadata, quality, grayscale, publication,
replacement, and logging behavior. Each rendered lossless PNG page is passed to
`scan-clean.sh` with the selected mode, the PDF timeout, an exact PNG output,
and `--strip-metadata`; final PDF metadata remains the responsibility of
`pdf-slim.sh`.

`pdf-slim.sh` locates the cleanup engine by preferring an executable
`scan-clean.sh` beside itself and then searching `PATH`. A missing engine is an
error only when `--clean-scan` is requested. There is no PDF `--all-modes`;
PDF cleanup continues to produce one PDF for one selected cleanup strength.

Version 1.2.0 also accepts supported raster-image input when `--clean-scan` is
selected. Exact output must be named `.pdf`; output-directory mode changes the
image extension to `.pdf` and preserves relative structure. Image input with
`--replace` is always refused. The image is cleaned to a lossless temporary PNG,
assembled into a temporary PDF, and then processed by the existing PDF quality
and optional grayscale pipeline. Recorded density at or above 150 DPI determines
physical page size; missing or lower density uses 300 DPI without resampling
pixels.

## Retired legacy files and completed history migration

The two `pdf_low` scripts were reviewed for behavior not yet represented in the
active command, then removed in commit `5bbe910`. The repository no longer has
a `legacy/` directory. Do not recreate or extend the retired scripts.

The old path-only processing history was migrated into the private version-2
history after checking existing paths, high-confidence relocations, folder
relationships, duplicate filenames, and user-reviewed mismatches. The archived
legacy log and temporary review lists were then removed. At migration
completion, the active history contained 3,731 validated records.

The live history is not a content cache. It records processing attempts against
specific file identities. A legacy path may be associated with one current path
only when relocation evidence is strong; identical bytes alone do not justify
creating history for every copy.

## Environment last observed

```text
Ghostscript:        10.07.1 at /usr/local/bin/gs
GNU timeout:        9.11 at /usr/local/bin/timeout
GNU gtimeout:       /usr/local/bin/gtimeout
realpath:           /bin/realpath
grealpath:          /usr/local/bin/grealpath
greadlink:          /usr/local/bin/greadlink
ImageMagick:        /usr/local/bin/magick
Poppler:            pdfinfo, pdfimages, pdftotext, pdfdetach, pdftocairo
shellcheck:         installed
```

Do not install dependencies without user approval. Recheck these commands in
the new thread because environment state can change.

## Agreed interface and behavior

The canonical command is:

```bash
pdf-slim.sh [options]
```

The user has approved these decisions:

1. Require exactly one of `--output FILE`, `--output-dir DIR`, or `--replace`.
   There is no implicit destructive action and no implicit default output
   directory.
2. All three output modes are mutually exclusive.
3. Match PDF extensions case-insensitively, including `.PDF`.
4. Skip symlinks with a clear warning; do not follow them.
5. Preserve relative directory structure beneath `--output-dir`.
6. Never overwrite an existing output destination silently.
7. Keep processed-file logging limited to `--replace` initially.
8. Preserve is the default quality policy; grayscale and reduced quality are
   always explicit.
9. `-o FILE` / `--output FILE` is for one-off conversion of exactly one regular
   PDF to an exact filename. It does not accept directories, multiple inputs, or
   `--recursive`; its parent directory must already exist.
10. Require `-i PATH` / `--input PATH` for every input. Repeat it for multiple
    files or directories. Positional inputs and the `--` terminator are not
    supported.
11. Quality can be selected either through the named `--quality` presets or
    through detailed `--max-dpi` / `--jpeg-recompress` controls. Reject commands
    that mix those approaches with a clear explanation. With no quality option,
    default to `preserve`; keep `--grayscale` independent.
12. Allow quoted basic glob patterns as `--input` values. Prefer an existing
    literal path when its filename contains glob metacharacters, reject
    no-match patterns, and reject accidental unquoted multi-match expansion
    before conversion or writes with a quoting hint.
13. Allow `--clean-scan gentle|standard|strong` for safely detected image-only
    scans. Preserve page dimensions, source resolution, and color by default.
    With no quality arguments, re-encode changed pixels at `QFactor 0.10`;
    explicit quality controls override cleanup defaults, and `--grayscale`
    remains independent. Refuse inputs whose detectable non-image content would
    be lost by flattening.
14. Prefix operational output with local `[HH:MM:SS]` wall-clock timestamps.
    Print `[YYYY-MM-DD]` before the first operational message and repeat the date
    after the last only when the run crosses midnight. Emit `processing:` before
    each real conversion. Leave help, version, and blank separator lines
    undecorated.

Implemented options:

- `-i PATH`, `--input PATH` — select an input PDF, directory, or quoted glob
  pattern; repeat for multiple inputs.
- `-o FILE`, `--output FILE` — publish one input PDF at an exact filename.
- `--output-dir DIR` — publish converted PDFs under a separate directory.
- `--replace` — replace an original only after a valid conversion is strictly
  smaller.
- `--recursive` — descend into supplied directories.
- `--reprocess` — bypass replacement-log checks without destroying the log or
  disabling safety checks.
- `--timeout DURATION` — per-file conversion timeout, default `1h`.
- `--dry-run` — show planned files/actions without Ghostscript or writes.
- `--quality MODE` — accept `preserve`, `balanced`, or `small`.
- `--max-dpi DPI` — detailed positive-integer color/grayscale DPI cap.
- `--jpeg-recompress Q` — detailed JPEG encoding with Ghostscript QFactor
  `0.0` through `1.0`.
- `--grayscale` — explicit and independent of quality mode.
- `--clean-scan MODE` — explicit gentle, standard, or strong image-only scan
  contrast cleanup.
- `--help` — document usage, defaults, behavior, and statuses.
- `--version` — add once useful; a development version is acceptable early.

Accept multiple files and directories through repeated `--input` options.
Correctly handle spaces, tabs, glob characters, and leading hyphens. Use Bash
arrays and null-delimited traversal; do not use string-based file loops, parse
`ls`, or globally change `IFS`.

When several supplied roots would map different sources to the same
destination, the implementation detects the collision and fails safely rather
than choosing or overwriting one silently.

## Completed implementation sequence and retained constraints

The stages below are complete. They remain as design and regression constraints
for future changes rather than as an unfinished implementation checklist.

### 1. Historical workspace verification — completed

The project root, Git state, remote, branch, and ordinary patch access were
verified before implementation. The two legacy scripts were hash-verified
before their later retirement. The temporary `/Users/stansult/dev/pdf_low`
compatibility symlink was resolved and removed without affecting the project.

### 2. Interface and safe traversal

Implement argument parsing, help, validation, case-insensitive PDF discovery,
null-delimited recursive/non-recursive traversal, symlink refusal, dry-run, and
safe destination mapping. Do not run Ghostscript in dry-run. Commit this layer
independently.

### 3. Reliable Ghostscript conversion

Use no `-dPDFSETTINGS` preset in the initial `preserve` mode and do not force
PDF 1.4 compatibility. Add grayscale arguments only when requested.

Detect `timeout` or `gtimeout`; never silently run without the requested
timeout. Capture stdout and stderr together and save status immediately:

```bash
output=$(command ... 2>&1)
status=$?
```

Treat all nonzero statuses as failures, identify timeout separately where
practical, print captured diagnostics, and require the result to be a nonempty
regular file. Warning-string inspection can supplement but never replace
exit-status checks.

Recovery-warning handling remains future work: a successful Ghostscript exit
that reports repairing or recovering a damaged PDF must never cause
`--replace` to replace the original. The intended behavior is to preserve the
original and retain a separate recovered candidate for inspection; its public
reporting and artifact naming still need to be designed and approved.

### 4. Safe output publication and replacement

For replacement, create the candidate in the original file's directory with a
collision-resistant `mktemp` name. Track exactly that temporary path and clean
it on failure or interruption. Never delete the original first. After complete
validation, compare byte sizes; use one same-filesystem `mv` only when the
candidate is strictly smaller. Otherwise delete only the candidate and retain
the original unchanged.

Investigate and discuss metadata preservation before promising permissions,
ownership, timestamps, extended attributes, or macOS metadata behavior.

For output-directory mode, preserve relative structure, validate before
publishing, and refuse existing destinations and mapping collisions. Exact-file
output must accept only one regular PDF and use the user-supplied destination.
Both output modes must recheck the destination immediately before atomic
publication. Never publish a partial candidate under its final name.

### 5. Correct replacement logging

Log only terminal successful outcomes: replaced, or valid conversion retained
because it was not smaller. Never log failure, timeout, invalid/empty output, or
interruption. `--reprocess` bypasses checks without erasing history.

Version 2 stores null-delimited canonical path, size, modification time,
resolved processing signature, outcome, processing time, and an optional
related artifact. It loads history once per batch and skips only a matching
file identity plus matching processing signature. Version-1 and legacy imports
use a wildcard signature to preserve their historical skip behavior; do not
treat those entries as proof of successful conversion.

The default state location is `~/Library/Application Support/pdf-slim` on
macOS and `${XDG_STATE_HOME:-$HOME/.local/state}/pdf-slim` elsewhere.
`PDF_SLIM_STATE_DIR` accepts an absolute override. State directories use mode
`700` and the log uses mode `600`.

### 6. Quality modes

The lossy presets below were finalized after interface, conversion, replacement,
output, cleanup, logging, and representative quality testing. Future changes to
their values require renewed comparison and user approval.

- `preserve` (default): no intentional image downsampling and normally no
  `-dPDFSETTINGS`; use lossless Flate image encoding.
- `balanced`: cap images above 300 DPI and use JPEG `QFactor 0.15`.
- `small`: cap images above 250 DPI and use JPEG `QFactor 0.4`.
- Detailed mode: allow either or both of `--max-dpi DPI` and
  `--jpeg-recompress Q`. With no explicit DPI cap, retain color/grayscale
  resolution. With no explicit recompression value, pass through eligible
  existing JPEGs and use `QFactor 0.15` for images that require JPEG encoding.
  Retain the 600-DPI monochrome cap.
- `--grayscale`: orthogonal explicit visible change.

Review current official Ghostscript `pdfwrite` documentation and test candidate
settings on representative local PDFs before choosing values. Discuss values
with the user before making defaults. Never claim lossy output is visually
identical.

### 7. Tests and documentation

Add automated shell tests or a documented test harness using Ghostscript test
doubles where useful. At minimum cover:

- single/multiple files and directories;
- spaces, tabs, glob characters, leading hyphens, and uppercase `.PDF`;
- non-PDF, missing input, empty directory, and recursive traversal;
- success with smaller/equal/larger output;
- nonzero exit with no output and with partial output;
- timeout and zero-status empty output;
- interruption and precise temporary cleanup;
- byte-identical original after every failure or non-smaller result;
- refusal to overwrite output or follow symlinks;
- exact-file output with both aliases, plus conflicts with directory output,
  replacement, multiple/directory inputs, recursion, and race-time destination
  creation;
- preset/detail quality conflicts, detailed value validation, independent
  QFactor and DPI propagation, and detailed grayscale conversion;
- quoted input glob expansion, no-match failure, existing literal
  metacharacter filenames, and safe rejection of unquoted multi-match usage;
- no log update after failure/timeout;
- dry-run performs no writes and launches no Ghostscript process.

Always run:

```bash
bash -n pdf-slim.sh
```

Run ShellCheck; it is installed in the last observed environment. Do not install
or upgrade dependencies without approval.
Keep `README.md` and both commands' usage text aligned with behavior.

## Deferred work

1. Implement the Ghostscript recovery-warning behavior described above, with
   tests for zero-status repaired/recovered input and safe `--replace` handling.
2. Add an optional progress counter for large batch runs.
3. Design a regular version-2 history-integrity check covering the header,
   complete records, valid fields, duplicate records, permissions, and possibly
   stale paths. Decide whether it belongs in `pdf-slim.sh`, a separate command,
   or maintenance tests before implementation.
4. Keep forced PDF 1.4 compatibility or a PDF-version option deferred unless a
   concrete compatibility need appears.

## Safety constraints

- Preserve user PDFs above all else.
- Never replace an original after a failed, timed-out, interrupted, empty, or
  otherwise invalid conversion.
- Quote every pathname and option value.
- Avoid broad deletion commands, unresolved destructive paths, and `rm` followed
  by `mv` replacement sequences.
- Keep destructive behavior explicit through `--replace`.
- Treat the private state directory and active replacement history as user data;
  never rewrite or discard it casually.
- Do not create/push another remote or install dependencies without user approval.
- Present material CLI, metadata, logging-format, and quality choices to the user
  before finalizing them.

## Collaboration and change approval

A concern, observation, question, or report of confusing behavior is not by
itself authorization to change the project.

When the user raises a concern without explicitly requesting implementation:

1. Restate the concern and ask the user to confirm that it was understood
   correctly.
2. After that confirmation, propose a specific solution without changing files.
3. Wait for the user to approve the proposed solution.
4. Only then implement, test, commit, or push the approved change.

Do not combine the understanding confirmation and solution approval into one
assumed decision. If the user explicitly requests a specific change, that
request is already authorization for that stated change.

## Immediate next step

The implementation and legacy-history migration are complete. The next
substantive safety improvement is Ghostscript recovery-warning handling, but it
requires explicit design approval before code changes. For future changes, run
`tests/run.sh`, Bash syntax checks, and ShellCheck before release, and keep
subsequent changes small and reviewable.
