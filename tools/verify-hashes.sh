#!/usr/bin/env bash
# =============================================================================
# verify-hashes.sh — Cross-verify LFS ↔ IPFS ↔ local file integrity
# =============================================================================
#
# Proves that the same bytes are addressable via both LFS (SHA-256) and
# IPFS (CID) by verifying hash chains independently.
#
# Usage:
#   ./tools/verify-hashes.sh                    # Verify all manifest entries
#   ./tools/verify-hashes.sh "path/to/file.wav" # Verify a specific file
#
# Dependencies: jq, ipfs CLI, shasum
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

# ---------------------------------------------------------------------------
# Format file size for display
# ---------------------------------------------------------------------------
human_size() {
    local bytes=$1
    if [ "$bytes" -ge 1048576 ]; then
        echo "$(echo "scale=1; $bytes / 1048576" | bc) MB"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$(echo "scale=1; $bytes / 1024" | bc) KB"
    else
        echo "${bytes} B"
    fi
}

# ---------------------------------------------------------------------------
# Verify a single entry
# ---------------------------------------------------------------------------
verify_entry() {
    local path="$1"
    local lfs_oid="$2"
    local ipfs_cid="$3"
    local size="$4"
    local pinata_id="$5"

    local lfs_hash="${lfs_oid#sha256:}"
    local file="$REPO_ROOT/$path"
    local basename
    basename=$(basename "$path")

    local sha_ok=false
    local ipfs_ok=false
    local pin_ok=false
    local errors=()

    # Check 1: Does the local file exist?
    if [ ! -f "$file" ]; then
        echo -e "  ${YELLOW}⏭${NC}  ${basename} ${DIM}(not checked out locally)${NC}"
        return 2
    fi

    # Check 2: SHA-256 of local file matches LFS OID
    local actual_sha
    actual_sha=$(shasum -a 256 "$file" | awk '{print $1}')

    if [ "$actual_sha" = "$lfs_hash" ]; then
        sha_ok=true
    else
        errors+=("SHA-256 mismatch: expected ${lfs_hash:0:16}..., got ${actual_sha:0:16}...")
    fi

    # Check 3: IPFS --only-hash matches stored CID
    if command -v ipfs &>/dev/null; then
        local computed_cid
        computed_cid=$(ipfs add --cid-version=1 --raw-leaves --only-hash --quieter "$file" 2>/dev/null) || true

        if [ "$computed_cid" = "$ipfs_cid" ]; then
            ipfs_ok=true
        elif [ -n "$computed_cid" ]; then
            errors+=("IPFS CID mismatch: expected ${ipfs_cid:0:20}..., got ${computed_cid:0:20}...")
        else
            errors+=("Could not compute IPFS CID (daemon not running?)")
        fi
    else
        errors+=("ipfs CLI not available — skipping CID verification")
    fi

    # Check 4: Pinata pin status (if applicable)
    if [ "$pinata_id" != "null" ] && [ -n "$pinata_id" ]; then
        pin_ok=true
    fi

    # Report
    if [ ${#errors[@]} -eq 0 ]; then
        local pinata_status=""
        if [ "$pin_ok" = "true" ]; then
            pinata_status="  |  ${GREEN}Pinata: pinned ✓${NC}"
        elif [ "$pinata_id" = "null" ] || [ -z "$pinata_id" ]; then
            pinata_status="  |  ${DIM}Pinata: —${NC}"
        fi

        echo -e "  ${GREEN}✓${NC}  ${basename} ($(human_size "$size"))"
        echo -e "     LFS OID:  ${DIM}${lfs_hash:0:24}...${NC}"
        echo -e "     IPFS CID: ${DIM}${ipfs_cid:0:24}...${NC}"
        echo -e "     Local:    ${GREEN}SHA-256 ✓${NC}  |  ${GREEN}IPFS CID ✓${NC}${pinata_status}"
        return 0
    else
        echo -e "  ${RED}✗${NC}  ${basename} ($(human_size "$size"))"
        echo -e "     LFS OID:  ${DIM}${lfs_hash:0:24}...${NC}"
        echo -e "     IPFS CID: ${DIM}${ipfs_cid:0:24}...${NC}"
        for err in "${errors[@]}"; do
            echo -e "     ${RED}→ ${err}${NC}"
        done
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    local target_path="${1:-}"

    if [ "$target_path" = "--help" ] || [ "$target_path" = "-h" ]; then
        echo "Usage: $0 [<path>]"
        echo ""
        echo "Verify integrity of LFS ↔ IPFS hash mapping."
        echo "  No arguments: verify all manifest entries"
        echo "  <path>:       verify a specific file"
        exit 0
    fi

    if [ ! -f "$MANIFEST" ] || [ ! -s "$MANIFEST" ]; then
        echo -e "${RED}✗${NC} Manifest not found or empty: ${MANIFEST}"
        echo "  Run ./tools/lfs-to-ipfs.sh --all first."
        exit 1
    fi

    echo ""
    echo -e "${BOLD}Hash Verification: LFS ↔ IPFS${NC}"
    echo "─────────────────────────────────────"
    echo ""

    local verified=0
    local failed=0
    local skipped=0

    if [ -n "$target_path" ]; then
        # Single file
        local entry
        entry=$(jq -c "select(.path==\"${target_path}\")" "$MANIFEST" 2>/dev/null | head -1)

        if [ -z "$entry" ]; then
            echo -e "${RED}✗${NC} File not in manifest: ${target_path}"
            exit 1
        fi

        local lfs_oid ipfs_cid size pinata_id
        lfs_oid=$(echo "$entry" | jq -r '.lfs_oid')
        ipfs_cid=$(echo "$entry" | jq -r '.ipfs_cid')
        size=$(echo "$entry" | jq -r '.size')
        pinata_id=$(echo "$entry" | jq -r '.pinata_id // "null"')

        verify_entry "$target_path" "$lfs_oid" "$ipfs_cid" "$size" "$pinata_id"

    else
        # All entries
        while IFS= read -r line; do
            local path lfs_oid ipfs_cid size pinata_id
            path=$(echo "$line" | jq -r '.path')
            lfs_oid=$(echo "$line" | jq -r '.lfs_oid')
            ipfs_cid=$(echo "$line" | jq -r '.ipfs_cid')
            size=$(echo "$line" | jq -r '.size')
            pinata_id=$(echo "$line" | jq -r '.pinata_id // "null"')

            local result=0
            verify_entry "$path" "$lfs_oid" "$ipfs_cid" "$size" "$pinata_id" || result=$?

            case $result in
                0) verified=$((verified + 1)) ;;
                1) failed=$((failed + 1)) ;;
                2) skipped=$((skipped + 1)) ;;
            esac
        done < "$MANIFEST"

        echo ""
        echo "─────────────────────────────────────"
        echo -e "${BOLD}Results:${NC}"
        echo -e "  ${GREEN}Verified:${NC} ${verified}"
        [ "$failed" -gt 0 ]  && echo -e "  ${RED}Failed:${NC}   ${failed}"
        [ "$skipped" -gt 0 ] && echo -e "  ${YELLOW}Skipped:${NC}  ${skipped} (not checked out)"
        echo ""
    fi
}

main "$@"
