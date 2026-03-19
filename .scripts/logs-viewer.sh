#!/bin/bash
# =============================================================================
# Docker Compose Skeleton — Log Viewer
# Quick access to service logs with formatting, filtering, and color coding
#
# Usage:
#   ./logs-viewer.sh                   Show last 50 lines of the main log
#   ./logs-viewer.sh --follow          Tail the log in real-time
#   ./logs-viewer.sh --errors          Show only ERROR/CRITICAL lines
#   ./logs-viewer.sh --warnings        Show only WARNING/CAUTION lines
#   ./logs-viewer.sh --today           Show only today's log entries
#   ./logs-viewer.sh --search "term"   Search log for a keyword
#   ./logs-viewer.sh --archives        List archived log files
#   ./logs-viewer.sh --stats           Show log file statistics
#   ./logs-viewer.sh --lines N         Show last N lines (default: 50)
#   ./logs-viewer.sh --help            Show usage information
#
# Supports multiple flags combined (e.g., --today --errors)
#
# Dependencies:
#   $BASE_DIR or $LOG_FILE should be set, or the script auto-detects
# =============================================================================

# =============================================================================
# PATH AUTO-DETECTION
# =============================================================================

if [[ -z "${BASE_DIR:-}" ]]; then
    _LV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BASE_DIR="$(cd "$_LV_SCRIPT_DIR/.." && pwd)"
    unset _LV_SCRIPT_DIR
fi

# Determine log file and directories
LOG_DIR="${LOG_DIR:-${BASE_DIR}/logs}"
LOG_FILE="${LOG_FILE:-${LOG_DIR}/docker-services.log}"
LOG_BACKUP_DIR="${LOG_BACKUP_DIR:-${LOG_DIR}/archive}"

# =============================================================================
# COLOR SETUP
# =============================================================================

if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
    _LV_COLORS=true
    _LV_RESET="$(tput sgr0)"
    _LV_BOLD="$(tput bold)"
    _LV_DIM="$(tput dim)"
    _LV_RED="$(tput setaf 196 2>/dev/null || tput setaf 1)"
    _LV_YELLOW="$(tput setaf 214 2>/dev/null || tput setaf 3)"
    _LV_GREEN="$(tput setaf 82 2>/dev/null || tput setaf 2)"
    _LV_CYAN="$(tput setaf 51 2>/dev/null || tput setaf 6)"
    _LV_BLUE="$(tput setaf 33 2>/dev/null || tput setaf 4)"
    _LV_MAGENTA="$(tput setaf 141 2>/dev/null || tput setaf 5)"
    _LV_GRAY="$(tput setaf 245 2>/dev/null || tput setaf 7)"
    _LV_WHITE="$(tput setaf 15 2>/dev/null || tput setaf 7)"
    _LV_ORANGE="$(tput setaf 208 2>/dev/null || tput setaf 3)"
    _LV_PINK="$(tput setaf 200 2>/dev/null || tput setaf 5)"
else
    _LV_COLORS=false
    _LV_RESET="" _LV_BOLD="" _LV_DIM=""
    _LV_RED="" _LV_YELLOW="" _LV_GREEN="" _LV_CYAN=""
    _LV_BLUE="" _LV_MAGENTA="" _LV_GRAY="" _LV_WHITE=""
    _LV_ORANGE="" _LV_PINK=""
fi

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

_lv_repeat() {
    local char="$1"
    local count="$2"
    (( count <= 0 )) && return
    printf "%0.s${char}" $(seq 1 "$count")
}

_lv_header() {
    local title="$1"
    local width=70
    local border
    border="$(_lv_repeat "=" "$width")"

    echo ""
    echo "${_LV_BOLD}${_LV_BLUE}${border}${_LV_RESET}"
    local pad=$(( (width - ${#title}) / 2 ))
    printf "${_LV_BOLD}${_LV_CYAN}%*s%s${_LV_RESET}\n" "$pad" "" "$title"
    echo "${_LV_BOLD}${_LV_BLUE}${border}${_LV_RESET}"
    echo ""
}

# Colorize a log line based on its level indicator
_lv_colorize_line() {
    local line="$1"

    if [[ "$_LV_COLORS" != "true" ]]; then
        echo "$line"
        return
    fi

    # Match log level patterns and apply colors
    if [[ "$line" =~ \[CRITICAL\]|\[ALERT\] ]]; then
        echo "${_LV_BOLD}${_LV_RED}${line}${_LV_RESET}"
    elif [[ "$line" =~ \[ERROR\] ]]; then
        echo "${_LV_RED}${line}${_LV_RESET}"
    elif [[ "$line" =~ \[WARNING\]|\[CAUTION\] ]]; then
        echo "${_LV_YELLOW}${line}${_LV_RESET}"
    elif [[ "$line" =~ \[SUCCESS\]|\[CONFIRMATION\] ]]; then
        echo "${_LV_GREEN}${line}${_LV_RESET}"
    elif [[ "$line" =~ \[DEBUG\] ]]; then
        echo "${_LV_PINK}${line}${_LV_RESET}"
    elif [[ "$line" =~ \[STEP\ [0-9] ]]; then
        echo "${_LV_BOLD}${_LV_BLUE}${line}${_LV_RESET}"
    elif [[ "$line" =~ \[TIMING\] ]]; then
        echo "${_LV_CYAN}${line}${_LV_RESET}"
    elif [[ "$line" =~ \[INFO_HEADER\]|Docker\ Compose\ Updater ]]; then
        echo "${_LV_BOLD}${_LV_MAGENTA}${line}${_LV_RESET}"
    elif [[ "$line" =~ \[INFO\] ]]; then
        echo "${_LV_GREEN}${line}${_LV_RESET}"
    elif [[ "$line" =~ \[FOCUS\]|\[HIGHLIGHT\] ]]; then
        echo "${_LV_BLUE}${line}${_LV_RESET}"
    elif [[ "$line" =~ \[STATUS\]|\[IMPORTANT\] ]]; then
        echo "${_LV_ORANGE}${line}${_LV_RESET}"
    elif [[ "$line" =~ ^[=+\-]{3,} ]] || [[ "$line" =~ ^[|+] ]]; then
        # Table borders and separators
        echo "${_LV_DIM}${_LV_GRAY}${line}${_LV_RESET}"
    elif [[ "$line" =~ ^--- ]] || [[ "$line" =~ ^Logger\ System ]]; then
        echo "${_LV_DIM}${_LV_GRAY}${line}${_LV_RESET}"
    else
        echo "$line"
    fi
}

# Process and colorize a stream of lines
_lv_colorize_stream() {
    while IFS= read -r line; do
        _lv_colorize_line "$line"
    done
}

# Check if log file exists
_lv_check_log_file() {
    if [[ ! -f "$LOG_FILE" ]]; then
        echo "${_LV_YELLOW}Log file not found: ${LOG_FILE}${_LV_RESET}" >&2
        echo "" >&2
        echo "Possible reasons:" >&2
        echo "  - The service has not been started yet" >&2
        echo "  - LOG_FILE is set to a different path" >&2
        echo "  - The log was rotated and archived" >&2
        echo "" >&2
        echo "Check archives with: $0 --archives" >&2
        return 1
    fi
    return 0
}

# =============================================================================
# DISPLAY FUNCTIONS
# =============================================================================

# Show last N lines of the log
_lv_show_tail() {
    local num_lines="${1:-50}"

    _lv_check_log_file || return 1

    _lv_header "Log Viewer — Last ${num_lines} Lines"
    printf "  ${_LV_DIM}${_LV_GRAY}File: %s${_LV_RESET}\n" "$LOG_FILE"
    printf "  ${_LV_DIM}${_LV_GRAY}Size: %s${_LV_RESET}\n" "$(du -h "$LOG_FILE" 2>/dev/null | awk '{print $1}')"
    echo ""
    echo "${_LV_DIM}${_LV_GRAY}$(_lv_repeat "-" 70)${_LV_RESET}"
    echo ""

    tail -n "$num_lines" "$LOG_FILE" | _lv_colorize_stream
}

# Follow the log in real-time
_lv_follow() {
    _lv_check_log_file || return 1

    _lv_header "Log Viewer — Live Follow Mode"
    printf "  ${_LV_DIM}${_LV_GRAY}File: %s${_LV_RESET}\n" "$LOG_FILE"
    printf "  ${_LV_BOLD}${_LV_CYAN}Press Ctrl+C to stop${_LV_RESET}\n"
    echo ""
    echo "${_LV_DIM}${_LV_GRAY}$(_lv_repeat "-" 70)${_LV_RESET}"
    echo ""

    tail -f "$LOG_FILE" | _lv_colorize_stream
}

# Show only error/critical lines
_lv_show_errors() {
    _lv_check_log_file || return 1

    _lv_header "Log Viewer — Errors & Critical"

    local count
    count="$(grep -cE '\[(ERROR|CRITICAL|ALERT)\]' "$LOG_FILE" 2>/dev/null || echo "0")"

    if (( count == 0 )); then
        echo "  ${_LV_GREEN}No errors found in the current log.${_LV_RESET}"
        echo ""
        return 0
    fi

    printf "  ${_LV_RED}Found %s error entries${_LV_RESET}\n" "$count"
    echo ""
    echo "${_LV_DIM}${_LV_GRAY}$(_lv_repeat "-" 70)${_LV_RESET}"
    echo ""

    grep -E '\[(ERROR|CRITICAL|ALERT)\]' "$LOG_FILE" | _lv_colorize_stream
}

# Show only warning/caution lines
_lv_show_warnings() {
    _lv_check_log_file || return 1

    _lv_header "Log Viewer — Warnings & Cautions"

    local count
    count="$(grep -cE '\[(WARNING|CAUTION)\]' "$LOG_FILE" 2>/dev/null || echo "0")"

    if (( count == 0 )); then
        echo "  ${_LV_GREEN}No warnings found in the current log.${_LV_RESET}"
        echo ""
        return 0
    fi

    printf "  ${_LV_YELLOW}Found %s warning entries${_LV_RESET}\n" "$count"
    echo ""
    echo "${_LV_DIM}${_LV_GRAY}$(_lv_repeat "-" 70)${_LV_RESET}"
    echo ""

    grep -E '\[(WARNING|CAUTION)\]' "$LOG_FILE" | _lv_colorize_stream
}

# Show only today's entries
_lv_show_today() {
    _lv_check_log_file || return 1

    local today
    today="$(date '+%b/%d/%Y')"

    _lv_header "Log Viewer — Today's Entries (${today})"

    local count
    count="$(grep -c "$today" "$LOG_FILE" 2>/dev/null || echo "0")"

    if (( count == 0 )); then
        echo "  ${_LV_YELLOW}No entries found for today (${today}).${_LV_RESET}"
        echo ""
        echo "  The log date format is: ${_LV_DIM}[Mon/DD/YYYY - HH:MM AM/PM]${_LV_RESET}"
        echo ""
        return 0
    fi

    printf "  ${_LV_CYAN}Found %s entries for today${_LV_RESET}\n" "$count"
    echo ""
    echo "${_LV_DIM}${_LV_GRAY}$(_lv_repeat "-" 70)${_LV_RESET}"
    echo ""

    grep "$today" "$LOG_FILE" | _lv_colorize_stream
}

# Search for a keyword
_lv_search() {
    local keyword="$1"

    if [[ -z "$keyword" ]]; then
        echo "${_LV_RED}Error: No search term provided${_LV_RESET}" >&2
        echo "Usage: $0 --search \"keyword\"" >&2
        return 1
    fi

    _lv_check_log_file || return 1

    _lv_header "Log Viewer — Search: \"${keyword}\""

    local count
    count="$(grep -ci "$keyword" "$LOG_FILE" 2>/dev/null || echo "0")"

    if (( count == 0 )); then
        echo "  ${_LV_YELLOW}No matches found for \"${keyword}\"${_LV_RESET}"
        echo ""
        return 0
    fi

    printf "  ${_LV_CYAN}Found %s matching lines${_LV_RESET}\n" "$count"
    echo ""
    echo "${_LV_DIM}${_LV_GRAY}$(_lv_repeat "-" 70)${_LV_RESET}"
    echo ""

    # Show matches with context, highlighting the search term
    grep -i --color=never "$keyword" "$LOG_FILE" | while IFS= read -r line; do
        if [[ "$_LV_COLORS" == "true" ]]; then
            # Highlight the keyword in the line
            local highlighted
            highlighted="$(echo "$line" | sed "s/${keyword}/${_LV_BOLD}${_LV_CYAN}&${_LV_RESET}/gi")"
            _lv_colorize_line "$highlighted"
        else
            echo "$line"
        fi
    done
}

# List archived log files
_lv_show_archives() {
    _lv_header "Log Viewer — Archived Logs"

    printf "  ${_LV_DIM}${_LV_GRAY}Archive directory: %s${_LV_RESET}\n" "$LOG_BACKUP_DIR"
    echo ""

    if [[ ! -d "$LOG_BACKUP_DIR" ]]; then
        echo "  ${_LV_YELLOW}Archive directory does not exist.${_LV_RESET}"
        echo ""
        return 0
    fi

    local -a archives=()
    local entry
    while IFS= read -r entry; do
        [[ -n "$entry" ]] && archives+=("$entry")
    done < <(ls -lhtr "$LOG_BACKUP_DIR"/*.log* 2>/dev/null)

    if [[ ${#archives[@]} -eq 0 ]]; then
        echo "  ${_LV_YELLOW}No archived logs found.${_LV_RESET}"
        echo ""
        return 0
    fi

    printf "  ${_LV_CYAN}Found %d archived log files:${_LV_RESET}\n" "${#archives[@]}"
    echo ""

    # Table header
    printf "  ${_LV_BOLD}${_LV_CYAN}%-45s  %-10s  %s${_LV_RESET}\n" "FILENAME" "SIZE" "DATE"
    echo "  ${_LV_DIM}${_LV_GRAY}$(_lv_repeat "-" 70)${_LV_RESET}"

    for entry in "${archives[@]}"; do
        local filename size date_str
        # Parse ls -lh output
        filename="$(echo "$entry" | awk '{print $NF}' | xargs basename)"
        size="$(echo "$entry" | awk '{print $5}')"
        date_str="$(echo "$entry" | awk '{print $6, $7, $8}')"

        local size_color="${_LV_GREEN}"
        # Highlight large files
        if [[ "$size" =~ [0-9]+G ]] || [[ "$size" =~ [5-9][0-9]+M ]] || [[ "$size" =~ [1-9][0-9]{2,}M ]]; then
            size_color="${_LV_YELLOW}"
        fi

        printf "  ${_LV_WHITE}%-45s${_LV_RESET}  ${size_color}%-10s${_LV_RESET}  ${_LV_GRAY}%s${_LV_RESET}\n" \
            "$filename" "$size" "$date_str"
    done

    # Total size
    local total_size
    total_size="$(du -sh "$LOG_BACKUP_DIR" 2>/dev/null | awk '{print $1}')"
    echo ""
    printf "  ${_LV_DIM}${_LV_GRAY}Total archive size: %s${_LV_RESET}\n" "${total_size:-unknown}"
    echo ""
}

# Show log statistics
_lv_show_stats() {
    _lv_check_log_file || return 1

    _lv_header "Log Viewer — Statistics"

    printf "  ${_LV_DIM}${_LV_GRAY}File: %s${_LV_RESET}\n" "$LOG_FILE"
    echo ""

    local total_lines file_size
    total_lines="$(wc -l < "$LOG_FILE" 2>/dev/null || echo "0")"
    file_size="$(du -h "$LOG_FILE" 2>/dev/null | awk '{print $1}')"

    # Count by level
    local errors warnings successes infos debugs steps timings
    errors="$(grep -cE '\[(ERROR|CRITICAL|ALERT)\]' "$LOG_FILE" 2>/dev/null || echo "0")"
    warnings="$(grep -cE '\[(WARNING|CAUTION)\]' "$LOG_FILE" 2>/dev/null || echo "0")"
    successes="$(grep -cE '\[(SUCCESS|CONFIRMATION)\]' "$LOG_FILE" 2>/dev/null || echo "0")"
    infos="$(grep -cE '\[(INFO|INFO_HEADER)\]' "$LOG_FILE" 2>/dev/null || echo "0")"
    debugs="$(grep -cE '\[(DEBUG|VERBOSE)\]' "$LOG_FILE" 2>/dev/null || echo "0")"
    steps="$(grep -cE '\[STEP [0-9]' "$LOG_FILE" 2>/dev/null || echo "0")"
    timings="$(grep -cE '\[TIMING\]' "$LOG_FILE" 2>/dev/null || echo "0")"

    local kv_width=22

    printf "    ${_LV_CYAN}%-${kv_width}s${_LV_RESET} ${_LV_WHITE}%s${_LV_RESET}\n" "Total Lines" "$total_lines"
    printf "    ${_LV_CYAN}%-${kv_width}s${_LV_RESET} ${_LV_WHITE}%s${_LV_RESET}\n" "File Size" "$file_size"
    echo ""

    # Level breakdown with colored bars
    local max_count="$errors"
    (( warnings > max_count )) && max_count="$warnings"
    (( successes > max_count )) && max_count="$successes"
    (( infos > max_count )) && max_count="$infos"
    (( debugs > max_count )) && max_count="$debugs"
    (( max_count == 0 )) && max_count=1

    local bar_max_width=30

    _lv_stat_bar() {
        local label="$1" count="$2" color="$3"
        local bar_len=$(( (count * bar_max_width) / max_count ))
        (( bar_len == 0 && count > 0 )) && bar_len=1
        local bar
        bar="$(_lv_repeat "#" "$bar_len")"
        printf "    ${color}%-${kv_width}s${_LV_RESET} ${color}%-${bar_max_width}s${_LV_RESET} %s\n" \
            "$label" "$bar" "$count"
    }

    _lv_stat_bar "Errors/Critical" "$errors"   "${_LV_RED}"
    _lv_stat_bar "Warnings"        "$warnings" "${_LV_YELLOW}"
    _lv_stat_bar "Success"         "$successes" "${_LV_GREEN}"
    _lv_stat_bar "Info"            "$infos"    "${_LV_GREEN}"
    _lv_stat_bar "Debug"           "$debugs"   "${_LV_PINK}"
    _lv_stat_bar "Steps"           "$steps"    "${_LV_BLUE}"
    _lv_stat_bar "Timings"         "$timings"  "${_LV_CYAN}"

    # Session info
    echo ""
    local sessions
    sessions="$(grep -c 'Session Started' "$LOG_FILE" 2>/dev/null || echo "0")"
    printf "    ${_LV_CYAN}%-${kv_width}s${_LV_RESET} ${_LV_WHITE}%s${_LV_RESET}\n" "Sessions Logged" "$sessions"

    # Archive stats
    if [[ -d "$LOG_BACKUP_DIR" ]]; then
        local archive_count archive_size
        archive_count="$(ls "$LOG_BACKUP_DIR"/*.log* 2>/dev/null | wc -l | tr -d ' ')"
        archive_size="$(du -sh "$LOG_BACKUP_DIR" 2>/dev/null | awk '{print $1}')"
        printf "    ${_LV_CYAN}%-${kv_width}s${_LV_RESET} ${_LV_WHITE}%s (%s)${_LV_RESET}\n" \
            "Archived Logs" "$archive_count files" "${archive_size:-0}"
    fi

    echo ""
}

# =============================================================================
# HELP DISPLAY
# =============================================================================

_lv_show_help() {
    _lv_header "Log Viewer — Help"

    cat <<HELP
  ${_LV_BOLD}${_LV_WHITE}USAGE${_LV_RESET}
    ./logs-viewer.sh [OPTIONS]

  ${_LV_BOLD}${_LV_WHITE}OPTIONS${_LV_RESET}
    ${_LV_CYAN}--follow, -f${_LV_RESET}          Tail the log file in real-time
    ${_LV_CYAN}--errors, -e${_LV_RESET}          Show only ERROR and CRITICAL entries
    ${_LV_CYAN}--warnings, -w${_LV_RESET}        Show only WARNING and CAUTION entries
    ${_LV_CYAN}--today, -t${_LV_RESET}           Show only entries from today
    ${_LV_CYAN}--search, -s TERM${_LV_RESET}     Search the log for a keyword
    ${_LV_CYAN}--archives, -a${_LV_RESET}        List all archived log files
    ${_LV_CYAN}--stats${_LV_RESET}               Show log file statistics
    ${_LV_CYAN}--lines, -n N${_LV_RESET}         Show last N lines (default: 50)
    ${_LV_CYAN}--help, -h${_LV_RESET}            Show this help message

  ${_LV_BOLD}${_LV_WHITE}EXAMPLES${_LV_RESET}
    ${_LV_GRAY}# Show the last 100 lines${_LV_RESET}
    ./logs-viewer.sh --lines 100

    ${_LV_GRAY}# Follow the log and see new entries in real-time${_LV_RESET}
    ./logs-viewer.sh --follow

    ${_LV_GRAY}# See only today's errors${_LV_RESET}
    ./logs-viewer.sh --today --errors

    ${_LV_GRAY}# Search for a specific stack${_LV_RESET}
    ./logs-viewer.sh --search "core-infrastructure"

    ${_LV_GRAY}# View statistics about the log${_LV_RESET}
    ./logs-viewer.sh --stats

  ${_LV_BOLD}${_LV_WHITE}LOG FILE${_LV_RESET}
    ${_LV_GRAY}Current:  ${LOG_FILE}${_LV_RESET}
    ${_LV_GRAY}Archives: ${LOG_BACKUP_DIR}${_LV_RESET}

HELP
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

    # Default settings
    _LV_ACTION="tail"
    _LV_NUM_LINES=50
    _LV_SEARCH_TERM=""
    _LV_FILTER_TODAY=false
    _LV_FILTER_ERRORS=false
    _LV_FILTER_WARNINGS=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --follow|-f)
                _LV_ACTION="follow"
                shift
                ;;
            --errors|-e)
                if [[ "$_LV_ACTION" == "tail" ]]; then
                    _LV_ACTION="errors"
                fi
                _LV_FILTER_ERRORS=true
                shift
                ;;
            --warnings|-w)
                if [[ "$_LV_ACTION" == "tail" ]]; then
                    _LV_ACTION="warnings"
                fi
                _LV_FILTER_WARNINGS=true
                shift
                ;;
            --today|-t)
                if [[ "$_LV_ACTION" == "tail" ]]; then
                    _LV_ACTION="today"
                fi
                _LV_FILTER_TODAY=true
                shift
                ;;
            --search|-s)
                _LV_ACTION="search"
                _LV_SEARCH_TERM="${2:-}"
                shift 2 || { echo "Error: --search requires an argument" >&2; exit 1; }
                ;;
            --archives|-a)
                _LV_ACTION="archives"
                shift
                ;;
            --stats)
                _LV_ACTION="stats"
                shift
                ;;
            --lines|-n)
                _LV_NUM_LINES="${2:-50}"
                shift 2 || { echo "Error: --lines requires a number" >&2; exit 1; }
                ;;
            --help|-h)
                _lv_show_help
                exit 0
                ;;
            *)
                echo "${_LV_RED}Unknown option: $1${_LV_RESET}" >&2
                echo "Run './logs-viewer.sh --help' for usage." >&2
                exit 1
                ;;
        esac
    done

    # Execute the selected action
    case "$_LV_ACTION" in
        follow)     _lv_follow ;;
        errors)     _lv_show_errors ;;
        warnings)   _lv_show_warnings ;;
        today)
            if [[ "$_LV_FILTER_ERRORS" == "true" ]]; then
                # Combine today + errors filter
                _lv_check_log_file || exit 1
                _lv_header "Log Viewer — Today's Errors"
                local today_date
                today_date="$(date '+%b/%d/%Y')"
                grep "$today_date" "$LOG_FILE" 2>/dev/null | grep -E '\[(ERROR|CRITICAL|ALERT)\]' | _lv_colorize_stream
            elif [[ "$_LV_FILTER_WARNINGS" == "true" ]]; then
                _lv_check_log_file || exit 1
                _lv_header "Log Viewer — Today's Warnings"
                local today_date
                today_date="$(date '+%b/%d/%Y')"
                grep "$today_date" "$LOG_FILE" 2>/dev/null | grep -E '\[(WARNING|CAUTION)\]' | _lv_colorize_stream
            else
                _lv_show_today
            fi
            ;;
        search)     _lv_search "$_LV_SEARCH_TERM" ;;
        archives)   _lv_show_archives ;;
        stats)      _lv_show_stats ;;
        tail)       _lv_show_tail "$_LV_NUM_LINES" ;;
    esac

    exit $?
fi
