# PDF quality policies

`pdf-slim.sh` offers named presets for common use and detailed controls for
experiments. Presets and detailed controls are mutually exclusive.

## Named presets

- `preserve` is the default. It keeps source image resolution and uses lossless
  Flate image encoding. Output may not be smaller; `--replace` retains the
  original in that case.
- `balanced` never upscales, caps color/grayscale images above 300 DPI using
  bicubic downsampling, and uses JPEG `QFactor 0.15` when encoding is required.
  Eligible existing JPEGs pass through unchanged.
- `small` never upscales, caps color/grayscale images above 250 DPI using
  bicubic downsampling, and uses JPEG `QFactor 0.4` when encoding is required.
  Eligible existing JPEGs pass through unchanged.

All policies retain the existing 600-DPI monochrome cap.

## Detailed controls

- `--max-dpi DPI` caps color and grayscale images at a positive integer DPI.
  Omitting it leaves their resolution uncapped.
- `--jpeg-recompress Q` forces color and grayscale images through JPEG
  encoding, including existing JPEGs below the DPI cap. `Q` is Ghostscript's
  QFactor from `0.0` through `1.0`; lower values preserve more quality and
  usually produce larger files.
- Without `--jpeg-recompress`, eligible JPEGs pass through. Images that must be
  JPEG-encoded in detailed mode use `QFactor 0.15`.
- `--grayscale` is independent and can accompany a preset or detailed policy.

| Arguments | Effective behavior |
| --- | --- |
| No quality arguments | Implicit `preserve` preset |
| `--quality MODE` | Named preset |
| `--max-dpi DPI` | Detailed mode with a DPI cap |
| `--jpeg-recompress Q` | Detailed recompression without a color/grayscale DPI cap |
| Both detailed options | Detailed control of recompression and DPI |
| Preset plus either detailed option | Invalid; choose one approach |

JPEG recompression and downsampling are lossy and do not guarantee a smaller
result.

## Interaction with scan cleanup

`--clean-scan` changes pixels before the PDF quality stage. With no quality
arguments, it retains source page dimensions and resolution and uses
`QFactor 0.10`. An explicit preset uses that preset instead. Detailed values
override corresponding cleanup defaults; supplying only `--max-dpi` retains the
cleanup default `QFactor 0.10`.

Explicit `--quality preserve` requests lossless encoding after cleanup. It does
not downsample, but output can be substantially larger than the practical
cleanup default.

For raster-image input, recorded density of at least 150 DPI determines the
physical PDF page size. Missing or lower density—common for phone photos—uses
300 DPI. This sets page dimensions without adding, removing, or resampling
pixels; the selected PDF policy may downsample afterward.

## Examples

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

Generate closely spaced candidates for visual comparison:

```bash
for q in 0.10 0.15 0.20 0.25 0.30; do
  pdf-slim.sh --input original.pdf --output "qfactor-$q.pdf" \
    --jpeg-recompress "$q"
done
```

See [`pdf-slim.sh` examples](examples.md) for output modes, scan cleanup, and
metadata combinations.
