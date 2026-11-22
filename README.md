# Nocturne

A personal, AI-first photo editor for macOS. Native Swift, Core Image and Metal, built for an Intel MacBook Pro and a Nikon D80.

## What works (0.7)

- Library on two plain folders: `~/Pictures/Nocturne/To Process` and `~/Pictures/Nocturne/Processed`. Drop photos into the folder or onto the window and they appear on their own.
- Camera import: a connected camera or card with a DCIM folder shows up in the sidebar with its photos grouped by day. Import a day with one click; after that, newer photos from the same card are imported on their own when it is connected. Nothing is deleted from the card.
- Tethered shooting: with the camera's USB mode set to PTP the Mac fires the shutter itself (a raw PTP InitiateCapture, so the camera's answer is readable: no card, busy, could not focus). Set a number of frames and an interval, press Start series, and every frame is pulled into To Process as it is taken. Older photos on the camera can be imported by day in this mode too.
- Series and stacks: frames shot within a few seconds with the same lens setting are recognised as a series, badged in the grid and offered for stacking in the bottom bar. Average aligns the frames and averages them (less noise), Lighten keeps the brightest value (star trails, light painting), Long exposure averages without aligning (silky water). The result is a 16-bit TIFF in To Process that edits like any photo. Any two or more selected photos can be stacked the same way.
- Field Guide for the Nikon D80: step by step from camera settings to the finished stack for stars, the Moon, star trails and silky water. Night mode tints the whole window deep red for work in the dark.
- RAW (through Apple's RAW engine) and regular formats, decoded into a linear Display P3 working space.
- Editor where the photo fills the window. Tone steps: Light, Color, Grade, Color Splash, Match.
- Light Stage: Lamp steps are virtual lights placed by clicking or dragging on the photo. A depth map gives every pixel a height, normals come from that relief, and shadows are ray-marched through it. Depth moves the lamp toward the camera or back behind things, where it turns into a rim light. Power, reach, warmth, shadow strength and scene dimming are sliders; click the Lamp tool again for a second lamp.
- Clean Up: paint over anything that should disappear (dust, wires, people, a whole monument) and the LaMa model fills in the background, about 0.6 s per stroke on the graphics card after a one-time warm-up. The fill is stored as a separate layer beside the photo, so it can be undone or switched off.
- Lens Lab: Mist, Halation, Bloom, Lens Blur (depth based, click the photo to pick what stays sharp), anamorphic Streaks, Fringe (chromatic aberration), Vignette, Grain.
- Masks on any step: Subject, Person, Background (Apple Vision) and Sky, Near, Far (Depth Anything V2 Small running locally on the CPU). Hover a mask chip to see it.
- Describe the look: type a sentence and Gemini (free tier) proposes named recipe steps, with masks where you name a region ("darker sky", "black and white, only the sun in color"). Every step can be switched off, tuned or deleted.
- Match a reference: copy any image or screenshot and press Cmd+V in the editor. The look (tone and color per shadow, midtone and highlight zone) is measured locally and applied as one step with an Amount slider.
- Presets: save a look by name, hover to preview it, click to apply. Stored as JSON in `~/Pictures/Nocturne/Presets`.
- Batch: Cmd-click or Shift-click photos in the library, then paste a copied look, apply a preset or export them all (right-click or the Photo menu). Masks and matches are recomputed for every photo.
- Non-destructive: the recipe is a small JSON saved beside the photo after every change. Originals are never modified.
- Export styles: Plain, Frame (a white or black border with a "Shot on" caption from EXIF, camera settings for real cameras, and an optional line of your own text) and Before / After (the original above the edit in one framed image). The frame is previewed live on the canvas and the last choice is remembered, also for batch export.
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

The models are not in the repo. Download `DepthAnythingV2SmallF16.mlpackage` from `apple/coreml-depth-anything-v2-small` and `LaMa.mlpackage` from `mlboydaisuke/LaMa-CoreML` on Hugging Face, compile each with `xcrun coremlcompiler compile` and put the `.mlmodelc` folders in `~/Library/Application Support/Nocturne/Models/`.

The Gemini key is read from `~/Library/Application Support/Nocturne/.env` (`GEMINI_API_KEYS`), never from the source.

## Planned

Star alignment and separate sky and ground stacking, lucky imaging for the Moon, focus stacking, denoise, crop and curves.
