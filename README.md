# Nozzles – 9 May

Audio & video production project. Uses **Git LFS** to manage large binary files.

## Directory Structure

```
nozzles9May/
├── raw-audio/          # Raw audio recordings (WAV, AIFF, etc.)
├── raw-video/          # Raw video footage (MOV, MP4, MXF, etc.)
├── projects/
│   ├── logic/          # Logic Pro projects (.logicx)
│   ├── protools/       # Pro Tools sessions (.ptx)
│   ├── ableton/        # Ableton Live sets (.als)
│   ├── finalcut/       # Final Cut Pro projects (.fcpbundle)
│   └── premiere/       # Premiere Pro projects (.prproj)
```

## Git LFS

All audio, video, and DAW/NLE binary files are tracked by Git LFS automatically via `.gitattributes`. Just commit normally — Git LFS handles the rest.

**Note on Logic Pro**: `.logicx` bundles are macOS directory packages, so Git tracks their contents as individual files (not a single LFS blob). Audio and image files inside `.logicx` bundles are caught by the `*.wav`, `*.jpg`, etc. LFS rules.

### Tracked file types

| Category | Extensions |
|----------|-----------:|
| Audio | `.wav` `.aif` `.aiff` `.flac` `.mp3` `.ogg` `.m4a` `.caf` |
| Video | `.mov` `.mp4` `.avi` `.mkv` `.mxf` `.r3d` `.braw` `.prores` |
| Pro Tools | `.ptx` `.ptf` `.pts` |
| Ableton | `.als` `.alp` `.adg` `.adv` `.alc` |
| Final Cut | `.fcpbundle` `.fcpxml` `.fcpproject` |
| Premiere | `.prproj` `.mogrt` |
| Images | `.psd` `.tiff` `.exr` `.dpx` `.png` `.jpg` |

### LFS Storage

Large files are stored on Google Cloud Storage via a self-hosted
[LFS server](https://github.com/peterTNTID/lfsServer) running on Cloud Run.

**Cloning**: No special setup needed — `git clone` and `git lfs pull` work
without credentials (public reads).

**Pushing** (write access): Requires the LFS API key configured via
`git credential-store`. See the [LFS server repo](https://github.com/peterTNTID/lfsServer)
for setup instructions.

