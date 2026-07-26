# pdf-slim project handoff

## Objective

Build one reliable, configurable Bash command for reducing PDF file sizes with
Ghostscript. The default quality policy must prioritize preserving the visible
appearance of the source PDF. More aggressive, lossy compression must be
available only through explicit options.

The active project and command are named **pdf-slim**. The old name `pdf_low`
applies only to the preserved legacy filenames.

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

The current branch is `master`, tracking `origin/master`. At the last verified
state, the working tree was clean and synchronized with the remote except for
the ignored runtime log.

The implementation was developed through small logical commits. Do not rewrite
this history.

## Current files

```text
pdf-slim.sh                    Active functional consolidated script
legacy/pdf_low.sh              Usable legacy conversion script
legacy/pdf_low_replace.sh      Preserved legacy replacement script
legacy/processed_pdfs.log      Ignored archived legacy runtime history
processed_pdfs.log             Ignored active replacement log (created on demand)
README.md                      Short project/layout description
INSTRUCTIONS.md                This handoff
.gitignore                     Runtime/temp exclusions
tests/                         Automated test suite and Ghostscript double
```

The active script implements safe traversal, dry-run planning, reliable
Ghostscript conversion, atomic output publication, strictly-smaller replacement,
metadata preservation, and versioned null-delimited replacement logging.

## Preserved legacy baseline

The legacy scripts remain usable while consolidation is completed. The user
intentionally changed `legacy/pdf_low.sh` from `/ebook` to `/printer` in commit
`030b997`. Their current verified SHA-256 hashes are:

```text
6b6cb630e848997f5ecfb4e7362ecb4011984dc0693a1258cfe4a770bf0200d8  legacy/pdf_low.sh
ac1fa2f24df52d656712d932be2688d26225cf1e0f3e1951d1e37c8a70798bba  legacy/pdf_low_replace.sh
```

The legacy scripts contain known quoting, traversal, error-handling, temporary
file, replacement, and logging problems. They are reference material, not code
to extend. Do not clean their trailing whitespace or rename them.

The preexisting runtime history was moved, with user approval, to
`legacy/processed_pdfs.log`. It remains ignored and unmodified. The active
script creates or reuses a root-level `processed_pdfs.log` in its new versioned
null-delimited format.

## Environment last observed

```text
Ghostscript:        10.07.1 at /usr/local/bin/gs
GNU timeout:        9.11 at /usr/local/bin/timeout
GNU gtimeout:       /usr/local/bin/gtimeout
realpath:           /bin/realpath
grealpath:          /usr/local/bin/grealpath
greadlink:          /usr/local/bin/greadlink
shellcheck:         not installed
```

Do not install dependencies without user approval. Recheck these commands in
the new thread because environment state can change.

## Agreed interface and behavior

The canonical command will be:

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

Planned options:

- `-i PATH`, `--input PATH` — select an input PDF or directory; repeat for
  multiple inputs.
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
- `--help` — document usage, defaults, behavior, and statuses.
- `--version` — add once useful; a development version is acceptable early.

Accept multiple files and directories through repeated `--input` options.
Correctly handle spaces, tabs, glob characters, and leading hyphens. Use Bash
arrays and null-delimited traversal; do not use string-based file loops, parse
`ls`, or globally change `IFS`.

One output-layout detail remains to implement carefully: when several supplied
roots would map different sources to the same destination, detect the collision
and fail safely rather than choosing or overwriting one silently.

## Implementation sequence

### 1. Verify the new workspace before editing

1. Confirm `pwd` is `/Users/stansult/dev/pdf-slim`.
2. Confirm `git status`, remote, branch, and files.
3. Verify the two legacy hashes above.
4. Test a harmless patch edit/revert in the real project path to prove ordinary
   write access, not merely terminal read access.
5. Inspect and then remove only the temporary `/Users/stansult/dev/pdf_low`
   symlink. Never operate recursively on it.
6. Reconfirm the working tree before implementation.

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
regular file. Warning-string inspection and `-dPDFSTOPONWARNING` can supplement
but never replace exit-status checks.

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

Before implementing the final format, discuss with the user whether to use a
null-delimited log and whether records should include size and modification time
so changed files are not incorrectly skipped. Do not trust old log entries as
proof of successful conversion.

### 6. Quality modes

Do not finalize lossy presets until interface, conversion, replacement, output,
cleanup, and logging behavior are tested.

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
- no log update after failure/timeout;
- dry-run performs no writes and launches no Ghostscript process.

Always run:

```bash
bash -n pdf-slim.sh
```

Use `shellcheck` if it becomes available, but do not install it without approval.
Expand `README.md` after behavior stabilizes.

## Safety constraints

- Preserve user PDFs above all else.
- Never replace an original after a failed, timed-out, interrupted, empty, or
  otherwise invalid conversion.
- Quote every pathname and option value.
- Avoid broad deletion commands, unresolved destructive paths, and `rm` followed
  by `mv` replacement sequences.
- Keep destructive behavior explicit through `--replace`.
- Do not modify legacy files or the preexisting runtime log.
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

Version `1.0.0` is feature-complete for the agreed scope. Run `tests/run.sh` and
`bash -n pdf-slim.sh` before future releases, preserve the legacy files and
archived log, and keep subsequent changes small and reviewable.
