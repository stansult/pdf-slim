# pdf-slim

This repository preserves two legacy PDF-processing scripts under `legacy/`:

- `legacy/pdf_low.sh` converts matching PDFs into a separate output directory, using
  Ghostscript's `/ebook` preset by default or an optional grayscale mode.
- `legacy/pdf_low_replace.sh` recursively converts PDFs and replaces an original only
  when the converted file is smaller.

The legacy scripts remain unchanged for reference. A new top-level `pdf-slim.sh`
is the starting point for consolidation into one safer, configurable command.

`processed_pdfs.log` is runtime history from the legacy replacement script and
is intentionally excluded from version control.
