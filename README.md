# Nocturne

A personal, AI-first photo editor for macOS. Native Swift, Core Image and Metal, built for an Intel MacBook Pro and a Nikon D80.

## What works (0.1)

- Library on two plain folders: `~/Pictures/Nocturne/To Process` and `~/Pictures/Nocturne/Processed`. Drop photos into the folder or onto the window and they appear on their own.
- RAW (through Apple's RAW engine) and regular formats, decoded into a linear Display P3 working space.
- Editor where the photo fills the window. Six step kinds: Light, Color, Grade, Vignette, Mist, Grain.
- Describe the look: type a sentence and Gemini (free tier) proposes named recipe steps. Every step can be switched off, tuned or deleted.
- Non-destructive: the recipe is a small JSON saved beside the photo after every change. Originals are never modified.
- Export writes a full-size JPEG with EXIF into `Processed`, suggests a descriptive Polish file name, and keeps the original in `Processed/Originals` so the project can be reopened and edited further.

## Keys

| Key | Action |
| --- | --- |
| Return | Open the selected photo, or jump to the prompt in the editor |
| Esc | Back to the library |
| Left / Right | Previous / next photo |
| `\` (hold) | Show the original |
| Z or double-click | Fit / 100% |
| Tab | Hide the controls |
| Cmd+K | Describe the look |
| Cmd+E | Export |
| Cmd+Z / Shift+Cmd+Z | Undo / redo |

## Build

```bash
./build.sh install
```

Builds with SwiftPM, bundles and signs `Nocturne.app`, and copies it to `/Applications`. The Metal kernels compile at runtime, so the offline Metal toolchain is not needed.

`nocturnetool` is a small CLI for engine checks: `render`, `describe`, `name`, `bench`.

The Gemini key is read from `~/Library/Application Support/Nocturne/.env` (`GEMINI_API_KEYS`), never from the source.

## Planned

Reference matching from a pasted image, masks (subject, person, sky, depth), presets and batch, stacking (stars, Moon, star trails, focus stacking, long exposure from a series) with a Nikon D80 field guide and tethered shooting, virtual 3D lighting, lens effects, cleanup and denoise.
