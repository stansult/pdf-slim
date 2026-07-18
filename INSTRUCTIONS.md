# pdf-slim consolidation handoff

## Objective

Consolidate the two existing PDF-processing scripts into one reliable, configurable shell script. The default quality mode must prioritize preserving the PDF's visible appearance. More aggressive compression must be available only through explicit options.

The project will be moved out of Dropbox before work continues. Start the next session from the relocated `pdf-slim` directory and treat that directory as the project root.

## Current state

The directory currently contains:

- `pdf_low.sh` — converts matching PDFs into an output directory. Its normal mode uses Ghostscript's `/ebook` preset; its `bw` mode converts output to grayscale.
- `pdf_low_replace.sh` — recursively processes PDFs, replacing an original only when the converted output is smaller. It currently uses Ghostscript's `/printer` preset and records processed paths in `processed_pdfs.log`.
- `processed_pdfs.log` — runtime history created by the replacement script.
- `INSTRUCTIONS.md` — this handoff and implementation plan.

The scripts were moved into this directory without modification. No Git repository has been initialized yet.

## Agreed direction

1. Make this directory a standalone Git repository after it is relocated.
2. Commit the untouched scripts as the historical baseline before changing them.
3. Replace the two scripts with one canonical `pdf-slim.sh` supporting explicit options.
4. Fix conversion/error-handling and replacement safety before designing quality modes.
5. Default to a quality-preserving mode. Reduced-quality modes must be opt-in.
6. Do not retain a permanent `legacy/` directory; Git history will preserve the original scripts.
7. `processed_pdfs.log` is runtime state and should not be committed.

## Phase 1: initialize Git and preserve the baseline

Do this only after confirming that the shell's current directory is the relocated `pdf-slim` directory.

1. Inspect the directory and ensure the expected files are present.
2. Initialize a local Git repository.
3. Create `.gitignore` with at least:

   ```gitignore
   processed_pdfs.log
   *.tmp.pdf
   .DS_Store
   ```

   If the final temporary-file naming convention differs, update the ignore rule accordingly.
4. Add a concise `README.md` describing the current legacy scripts and noting that consolidation is pending.
5. Commit the untouched scripts, `.gitignore`, `README.md`, and this instruction file as the baseline. Do not commit `processed_pdfs.log`.
6. Confirm that `git status` is clean apart from the ignored runtime log.

Suggested baseline commit message:

```text
Preserve original PDF scripts before consolidation
```

Creating a GitHub remote is optional at this point. Local Git history should exist before implementation begins. Do not publish the repository unless the user asks.

## Phase 2: define the consolidated interface

Implement one canonical command:

```bash
pdf-slim.sh [options] [FILE_OR_DIRECTORY ...]
```

The intended interface is:

- `--output-dir DIR` — write converted PDFs under a separate directory.
- `--replace` — replace each original only if the successfully converted PDF is smaller.
- `--recursive` — descend into supplied directories.
- `--force` or `--reprocess` — ignore entries in the processed-file log.
- `--timeout DURATION` — conversion timeout, default `1h`.
- `--dry-run` — show which files and actions would be attempted without running Ghostscript or modifying files.
- `--quality MODE` — quality policy; initially implement only the safe default or defer all modes until Phase 5.
- `--grayscale` — explicitly convert colors to grayscale; keep this independent of quality mode.
- `--help` — document usage, defaults, behavior, and exit statuses.
- `--version` — optional but useful once the interface stabilizes.

Interface rules:

1. The default must be non-destructive. Prefer requiring either `--output-dir DIR` or `--replace`; alternatively, use a documented default output directory. Discuss this choice with the user before finalizing it.
2. `--replace` and `--output-dir` should be mutually exclusive unless a clear combined meaning is established.
3. Accept multiple files and directories safely, including names containing spaces, tabs, glob characters, and leading hyphens.
4. Support `--` to terminate option parsing.
5. Do not use string-based file loops or change global `IFS`. Use arrays and null-delimited traversal.
6. Decide with the user whether `.PDF` and other case variants should count as PDFs. Case-insensitive matching is recommended.

Commit the interface/refactor independently from later quality-policy work.

## Phase 3: repair Ghostscript and timeout error handling

This is the first functional implementation priority. The legacy replacement script has two related bugs:

1. `output=$(...)` captures standard output but not standard error, while Ghostscript usually emits diagnostics on standard error.
2. The command's exit status is not retained and checked reliably. A failed Ghostscript process can create a partial output and the function can later return success accidentally.

The consolidated conversion function must:

1. Capture standard output and standard error together using `2>&1`.
2. save the command status immediately after command substitution:

   ```bash
   output=$(command ... 2>&1)
   status=$?
   ```

   Do not run another command before assigning `status`.
3. Treat every nonzero status as a failed conversion.
4. Identify and report timeout status separately where practical.
5. Print the captured Ghostscript diagnostics on failure.
6. Verify that the output exists, is a regular file, and is nonempty even when the command reports success.
7. Return failure if any validation fails.
8. Never allow warning-string searches to replace exit-status checking. `-dPDFSTOPONWARNING` may remain if supported by the installed Ghostscript, but it is an additional safeguard, not the primary success test.

### Portability note

The existing scripts assume macOS with GNU utilities installed by Homebrew (`greadlink`, `grealpath`, and GNU `timeout`). Before coding, inspect the actual environment:

```bash
command -v gs
command -v timeout
command -v gtimeout
command -v realpath
command -v grealpath
```

Prefer shell-native path handling where feasible. If a timeout program is required, detect `timeout` and `gtimeout` and fail with an actionable message when neither exists. Do not silently run without the requested timeout.

## Phase 4: make replacement and cleanup safe

For `--replace`:

1. Create the candidate output in the same directory as the original. This makes the final rename occur on the same filesystem.
2. Give temporary files a collision-resistant name, preferably using `mktemp` with a narrowly scoped template.
3. Install cleanup handling so normal errors and interruptions remove only the known temporary file.
4. Never remove the original before the candidate has passed all checks.
5. After successful conversion:
   - determine old and new byte sizes using a portable method;
   - if the candidate is strictly smaller, replace the original with a single `mv` operation;
   - otherwise remove the candidate and leave the original untouched.
6. Preserve original permissions where appropriate. Investigate whether ownership, timestamps, extended attributes, and macOS metadata need preservation; discuss any tradeoffs before promising preservation.
7. Refuse unsafe cases such as input and output resolving to the same temporary pathname.
8. Do not follow unexpected symlinks without an explicit, documented policy.

The old sequence `rm original` followed by `mv candidate original` must not be retained because it creates an avoidable window in which the original is gone.

For `--output-dir`:

1. Define whether directory structure is preserved for recursive inputs. Preserving relative structure is recommended to avoid basename collisions.
2. Never overwrite an existing destination silently. Choose an explicit policy such as skip by default and add a future `--overwrite` option if needed.
3. Validate the candidate completely before publishing it at the destination pathname.

## Phase 5: correct processed-file logging

The existing log contains absolute file paths and currently records a file even after conversion errors. Change this behavior:

1. Keep the log beside the script/project data unless a more appropriate user-state directory is selected later.
2. Do not commit the log.
3. Log a file only after a terminal successful outcome:
   - conversion succeeded and the original was replaced; or
   - conversion succeeded but the candidate was not smaller, so the original was intentionally retained.
4. Do not log failures, timeouts, invalid outputs, or interrupted conversions; they must remain eligible for retry.
5. Append safely and ensure each record is unambiguous. Plain newline-separated paths cannot represent filenames containing newlines. Decide whether that edge case should be supported via a null-delimited log or documented as unsupported.
6. Decide whether logging applies only to `--replace` or also to output-directory mode. Replacement-only logging is the simpler default.
7. Implement `--force`/`--reprocess` to bypass log checks without destroying the log.
8. Consider file modification after logging. A path-only entry can incorrectly suppress a changed file. A stronger future format could include path, size, and modification time. Discuss this before expanding scope.

The existing `processed_pdfs.log` may contain useful history. Preserve it during migration, but do not assume every entry represents a successful conversion because of the legacy behavior.

## Phase 6: quality modes

Do not finalize the quality presets until Phases 2–5 are working and tested.

### Required policy

- Default mode: closest practical visual match to the input, with no intentional image downsampling.
- Reduced-quality modes: explicit opt-in.
- Grayscale: explicit and orthogonal because it visibly changes the document.

Proposed names:

- `--quality preserve` — default. Omit `-dPDFSETTINGS`, or use `/default` only if tests show a reason. Do not force `-dCompatibilityLevel=1.4`; current Ghostscript defaults should generally be preferred.
- `--quality balanced` — modest reduction intended to remain clean on ordinary screens and prints.
- `--quality small` — stronger reduction aimed at large scans and image-heavy documents.

Avoid assuming `/prepress` means maximum fidelity. Ghostscript documentation states that the closest result to the original is obtained without `-dPDFSETTINGS` or with `/default`, and that every preset can alter the input.

For `balanced` and `small`, prefer explicit image downsampling and compression controls over relying only on `/printer` and `/ebook`. Explicit controls make behavior easier to explain and less dependent on preset definitions. Before choosing values:

1. Confirm the installed Ghostscript version.
2. Review current official Ghostscript `pdfwrite` documentation.
3. Build a representative local test set:
   - vector/text-heavy PDF;
   - high-resolution scanned document;
   - photographic PDF;
   - charts and fine linework;
   - transparency and annotation examples if available.
4. Compare file sizes and rendered output at realistic zoom levels and print-like resolution.
5. Discuss candidate resolution/compression values with the user before making them defaults.

Do not claim any lossy mode is visually identical. Name and document the tradeoff plainly.

## Phase 7: validation

Add a test script or documented test procedure. At minimum verify:

### Input handling

- One PDF file.
- Multiple PDF files.
- Filename containing spaces.
- Filename containing tabs or glob characters.
- Filename beginning with `-`.
- Non-PDF input.
- Missing input.
- Empty directory.
- Recursive directory traversal.
- Uppercase `.PDF`, according to the chosen policy.

### Conversion outcomes

- Ghostscript success with smaller output.
- Ghostscript success with equal or larger output.
- Ghostscript nonzero exit with no output.
- Ghostscript nonzero exit with a partial output.
- Timeout.
- Empty output despite zero status, using a test double if necessary.
- User interruption and temporary-file cleanup.

### Safety

- Original remains byte-for-byte untouched after every failed conversion.
- Original remains untouched when the candidate is not smaller.
- Existing output destination is not silently overwritten.
- Temporary files are removed after success, failure, timeout, and interruption.
- Log is not updated after failure or timeout.
- `--dry-run` performs no writes and runs no Ghostscript conversion.

### Quality

- Compare rendered pages between original and `preserve` output.
- Inspect text, fine lines, gradients, photographs, scans, and transparency.
- Record output sizes for each proposed quality mode.

Use `shellcheck` if available. Run syntax validation with:

```bash
bash -n pdf-slim.sh
```

Do not install dependencies or publish files without user approval.

## Phase 8: documentation and cleanup

1. Expand `README.md` with prerequisites, installation, examples, quality-mode descriptions, replacement safety, logging behavior, and limitations.
2. Include examples such as:

   ```bash
   ./pdf-slim.sh --output-dir ./new document.pdf
   ./pdf-slim.sh --replace --recursive ./archive
   ./pdf-slim.sh --replace --quality small huge-scan.pdf
   ./pdf-slim.sh --output-dir ./gray --grayscale report.pdf
   ./pdf-slim.sh --dry-run --replace --recursive .
   ```

3. After the consolidated script passes validation, remove the obsolete replacement script from the working tree. Its original content remains in Git history.
4. Decide whether the preexisting `processed_pdfs.log` should remain in the relocated working directory, be archived outside the repository, or be reset. Do not delete it without user approval.
5. Commit logical changes separately. Suggested sequence:
   - baseline originals;
   - consolidated interface and safe file traversal;
   - reliable conversion/error handling;
   - atomic replacement and corrected logging;
   - quality modes;
   - tests and documentation;
   - removal of obsolete script.
6. Once the user is satisfied, optionally create a private or public GitHub repository and push it. Ask before creating or publishing a remote repository.

## Important implementation constraints

- Preserve user data above all else. Never replace an original after a failed, timed-out, interrupted, empty, or otherwise invalid conversion.
- Quote every pathname and option value correctly.
- Prefer Bash arrays and `find -print0`/null-delimited processing over word splitting.
- Avoid parsing `ls` output.
- Avoid deleting broad paths or unresolved variables.
- Keep quality-preserving behavior as the default.
- Keep destructive behavior explicit through `--replace`.
- Make changes in small commits so each stage is reviewable and reversible.
- Before implementing a choice that materially changes CLI behavior or quality, present the proposed behavior to the user for discussion.

## Next-session starting checklist

The next Codex thread should:

1. Read this file and both legacy scripts completely.
2. Confirm the folder has been relocated outside Dropbox.
3. Inspect available Ghostscript and GNU utility versions without modifying the system.
4. Initialize Git and make the untouched baseline commit.
5. Stop and report the baseline state before beginning functional changes, unless the user explicitly asks to continue through subsequent phases.
