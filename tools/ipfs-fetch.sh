#!/usr/bin/env bash
# =============================================================================
# ipfs-fetch.sh — Retrieve files via IPFS (alternative to git lfs pull)
# =============================================================================
#
# Looks up IPFS CIDs from .ipfs/manifest.jsonl and fetches file content
# via the local IPFS node or an HTTP gateway.
#
# Usage:
#   ./tools/ipfs-fetch.sh "path/to/file.wav"         # Fetch a single file
#   ./tools/ipfs-fetch.sh --all                       # Fetch all manifest files
#   ./tools/ipfs-fetch.sh --gateway https://dweb.link # Use HTTP gateway
#
# Dependencies: jq, ipfs CLI (or curl for gateway mode)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/.ipfs/manifest.jsonl"

# Source .env if it exists
[ -f "$REPO_ROOT/.env" ] && source "$REPO_ROOT/.env"

# Default gateway (overridable via --gateway or IPFS_GATEWAY env)
GATEWAY="${IPFS_GATEWAY:-http://localhost:8080}"

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
# Fetch a single file by CID
# ---------------------------------------------------------------------------
fetch_file() {
    local path="$1"
    local cid="$2"
    local lfs_oid="$3"
    local size="$4"
    local pinata_id="$5"
    local use_gateway="$6"

    local target="$REPO_ROOT/$path"

    # Create parent directory
    mkdir -p "$(dirname "$target")"

    local fetched=false
    local method=""

    # Strategy 1: Local IPFS node (fastest)
    if [ "$use_gateway" = "false" ] && command -v ipfs &>/dev/null; then
        if ipfs cat "$cid" > "$target" 2>/dev/null; then
            fetched=true
            method="local ipfs"
        fi
    fi

    # Strategy 2: Pinata gateway (if pinned and available)
    if [ "$fetched" = "false" ] && [ "$pinata_id" != "null" ] && [ -n "$pinata_id" ]; then
        local pinata_url="https://gateway.pinata.cloud/ipfs/${cid}"
        if curl -sfL "$pinata_url" -o "$target" 2>/dev/null; then
            fetched=true
            method="Pinata gateway"
        fi
    fi

    # Strategy 3: Specified or default HTTP gateway
    if [ "$fetched" = "false" ]; then
        local gateway_url="${GATEWAY}/ipfs/${cid}"
        if curl -sfL "$gateway_url" -o "$target" 2>/dev/null; then
            fetched=true
            method="gateway ${GATEWAY}"
        fi
    fi

    # Strategy 4: Public fallback gateway
    if [ "$fetched" = "false" ] && [ "$GATEWAY" != "https://dweb.link" ]; then
        local fallback_url="https://dweb.link/ipfs/${cid}"
        if curl -sfL "$fallback_url" -o "$target" 2>/dev/null; then
            fetched=true
            method="dweb.link"
        fi
    fi

    if [ "$fetched" = "false" ]; then
        error "Failed to fetch: ${path}"
        return 1
    fi

    # Verify SHA-256 integrity
    local lfs_hash="${lfs_oid#sha256:}"
    local actual_hash
    actual_hash=$(shasum -a 256 "$target" | awk '{print $1}')

    if [ "$actual_hash" = "$lfs_hash" ]; then
        echo -e "  ${GREEN}✓${NC} ${path} ($(human_size "$size")) ${DIM}via ${method}${NC}"
        return 0
    else
        error "Hash mismatch for ${path}!"
        echo "  Expected: ${lfs_hash}"
        echo "  Got:      ${actual_hash}"
        rm -f "$target"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local mode="single"
    local target_path=""
    local use_gateway=false

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --all)
                mode="all"
                shift
                ;;
            --gateway)
                use_gateway=true
                GATEWAY="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [--all | <path>] [--gateway <url>]"
                echo ""
                echo "Options:"
                echo "  --all               Fetch all files in the manifest"
                echo "  <path>              Fetch a specific file by repo path"
                echo "  --gateway <url>     Use HTTP gateway instead of local node"
                echo ""
                echo "Fetching priority:"
                echo "  1. Local IPFS node (ipfs cat)"
                echo "  2. Pinata gateway (if file is pinned)"
                echo "  3. Specified/default gateway"
                echo "  4. dweb.link (public fallback)"
                exit 0
                ;;
            *)
                target_path="$1"
                shift
                ;;
        esac
    done

    # Check manifest exists
    if [ ! -f "$MANIFEST" ] || [ ! -s "$MANIFEST" ]; then
        error "Manifest not found or empty: ${MANIFEST}"
        echo "  Run ./tools/lfs-to-ipfs.sh --all first to populate the manifest."
        exit 1
    fi

    echo ""
    echo -e "${BOLD}IPFS Fetch${NC}"
    echo "─────────────────────────────────────"

    local fetched=0
    local failed=0
    local total_size=0

    if [ "$mode" = "all" ]; then
        info "Fetching all files from manifest..."
        echo ""

        while IFS= read -r line; do
            local path cid lfs_oid size pinata_id
            path=$(echo "$line" | jq -r '.path')
            cid=$(echo "$line" | jq -r '.ipfs_cid')
            lfs_oid=$(echo "$line" | jq -r '.lfs_oid')
            size=$(echo "$line" | jq -r '.size')
            pinata_id=$(echo "$line" | jq -r '.pinata_id // "null"')

            if fetch_file "$path" "$cid" "$lfs_oid" "$size" "$pinata_id" "$use_gateway"; then
                fetched=$((fetched + 1))
                total_size=$((total_size + size))
            else
                failed=$((failed + 1))
            fi
        done < "$MANIFEST"

    else
        if [ -z "$target_path" ]; then
            error "Specify --all or a file path."
            exit 1
        fi

        # Look up in manifest
        local entry
        entry=$(jq -c "select(.path==\"${target_path}\")" "$MANIFEST" 2>/dev/null | head -1)

        if [ -z "$entry" ]; then
            error "File not in manifest: ${target_path}"
            echo "  Check available files: ./tools/show-manifest.sh"
            exit 1
        fi

        local cid lfs_oid size pinata_id
        cid=$(echo "$entry" | jq -r '.ipfs_cid')
        lfs_oid=$(echo "$entry" | jq -r '.lfs_oid')
        size=$(echo "$entry" | jq -r '.size')
        pinata_id=$(echo "$entry" | jq -r '.pinata_id // "null"')

        if fetch_file "$target_path" "$cid" "$lfs_oid" "$size" "$pinata_id" "$use_gateway"; then
            fetched=1
            total_size=$size
        else
            failed=1
        fi
    fi

    echo ""
    echo "─────────────────────────────────────"
    echo -e "${BOLD}Fetched:${NC} ${fetched} files ($(human_size "$total_size"))"
    [ "$failed" -gt 0 ] && echo -e "${RED}Failed:  ${failed}${NC}"
    echo ""
}

main "$@"
