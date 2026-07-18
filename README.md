# pdf_low

This repository currently preserves two legacy PDF-processing scripts:

- `pdf_low.sh` converts matching PDFs into a separate output directory, using
  Ghostscript's `/ebook` preset by default or an optional grayscale mode.
- `pdf_low_replace.sh` recursively converts PDFs and replaces an original only
  when the converted file is smaller.

The scripts are preserved here as an untouched historical baseline.
Consolidation into one safer, configurable command is pending.

`processed_pdfs.log` is runtime history from the legacy replacement script and
is intentionally excluded from version control.
