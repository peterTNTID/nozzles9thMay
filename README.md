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

---

## IPFS Mirroring

Every LFS-tracked file is also addressable via **IPFS**, creating a dual
content-addressed storage layer. The hash mapping between LFS and IPFS is
tracked in [`.ipfs/manifest.jsonl`](.ipfs/manifest.jsonl).

### Why LFS + IPFS?

| LFS (centralized) | IPFS (decentralized) |
|---|---|
| Fast, reliable via GCS | Available from any IPFS node or gateway |
| Requires the LFS server to be up | Works peer-to-peer, no single server |
| Access controlled by credentials | Content-addressed — anyone with the CID can fetch |
| One storage provider | Pin to multiple providers (Pinata, etc.) for redundancy |

### How the hash mapping works

Both Git LFS and IPFS use **SHA-256** internally, but wrap the hash differently:

```
LFS pointer file:
  oid sha256:a339c6e003371bf38de9b111b3cbc66130165dda0f6e4b0c03400bbc82f0b38e
                     └── raw SHA-256 hex digest ──────────────────────────────┘

IPFS CIDv1:
  bafkrei...
  └── base32( 0x01 version │ 0x55 raw codec │ 0x12 sha256 │ 0x20 length │ <digest> )
```

For files ≤ 256 KiB, the CID is a deterministic transformation of the LFS hash.
For larger files, IPFS chunks the data into a Merkle DAG — see
[docs/LFS-IPFS-BRIDGE.md](docs/LFS-IPFS-BRIDGE.md) for the full explanation.

### Quick Start

```bash
# 1. Install IPFS (Kubo)
./tools/setup-ipfs.sh

# 2. Install the git hook (auto-mirrors new files on commit)
./tools/install-hooks.sh

# 3. Mirror all existing LFS files to IPFS
./tools/lfs-to-ipfs.sh --all

# 4. View the hash manifest
./tools/show-manifest.sh

# 5. Verify integrity
./tools/verify-hashes.sh
```

### Retrieving files via IPFS

As an alternative to `git lfs pull`, you can fetch files from IPFS:

```bash
# Fetch a single file
./tools/ipfs-fetch.sh "projects/logic/9May11am/Audio Files/10 - Keys #01.wav"

# Fetch all files
./tools/ipfs-fetch.sh --all

# Fetch via a public gateway (no local IPFS node needed)
./tools/ipfs-fetch.sh --gateway https://dweb.link --all
```

### How it works (without Pinata)

Files are added to your **local IPFS node** and the mapping is recorded
in the manifest. Files are available on the IPFS network while your
node is online.

```
commit → post-commit hook → ipfs add → manifest updated → sync to LFS server
```

The LFS server also acts as an **IPFS HTTP Gateway** — after syncing the
manifest, anyone can fetch files by CID:

```
https://lfs-server-183374654452.australia-southeast1.run.app/ipfs/<cid>
```

No additional infrastructure — the same Cloud Run service that handles LFS
also resolves CIDs to GCS signed URLs.

### How it works (with Pinata)

When `PINATA_JWT` is set, files are additionally **pinned to Pinata** for
persistent availability — they stay on IPFS even when your node is offline.

```bash
# Set your Pinata JWT (see docs/PINATA-SETUP.md)
export PINATA_JWT="your-jwt-here"

# Pin everything
./tools/pinata-pin.sh --all

# Check status
./tools/pinata-pin.sh --status
```

See [docs/PINATA-SETUP.md](docs/PINATA-SETUP.md) for setup details.

### Tools reference

| Script | Purpose |
|--------|---------|
| `tools/setup-ipfs.sh` | Install Kubo + initialize IPFS |
| `tools/install-hooks.sh` | Install the post-commit hook |
| `tools/lfs-to-ipfs.sh` | Add LFS objects to IPFS |
| `tools/ipfs-fetch.sh` | Retrieve files via IPFS |
| `tools/verify-hashes.sh` | Cross-verify LFS ↔ IPFS integrity |
| `tools/show-manifest.sh` | Pretty-print the hash manifest |
| `tools/sync-manifest.sh` | Push manifest to LFS server gateway |
| `tools/pinata-pin.sh` | Pin to Pinata (optional) |

### Learn more

- [docs/LFS-IPFS-BRIDGE.md](docs/LFS-IPFS-BRIDGE.md) — Deep dive into how
  LFS and IPFS content addressing relate
- [docs/IPFS-SETUP.md](docs/IPFS-SETUP.md) — IPFS node setup guide
- [docs/PINATA-SETUP.md](docs/PINATA-SETUP.md) — Pinata pinning setup
