#!/usr/bin/env bash
# =============================================================================
# install-hooks.sh — Install git hooks for automatic IPFS mirroring
# =============================================================================
#
# Copies hooks from tools/hooks/ into .git/hooks/ and makes them executable.
#
# Usage:
#   ./tools/install-hooks.sh
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_SRC="$SCRIPT_DIR/hooks"
HOOKS_DST="$REPO_ROOT/.git/hooks"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}Installing Git Hooks${NC}"
echo "─────────────────────────────────────"

if [ ! -d "$HOOKS_SRC" ]; then
    echo -e "${YELLOW}⚠${NC} No hooks found at ${HOOKS_SRC}"
    exit 1
fi

mkdir -p "$HOOKS_DST"

for hook in "$HOOKS_SRC"/*; do
    local_name=$(basename "$hook")
    target="$HOOKS_DST/$local_name"

    # Backup existing hook if it's not ours
    if [ -f "$target" ] && ! grep -q "LFS_IPFS_HOOK" "$target" 2>/dev/null; then
        backup="${target}.backup.$(date +%s)"
        cp "$target" "$backup"
        echo -e "${YELLOW}⚠${NC} Backed up existing ${local_name} → $(basename "$backup")"
    fi

    cp "$hook" "$target"
    chmod +x "$target"
    echo -e "${GREEN}✓${NC} Installed ${local_name} → .git/hooks/${local_name}"
done

echo ""
echo -e "${BOLD}Hooks installed!${NC}"
echo ""
echo "  On each commit, new LFS objects will automatically be:"
echo "    1. Added to your local IPFS node"
echo "    2. Recorded in .ipfs/manifest.jsonl"

if [ -n "${PINATA_JWT:-}" ]; then
    echo "    3. Pinned to Pinata (PINATA_JWT detected)"
else
    echo ""
    echo "  To also pin to Pinata, set PINATA_JWT:"
    echo "    export PINATA_JWT=\"your-jwt-here\""
fi

echo ""
echo "  Prerequisites:"
echo "    • IPFS daemon running: ipfs daemon &"
echo "    • jq installed: brew install jq (macOS)"
echo ""
