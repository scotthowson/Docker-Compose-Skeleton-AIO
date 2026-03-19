#!/bin/bash
# =============================================================================
# Docker Compose Skeleton - Restart Script
# Convenience wrapper: runs stop.sh followed by start.sh
# =============================================================================

# =============================================================================
# PATH AUTO-DETECTION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SCRIPT_DIR"
export BASE_DIR

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

SHOW_HELP=false
STOP_ARGS=()
START_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)        SHOW_HELP=true; shift ;;
        --force|-f)       STOP_ARGS+=("$1"); shift ;;   # --force only applies to stop
        --debug|-d)       STOP_ARGS+=("$1"); START_ARGS+=("$1"); shift ;;
        *)                STOP_ARGS+=("$1"); START_ARGS+=("$1"); shift ;;
    esac
done

if [[ "$SHOW_HELP" == "true" ]]; then
    cat <<EOF
Docker Compose Skeleton - Restart

Usage: ./restart.sh [OPTIONS]

Convenience script that runs stop.sh followed by start.sh.
All arguments (except --help) are passed through to both scripts.

OPTIONS:
  --help, -h     Show this help message and exit
  --debug, -d    Passed through to stop.sh and start.sh
  --force, -f    Force stop with shorter timeout (passed to stop.sh only)

EXAMPLES:
  ./restart.sh              # Normal restart
  ./restart.sh --debug      # Restart with debug logging
  ./restart.sh --force      # Force stop, then normal start

EOF
    exit 0
fi

# =============================================================================
# SIMPLE COLOR OUTPUT (lightweight, no logger dependency)
# =============================================================================

if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
    C_BOLD="$(tput bold 2>/dev/null || true)"
    C_CYAN="$(tput setaf 51 2>/dev/null || tput setaf 6 2>/dev/null || true)"
    C_GREEN="$(tput setaf 82 2>/dev/null || tput setaf 2 2>/dev/null || true)"
    C_RED="$(tput setaf 124 2>/dev/null || tput setaf 1 2>/dev/null || true)"
    C_RESET="$(tput sgr0 2>/dev/null || true)"
else
    C_BOLD="" C_CYAN="" C_GREEN="" C_RED="" C_RESET=""
fi

# =============================================================================
# EXECUTION
# =============================================================================

echo ""
echo -e "${C_BOLD}${C_CYAN}=== Docker Compose Skeleton -- Restart ===${C_RESET}"
echo ""

# --- Phase 1: Stop ---

echo -e "${C_BOLD}>>> Phase 1: Stopping services...${C_RESET}"
echo ""

if "$BASE_DIR/stop.sh" "${STOP_ARGS[@]}"; then
    echo ""
    echo -e "${C_GREEN}>>> Stop phase completed successfully${C_RESET}"
else
    echo ""
    echo -e "${C_RED}>>> Stop phase encountered errors (continuing to start)${C_RESET}"
fi

echo ""

# --- Phase 2: Start ---

echo -e "${C_BOLD}>>> Phase 2: Starting services...${C_RESET}"
echo ""

if "$BASE_DIR/start.sh" "${START_ARGS[@]}"; then
    echo ""
    echo -e "${C_GREEN}>>> Start phase completed successfully${C_RESET}"
else
    echo ""
    echo -e "${C_RED}>>> Start phase encountered errors${C_RESET}"
    exit 1
fi

echo ""
echo -e "${C_BOLD}${C_GREEN}=== Restart Complete ===${C_RESET}"
echo ""
