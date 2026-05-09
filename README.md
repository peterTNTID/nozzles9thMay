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

All audio, video, and DAW/NLE project files are tracked by Git LFS automatically via `.gitattributes`. Just commit normally — Git LFS handles the rest.

### Tracked file types

| Category | Extensions |
|----------|-----------|
| Audio | `.wav` `.aif` `.aiff` `.flac` `.mp3` `.ogg` `.m4a` `.caf` |
| Video | `.mov` `.mp4` `.avi` `.mkv` `.mxf` `.r3d` `.braw` `.prores` |
| Logic Pro | `.logicx` |
| Pro Tools | `.ptx` `.ptf` `.pts` |
| Ableton | `.als` `.alp` `.adg` `.adv` `.alc` |
| Final Cut | `.fcpbundle` `.fcpxml` `.fcpproject` |
| Premiere | `.prproj` `.mogrt` |
| Images | `.psd` `.tiff` `.exr` `.dpx` `.png` `.jpg` |
