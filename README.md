# Nocturne

A personal, AI-first photo editor for macOS. Native Swift, Core Image and Metal, built for an Intel MacBook Pro and a Nikon D80.

## What works (0.2)

- Library on two plain folders: `~/Pictures/Nocturne/To Process` and `~/Pictures/Nocturne/Processed`. Drop photos into the folder or onto the window and they appear on their own.
- RAW (through Apple's RAW engine) and regular formats, decoded into a linear Display P3 working space.
- Editor where the photo fills the window. Step kinds: Light, Color, Grade, Color Splash, Vignette, Mist, Grain, Match.
- Masks on any step: Subject, Person, Background (Apple Vision) and Sky, Near, Far (Depth Anything V2 Small running locally on the CPU). Hover a mask chip to see it.
- Describe the look: type a sentence and Gemini (free tier) proposes named recipe steps, with masks where you name a region ("darker sky", "black and white, only the sun in color"). Every step can be switched off, tuned or deleted.
- Match a reference: copy any image or screenshot and press Cmd+V in the editor. The look (tone and color per shadow, midtone and highlight zone) is measured locally and applied as one step with an Amount slider.
- Presets: save a look by name, hover to preview it, click to apply. Stored as JSON in `~/Pictures/Nocturne/Presets`.
- Batch: Cmd-click or Shift-click photos in the library, then paste a copied look, apply a preset or export them all (right-click or the Photo menu). Masks and matches are recomputed for every photo.
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
| Cmd+V | Match the image on the clipboard |
| Shift+Cmd+C / Shift+Cmd+V | Copy / paste a look |
| Shift+Cmd+P | Presets |
| Cmd+A | Select all photos in the library |
| Cmd+E | Export |
| Cmd+Z / Shift+Cmd+Z | Undo / redo |

## Build

```bash
./build.sh install
```

Builds with SwiftPM, bundles and signs `Nocturne.app`, and copies it to `/Applications`. The Metal kernels compile at runtime, so the offline Metal toolchain is not needed.

`./build.sh dev` makes a separate `Nocturne Dev.app` for testing; run it with `NOCTURNE_ROOT` pointing at a test library.

`nocturnetool` is a small CLI for engine checks: `render`, `describe`, `name`, `bench`, `masks`, `match`.

The depth model is not in the repo. Download `DepthAnythingV2SmallF16.mlpackage` from `apple/coreml-depth-anything-v2-small` on Hugging Face, compile it with `xcrun coremlcompiler compile` and put the `.mlmodelc` in `~/Library/Application Support/Nocturne/Models/`.

The Gemini key is read from `~/Library/Application Support/Nocturne/.env` (`GEMINI_API_KEYS`), never from the source.

## Planned

Stacking (stars, Moon, star trails, focus stacking, long exposure from a series) with a Nikon D80 field guide and tethered shooting, virtual 3D lighting, lens effects, cleanup and denoise.
