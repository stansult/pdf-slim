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

Start the next Codex thread from that exact directory and verify normal file
writes with the patch editor before claiming the workspace is ready. The thread
that produced this handoff retained a sandbox write grant for the former path
`/Users/stansult/dev/pdf_low`; terminal reads and elevated Git commands worked in
the renamed directory, but ordinary patch edits did not. This was discovered
only when implementation was about to begin.

A temporary compatibility symlink currently exists:

```text
/Users/stansult/dev/pdf_low -> /Users/stansult/dev/pdf-slim
```

It was created solely while diagnosing the stale workspace grant. After a new
thread confirms direct write access to `/Users/stansult/dev/pdf-slim`, remove
the symlink without affecting the real project directory. Resolve and verify
both paths before removing anything.

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

Existing commits:

```text
3b28637 Rename project to pdf-slim
c3743d4 Move legacy scripts aside for consolidation
0550bfb Preserve original PDF scripts before consolidation
```

Do not rewrite this history. Continue with small, logical commits.

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
pdf-slim.sh [options] [FILE_OR_DIRECTORY ...]
```

The user has approved these decisions:

1. Require exactly one of `--output-dir DIR` or `--replace`. There is no implicit
   destructive action and no implicit default output directory.
2. `--replace` and `--output-dir` are mutually exclusive.
3. Match PDF extensions case-insensitively, including `.PDF`.
4. Skip symlinks with a clear warning; do not follow them.
5. Preserve relative directory structure beneath `--output-dir`.
6. Never overwrite an existing output destination silently.
7. Keep processed-file logging limited to `--replace` initially.
8. Preserve is the default quality policy; grayscale and reduced quality are
   always explicit.

Planned options:

- `--output-dir DIR` — publish converted PDFs under a separate directory.
- `--replace` — replace an original only after a valid conversion is strictly
  smaller.
- `--recursive` — descend into supplied directories.
- `--force` or `--reprocess` — bypass replacement-log checks without destroying
  the log.
- `--timeout DURATION` — per-file conversion timeout, default `1h`.
- `--dry-run` — show planned files/actions without Ghostscript or writes.
- `--quality MODE` — initially accept only `preserve`; add lossy modes later.
- `--grayscale` — explicit and independent of quality mode.
- `--help` — document usage, defaults, behavior, and statuses.
- `--version` — add once useful; a development version is acceptable early.
- `--` — terminate option parsing so leading-hyphen filenames are safe.

Accept multiple files and directories. Correctly handle spaces, tabs, glob
characters, and leading hyphens. Use Bash arrays and null-delimited traversal;
do not use string-based file loops, parse `ls`, or globally change `IFS`.

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

For output mode, preserve relative structure, validate before publishing, and
refuse existing destinations and mapping collisions. Never publish a partial
candidate under its final name.

### 5. Correct replacement logging

Log only terminal successful outcomes: replaced, or valid conversion retained
because it was not smaller. Never log failure, timeout, invalid/empty output, or
interruption. `--force` bypasses checks without erasing history.

Before implementing the final format, discuss with the user whether to use a
null-delimited log and whether records should include size and modification time
so changed files are not incorrectly skipped. Do not trust old log entries as
proof of successful conversion.

### 6. Quality modes

Do not finalize lossy presets until interface, conversion, replacement, output,
cleanup, and logging behavior are tested.

- `preserve` (default): no intentional image downsampling and normally no
  `-dPDFSETTINGS`.
- `balanced`: future explicit opt-in with documented modest loss.
- `small`: future explicit opt-in with stronger reduction.
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

## Immediate next step

The next thread should perform the workspace/access verification checklist,
clean up the temporary compatibility symlink after resolving it safely, and
report the verified state. Only then begin the interface/safe-traversal commit.
