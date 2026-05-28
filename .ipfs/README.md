# `.ipfs/` Directory

This directory contains the **IPFS manifest** — the mapping between Git LFS
object IDs and IPFS content identifiers (CIDs) for every large file in the
repository.

---

## What's Here

| File | Description |
|---|---|
| `manifest.jsonl` | JSONL file with one entry per LFS-tracked file. Each line maps a file path and LFS OID to its IPFS CID. |

---

## Manifest Format

Each line in `manifest.jsonl` is a JSON object with these fields:

```json
{
  "path": "projects/logic/9May11am/Audio Files/10 - Keys #01.wav",
  "lfs_oid": "sha256:49186c526d247603d5209adde60c1c230b0f3a253eb9a120ea31612a01238249",
  "ipfs_cid": "bafybeig5h3ylkwrn7qvp2nba6hxr4ek7m2c7kdp3txf4g9qlmea2j5rmzi",
  "size": 4540741,
  "added": "2026-05-28T09:00:00Z",
  "pinata_id": "abc123def456"
}
```

| Field | Description |
|---|---|
| `path` | Repo-relative file path |
| `lfs_oid` | Git LFS object ID (`sha256:<hex>`) — the SHA-256 hash of the file content |
| `ipfs_cid` | IPFS CIDv1 — the content identifier on the IPFS network |
| `size` | File size in bytes |
| `added` | ISO 8601 timestamp of when this entry was added |
| `pinata_id` | Pinata pin ID (if pinned to Pinata), or `null` |

---

## Quick Reference — `jq` Examples

> **Prerequisite:** Install `jq` — `brew install jq` (macOS) or
> `apt install jq` (Linux).

### Look up a file's IPFS CID

```bash
jq -r 'select(.path=="projects/logic/9May11am/Audio Files/10 - Keys #01.wav") | .ipfs_cid' .ipfs/manifest.jsonl
```

Output:

```
bafybeig5h3ylkwrn7qvp2nba6hxr4ek7m2c7kdp3txf4g9qlmea2j5rmzi
```

### Look up a file's LFS OID

```bash
jq -r 'select(.path=="projects/logic/9May11am/Audio Files/10 - Keys #01.wav") | .lfs_oid' .ipfs/manifest.jsonl
```

### Search by partial filename

```bash
jq -r 'select(.path | contains("Keys #01")) | "\(.path) → \(.ipfs_cid)"' .ipfs/manifest.jsonl
```

### List all WAV files and their sizes

```bash
jq -r 'select(.path | endswith(".wav")) | "\(.size / 1048576 | round) MB  \(.path)"' .ipfs/manifest.jsonl
```

### Count files by extension

```bash
jq -r '.path | split(".") | last' .ipfs/manifest.jsonl | sort | uniq -c | sort -rn
```

### List unpinned files (no Pinata)

```bash
jq -r 'select(.pinata_id == null) | .path' .ipfs/manifest.jsonl
```

### List pinned files

```bash
jq -r 'select(.pinata_id != null) | "\(.path) → \(.pinata_id)"' .ipfs/manifest.jsonl
```

### Export as CSV

```bash
echo "path,size,ipfs_cid"
jq -r '"\(.path),\(.size),\(.ipfs_cid)"' .ipfs/manifest.jsonl
```

---

## Retrieving a File via IPFS Gateway

Once you know a file's CID, you can download it from any IPFS gateway —
no credentials or special software required:

```bash
# Using dweb.link (Protocol Labs gateway)
CID="bafybeig5h3ylkwrn7qvp2nba6hxr4ek7m2c7kdp3txf4g9qlmea2j5rmzi"
curl "https://dweb.link/ipfs/${CID}" -o "10 - Keys #01.wav"
```

Other public gateways:

```bash
# Pinata (fastest if content is pinned there)
curl "https://gateway.pinata.cloud/ipfs/${CID}" -o file.wav

# ipfs.io
curl "https://ipfs.io/ipfs/${CID}" -o file.wav

# Cloudflare
curl "https://cloudflare-ipfs.com/ipfs/${CID}" -o file.wav
```

### One-liner: Look up CID and download

```bash
CID=$(jq -r 'select(.path | contains("Keys #01")) | .ipfs_cid' .ipfs/manifest.jsonl)
curl "https://dweb.link/ipfs/${CID}" -o "10 - Keys #01.wav"
```

---

## Full Documentation

For a deep dive into how LFS and IPFS content addressing work together —
including why some CIDs can be derived from LFS OIDs and others cannot:

📖 **[docs/LFS-IPFS-BRIDGE.md](../docs/LFS-IPFS-BRIDGE.md)**

For setup guides:

- 🔧 **[docs/IPFS-SETUP.md](../docs/IPFS-SETUP.md)** — Install and run a local
  IPFS node
- 📌 **[docs/PINATA-SETUP.md](../docs/PINATA-SETUP.md)** — Pin content to
  Pinata for 24/7 availability
