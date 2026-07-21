#!/usr/bin/env bash
# =============================================================================
# hash-manifest.sh — Complete the IPFS manifest by computing CIDs (hash-only)
# =============================================================================
#
# Computes IPFS CIDs for all LFS-tracked files using `ipfs add --only-hash`.
# No IPFS daemon required. No upload. No pinning. Pure local hash computation.
#
# Reads LFS pointer files, resolves actual content from .git/lfs/objects/,
# computes the CID without adding to IPFS, and appends to .ipfs/manifest.jsonl.
#
# Usage:
#   ./tools/hash-manifest.sh                # Hash all files missing from manifest
#   ./tools/hash-manifest.sh --all          # Same as default (idempotent)
#   ./tools/hash-manifest.sh --dry-run      # Show what would be hashed
#   ./tools/hash-manifest.sh "path/to/*.wav" # Specific files/globs
#
# Dependencies: jq, ipfs CLI (for --only-hash, no daemon needed)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/.ipfs/manifest.jsonl"

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
# Check dependencies (no daemon required — only the CLI for --only-hash)
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

    # NOTE: No daemon check — --only-hash works offline
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
# Process a single LFS file — compute CID via --only-hash (no upload)
# ---------------------------------------------------------------------------
process_file() {
    local oid="$1"
    local path="$2"
    local size="$3"
    local dry_run="${4:-false}"

    local full_oid="sha256:${oid}"

    if [ "$dry_run" = "true" ]; then
        echo -e "  ${DIM}Would hash:${NC} ${path} ($(human_size "$size"))"
        return 0
    fi

    # Resolve LFS object
    local obj_path
    obj_path=$(lfs_object_path "$oid")

    if [ ! -f "$obj_path" ]; then
        warn "LFS object not local: ${path} (run 'git lfs pull' first)"
        return 1
    fi

    # Compute CID via --only-hash (no daemon, no upload, no pinning)
    local cid
    cid=$(ipfs add --cid-version=1 --raw-leaves --only-hash --quieter "$obj_path" 2>/dev/null)

    if [ -z "$cid" ]; then
        error "Failed to compute CID: ${path}"
        return 1
    fi

    # Write the manifest entry (pinata_id is always null — no pinning)
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "{\"path\":\"${path}\",\"lfs_oid\":\"${full_oid}\",\"ipfs_cid\":\"${cid}\",\"size\":${size},\"added\":\"${timestamp}\",\"pinata_id\":null}" >> "$MANIFEST"

    echo -e "  ${GREEN}✓${NC} ${path} → ${DIM}${cid:0:20}...${NC} ($(human_size "$size"))"
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local mode="all"
    local pattern=""
    local dry_run=false

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --all)      mode="all"; shift ;;
            --dry-run)  dry_run=true; shift ;;
            --help|-h)
                echo "Usage: $0 [--all | <glob>] [--dry-run]"
                echo ""
                echo "Compute IPFS CIDs for LFS files and update the manifest."
                echo "No IPFS daemon required. No upload. No pinning."
                echo ""
                echo "Options:"
                echo "  --all       Hash all LFS files missing from manifest (default)"
                echo "  --dry-run   Show what would be hashed without doing it"
                echo "  <glob>      Hash files matching a glob pattern"
                echo ""
                echo "Dependencies:"
                echo "  jq, ipfs CLI (no daemon needed — uses --only-hash)"
                exit 0
                ;;
            *)
                mode="glob"
                pattern="$1"
                shift
                ;;
        esac
    done

    # Pre-flight checks (skip for dry-run — it's informational)
    if [ "$dry_run" = "false" ]; then
        check_deps
    fi

    ensure_manifest

    echo ""
    echo -e "${BOLD}Hash-Only Manifest Completion${NC}"
    echo "─────────────────────────────────────"
    info "No upload, no pinning — pure local hash computation"
    info "Using: ipfs add --cid-version=1 --raw-leaves --only-hash"
    echo ""

    if [ "$dry_run" = "true" ]; then
        echo -e "${YELLOW}DRY RUN — no changes will be made${NC}"
        echo ""
    fi

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

        # Skip if already in manifest (don't create duplicates)
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
        echo -e "${BOLD}Would hash:${NC} ${count} files ($(human_size "$total_size"))"
    else
        echo -e "${BOLD}Hashed:${NC}   ${added} files ($(human_size "$total_size"))"
    fi
    [ "$skipped" -gt 0 ] && echo -e "${DIM}Skipped: ${skipped} (already in manifest)${NC}"
    [ "$failed" -gt 0 ]  && echo -e "${RED}Failed:  ${failed}${NC}"

    # Show manifest total
    local manifest_count
    manifest_count=$(wc -l < "$MANIFEST" | tr -d ' ')
    echo -e "${BOLD}Manifest total:${NC} ${manifest_count} entries"

    if [ "$failed" -gt 0 ]; then
        echo ""
        warn "${failed} files could not be hashed (LFS objects not pulled locally)."
        echo "  Run: git lfs pull"
        echo "  Then re-run: ./tools/hash-manifest.sh"
    fi
    echo ""
}

main "$@"