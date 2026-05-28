#!/usr/bin/env bash
# =============================================================================
# lfs-to-ipfs.sh — Bridge Git LFS objects to IPFS
# =============================================================================
#
# Reads LFS pointer files, resolves actual content from .git/lfs/objects/,
# adds to IPFS via local Kubo node, and updates .ipfs/manifest.jsonl.
#
# If PINATA_JWT is set, also pins to Pinata after the local IPFS add.
#
# Usage:
#   ./tools/lfs-to-ipfs.sh --all              # Add all LFS files to IPFS
#   ./tools/lfs-to-ipfs.sh --new-only         # Only files not in manifest
#   ./tools/lfs-to-ipfs.sh "path/to/*.wav"    # Specific files/globs
#   ./tools/lfs-to-ipfs.sh --dry-run --all    # Show what would be added
#
# Environment:
#   PINATA_JWT      — (Optional) Pinata JWT for pinning
#   IPFS_API        — (Optional) IPFS API endpoint (default: localhost:5001)
#
# Dependencies: jq, ipfs CLI, curl (for Pinata)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/.ipfs/manifest.jsonl"
IPFS_API="${IPFS_API:-http://localhost:5001}"

# Source .env if it exists
[ -f "$REPO_ROOT/.env" ] && source "$REPO_ROOT/.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "${BLUE}ℹ${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
error()   { echo -e "${RED}✗${NC} $*" >&2; }

# ---------------------------------------------------------------------------
# Check dependencies
# ---------------------------------------------------------------------------
check_deps() {
    local missing=()
    command -v jq &>/dev/null    || missing+=("jq")
    command -v ipfs &>/dev/null  || missing+=("ipfs (Kubo)")

    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing dependencies: ${missing[*]}"
        echo "  Install with: ./tools/setup-ipfs.sh"
        [ "jq" = "${missing[0]:-}" ] && echo "  Install jq:  brew install jq (macOS) or sudo apt install jq (Linux)"
        exit 1
    fi

    # Check IPFS daemon
    if ! ipfs swarm peers &>/dev/null 2>&1; then
        error "IPFS daemon is not running."
        echo ""
        echo "  Start it with:  ipfs daemon &"
        echo "  Or run:         ./tools/setup-ipfs.sh"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Ensure manifest directory and file exist
# ---------------------------------------------------------------------------
ensure_manifest() {
    mkdir -p "$(dirname "$MANIFEST")"
    touch "$MANIFEST"
}

# ---------------------------------------------------------------------------
# Check if an OID is already in the manifest
# ---------------------------------------------------------------------------
in_manifest() {
    local oid="$1"
    grep -q "\"lfs_oid\":\"${oid}\"" "$MANIFEST" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Resolve LFS object path from OID
# ---------------------------------------------------------------------------
lfs_object_path() {
    local oid="$1"
    # Strip 'sha256:' prefix if present
    oid="${oid#sha256:}"
    local prefix1="${oid:0:2}"
    local prefix2="${oid:2:2}"
    echo "$REPO_ROOT/.git/lfs/objects/${prefix1}/${prefix2}/${oid}"
}

# ---------------------------------------------------------------------------
# Pin to Pinata (by hash — cheaper, uses existing IPFS content)
# ---------------------------------------------------------------------------
pinata_pin_by_hash() {
    local cid="$1"
    local name="$2"

    if [ -z "${PINATA_JWT:-}" ]; then
        echo "null"
        return
    fi

    local response
    response=$(curl -s -X POST "https://api.pinata.cloud/pinning/pinByHash" \
        -H "Authorization: Bearer ${PINATA_JWT}" \
        -H "Content-Type: application/json" \
        -d "{\"hashToPin\":\"${cid}\",\"pinataMetadata\":{\"name\":\"${name}\"}}" \
        2>/dev/null) || true

    local pin_id
    pin_id=$(echo "$response" | jq -r '.id // empty' 2>/dev/null) || true

    if [ -n "$pin_id" ] && [ "$pin_id" != "null" ]; then
        echo "$pin_id"
    else
        # Try upload as fallback
        pinata_pin_upload "$cid" "$name"
    fi
}

# ---------------------------------------------------------------------------
# Pin to Pinata (upload file — fallback when content not yet on network)
# ---------------------------------------------------------------------------
pinata_pin_upload() {
    local cid="$1"
    local name="$2"

    # We need the actual file for upload. Find it via the manifest's path.
    local file_path
    file_path=$(jq -r "select(.ipfs_cid==\"${cid}\") | .path" "$MANIFEST" 2>/dev/null | head -1)

    if [ -z "$file_path" ] || [ ! -f "$REPO_ROOT/$file_path" ]; then
        echo "null"
        return
    fi

    local response
    response=$(curl -s -X POST "https://api.pinata.cloud/pinning/pinFileToIPFS" \
        -H "Authorization: Bearer ${PINATA_JWT}" \
        -F "file=@${REPO_ROOT}/${file_path}" \
        -F "pinataMetadata={\"name\":\"${name}\"}" \
        2>/dev/null) || true

    local ipfs_hash
    ipfs_hash=$(echo "$response" | jq -r '.IpfsHash // empty' 2>/dev/null) || true

    if [ -n "$ipfs_hash" ]; then
        # Return the pin ID (Pinata uses IpfsHash as identifier)
        echo "$ipfs_hash"
    else
        echo "null"
    fi
}

# ---------------------------------------------------------------------------
# Format file size for display
# ---------------------------------------------------------------------------
human_size() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        echo "$(echo "scale=1; $bytes / 1073741824" | bc) GB"
    elif [ "$bytes" -ge 1048576 ]; then
        echo "$(echo "scale=1; $bytes / 1048576" | bc) MB"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$(echo "scale=1; $bytes / 1024" | bc) KB"
    else
        echo "${bytes} B"
    fi
}

# ---------------------------------------------------------------------------
# Process a single LFS file
# ---------------------------------------------------------------------------
process_file() {
    local oid="$1"
    local path="$2"
    local size="$3"
    local dry_run="${4:-false}"

    local full_oid="sha256:${oid}"

    if [ "$dry_run" = "true" ]; then
        echo -e "  ${DIM}Would add:${NC} ${path} ($(human_size "$size"))"
        return 0
    fi

    # Resolve LFS object
    local obj_path
    obj_path=$(lfs_object_path "$oid")

    if [ ! -f "$obj_path" ]; then
        warn "LFS object not local: ${path} (run 'git lfs pull' first)"
        return 1
    fi

    # Add to IPFS
    local ipfs_output
    ipfs_output=$(ipfs add --cid-version=1 --raw-leaves --pin=true --quieter "$obj_path" 2>/dev/null)
    local cid="$ipfs_output"

    if [ -z "$cid" ]; then
        error "Failed to add to IPFS: ${path}"
        return 1
    fi

    # Pin to Pinata (if configured)
    local pinata_id="null"
    if [ -n "${PINATA_JWT:-}" ]; then
        local basename
        basename=$(basename "$path")

        # Write the manifest entry first so pinata_pin_upload can find the path
        local timestamp
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        echo "{\"path\":\"${path}\",\"lfs_oid\":\"${full_oid}\",\"ipfs_cid\":\"${cid}\",\"size\":${size},\"added\":\"${timestamp}\",\"pinata_id\":null}" >> "$MANIFEST"

        pinata_id=$(pinata_pin_by_hash "$cid" "$basename")

        # Update the manifest entry with pinata_id if we got one
        if [ "$pinata_id" != "null" ] && [ -n "$pinata_id" ]; then
            # Use a temp file to update the last entry
            local tmpfile
            tmpfile=$(mktemp)
            # Replace the null pinata_id in the entry we just wrote
            sed "s|\"ipfs_cid\":\"${cid}\",\"size\":${size},\"added\":\"${timestamp}\",\"pinata_id\":null|\"ipfs_cid\":\"${cid}\",\"size\":${size},\"added\":\"${timestamp}\",\"pinata_id\":\"${pinata_id}\"|" "$MANIFEST" > "$tmpfile"
            mv "$tmpfile" "$MANIFEST"
        fi
    else
        # No Pinata — just write the manifest entry
        local timestamp
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        echo "{\"path\":\"${path}\",\"lfs_oid\":\"${full_oid}\",\"ipfs_cid\":\"${cid}\",\"size\":${size},\"added\":\"${timestamp}\",\"pinata_id\":null}" >> "$MANIFEST"
    fi

    # Display result
    local pinata_status=""
    if [ -n "${PINATA_JWT:-}" ]; then
        if [ "$pinata_id" != "null" ] && [ -n "$pinata_id" ]; then
            pinata_status=" ${GREEN}📌 Pinata${NC}"
        else
            pinata_status=" ${YELLOW}📌 Pinata failed${NC}"
        fi
    fi

    echo -e "  ${GREEN}✓${NC} ${path} → ${DIM}${cid:0:20}...${NC} ($(human_size "$size"))${pinata_status}"
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local mode="glob"
    local pattern=""
    local dry_run=false
    local new_only=false

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --all)      mode="all"; shift ;;
            --new-only) new_only=true; shift ;;
            --dry-run)  dry_run=true; shift ;;
            --help|-h)
                echo "Usage: $0 [--all | --new-only | <glob>] [--dry-run]"
                echo ""
                echo "Options:"
                echo "  --all       Add all LFS-tracked files"
                echo "  --new-only  Only add files not yet in the manifest"
                echo "  --dry-run   Show what would be added without doing it"
                echo "  <glob>      Add files matching a glob pattern"
                echo ""
                echo "Environment:"
                echo "  PINATA_JWT  Set to enable Pinata pinning"
                exit 0
                ;;
            *)
                mode="glob"
                pattern="$1"
                shift
                ;;
        esac
    done

    if [ "$mode" = "glob" ] && [ -z "$pattern" ]; then
        error "Specify --all, --new-only, or a file pattern."
        echo "  Usage: $0 [--all | --new-only | <glob>] [--dry-run]"
        exit 1
    fi

    # Pre-flight checks (skip for dry-run — it's informational)
    if [ "$dry_run" = "false" ]; then
        check_deps
    fi

    ensure_manifest

    echo ""
    echo -e "${BOLD}LFS → IPFS Bridge${NC}"
    echo "─────────────────────────────────────"

    if [ "$dry_run" = "true" ]; then
        echo -e "${YELLOW}DRY RUN — no changes will be made${NC}"
    fi

    if [ -n "${PINATA_JWT:-}" ]; then
        info "Pinata JWT detected — will pin to Pinata after IPFS add"
    else
        info "No PINATA_JWT — files will be added to local IPFS only"
    fi

    echo ""

    # Enumerate LFS files
    local count=0
    local added=0
    local skipped=0
    local failed=0
    local total_size=0

    cd "$REPO_ROOT"

    while IFS= read -r line; do
        # Parse: <oid> <status> <path>
        # Format from git lfs ls-files --long:
        # <64-char-oid> <*|-> <path>
        local oid status path

        oid=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $2}')
        path=$(echo "$line" | sed 's/^[a-f0-9]* [*-] //')

        # Get size from pointer file
        local size
        size=$(git show "HEAD:${path}" 2>/dev/null | grep '^size ' | awk '{print $2}') || size=0

        # Filter by glob pattern
        if [ "$mode" = "glob" ]; then
            # shellcheck disable=SC2254
            case "$path" in
                $pattern) ;; # Match
                *) continue ;;
            esac
        fi

        # Skip if already in manifest (when --new-only or default behavior)
        if [ "$new_only" = "true" ] || [ "$mode" != "all" -a "$mode" != "glob" ]; then
            if in_manifest "sha256:${oid}"; then
                skipped=$((skipped + 1))
                continue
            fi
        fi

        # Skip if already in manifest (even in --all mode, don't create duplicates)
        if in_manifest "sha256:${oid}"; then
            skipped=$((skipped + 1))
            continue
        fi

        count=$((count + 1))
        total_size=$((total_size + size))

        if process_file "$oid" "$path" "$size" "$dry_run"; then
            added=$((added + 1))
        else
            failed=$((failed + 1))
        fi

    done < <(git lfs ls-files --long 2>/dev/null)

    # Summary
    echo ""
    echo "─────────────────────────────────────"
    if [ "$dry_run" = "true" ]; then
        echo -e "${BOLD}Would add:${NC} ${count} files ($(human_size "$total_size"))"
    else
        echo -e "${BOLD}Added:${NC}   ${added} files ($(human_size "$total_size"))"
    fi
    [ "$skipped" -gt 0 ] && echo -e "${DIM}Skipped: ${skipped} (already in manifest)${NC}"
    [ "$failed" -gt 0 ]  && echo -e "${RED}Failed:  ${failed}${NC}"
    echo ""
}

main "$@"
