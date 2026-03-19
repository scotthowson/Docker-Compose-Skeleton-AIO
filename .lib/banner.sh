#!/bin/bash
# =============================================================================
# Banner Display Library
# Beautiful ASCII art banners for Docker Compose Skeleton
#
# Provides elegant startup banners with system information, color support,
# and graceful fallback for non-interactive terminals.
#
# Usage:
#   source .lib/banner.sh
#   show_startup_banner
#   show_shutdown_banner
#   show_mini_banner "Custom Title"
#
# Dependencies:
#   Colors from settings.cfg or palette.sh (optional — falls back gracefully)
# =============================================================================

# =============================================================================
# COLOR INITIALIZATION
# =============================================================================

# Set up colors if not already available from the palette system
_banner_init_colors() {
    if [[ -n "${COLOR_RESET:-}" ]]; then
        # Colors already loaded from settings.cfg / palette.sh
        _BNR_RESET="${COLOR_RESET}"
        _BNR_BOLD="${COLOR_BOLD:-}"
        _BNR_DIM="${COLOR_DIM:-}"
        _BNR_CYAN="${COLOR_PROMPT:-$(tput setaf 51 2>/dev/null || true)}"
        _BNR_BLUE="${COLOR_FOCUS:-$(tput setaf 33 2>/dev/null || true)}"
        _BNR_GREEN="${COLOR_SUCCESS:-$(tput setaf 82 2>/dev/null || true)}"
        _BNR_MAGENTA="${COLOR_INFO_HEADER:-$(tput setaf 141 2>/dev/null || true)}"
        _BNR_GRAY="${COLOR_NEUTRAL:-$(tput setaf 245 2>/dev/null || true)}"
        _BNR_WHITE="$(tput setaf 15 2>/dev/null || true)"
        _BNR_YELLOW="${COLOR_WARNING:-$(tput setaf 214 2>/dev/null || true)}"
        _BNR_RED="${COLOR_CRITICAL:-$(tput setaf 196 2>/dev/null || true)}"
        return
    fi

    if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]] && command -v tput >/dev/null 2>&1; then
        local colors
        colors="$(tput colors 2>/dev/null || echo 0)"
        if (( colors >= 256 )); then
            _BNR_RESET="$(tput sgr0)"
            _BNR_BOLD="$(tput bold)"
            _BNR_DIM="$(tput dim)"
            _BNR_CYAN="$(tput setaf 51)"
            _BNR_BLUE="$(tput setaf 33)"
            _BNR_GREEN="$(tput setaf 82)"
            _BNR_MAGENTA="$(tput setaf 141)"
            _BNR_GRAY="$(tput setaf 245)"
            _BNR_WHITE="$(tput setaf 15)"
            _BNR_YELLOW="$(tput setaf 214)"
            _BNR_RED="$(tput setaf 196)"
        elif (( colors >= 8 )); then
            _BNR_RESET="$(tput sgr0)"
            _BNR_BOLD="$(tput bold)"
            _BNR_DIM="$(tput dim 2>/dev/null || true)"
            _BNR_CYAN="$(tput setaf 6)"
            _BNR_BLUE="$(tput setaf 4)"
            _BNR_GREEN="$(tput setaf 2)"
            _BNR_MAGENTA="$(tput setaf 5)"
            _BNR_GRAY="$(tput setaf 7)"
            _BNR_WHITE="$(tput setaf 7)"
            _BNR_YELLOW="$(tput setaf 3)"
            _BNR_RED="$(tput setaf 1)"
        else
            _banner_no_colors
        fi
    else
        _banner_no_colors
    fi
}

_banner_no_colors() {
    _BNR_RESET="" _BNR_BOLD="" _BNR_DIM=""
    _BNR_CYAN="" _BNR_BLUE="" _BNR_GREEN="" _BNR_MAGENTA=""
    _BNR_GRAY="" _BNR_WHITE="" _BNR_YELLOW="" _BNR_RED=""
}

# Initialize on source
_banner_init_colors

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Center text within a given width
_banner_center() {
    local text="$1"
    local width="${2:-60}"
    local text_len=${#text}
    local pad_left=$(( (width - text_len) / 2 ))

    (( pad_left < 0 )) && pad_left=0
    printf "%*s%s" "$pad_left" "" "$text"
}

# Repeat a character
_banner_repeat() {
    local char="$1"
    local count="$2"
    (( count <= 0 )) && return
    printf "%0.s${char}" $(seq 1 "$count")
}

# =============================================================================
# STARTUP BANNER
# =============================================================================

show_startup_banner() {
    local version="${SCRIPT_VERSION:-2.0.0}"
    local app_name="${APPLICATION_TITLE:-Docker Compose Skeleton}"
    local environment="${ENVIRONMENT:-production}"
    local current_date
    current_date="$(date '+%B %d, %Y at %-l:%M %p')"

    local inner_width=58
    local total_width=$(( inner_width + 2 ))

    local bar_top bar_bot bar_mid
    bar_top="${_BNR_BLUE}+$(_banner_repeat "-" "$inner_width")+${_BNR_RESET}"
    bar_bot="${_BNR_BLUE}+$(_banner_repeat "-" "$inner_width")+${_BNR_RESET}"
    bar_mid="${_BNR_BLUE}|$(_banner_repeat " " "$inner_width")|${_BNR_RESET}"

    # Decorative accent line
    local accent_len=40
    local accent_pad=$(( (inner_width - accent_len) / 2 ))
    local accent_line="${_BNR_BLUE}|${_BNR_RESET}"
    accent_line+="$(printf '%*s' "$accent_pad" '')"
    accent_line+="${_BNR_CYAN}$(_banner_repeat "=" "$accent_len")${_BNR_RESET}"
    accent_line+="$(printf '%*s' $(( inner_width - accent_pad - accent_len )) '')"
    accent_line+="${_BNR_BLUE}|${_BNR_RESET}"

    # Title line
    local title="D O C K E R   S K E L E T O N"
    local title_pad=$(( (inner_width - ${#title}) / 2 ))
    local title_line="${_BNR_BLUE}|${_BNR_RESET}"
    title_line+="$(printf '%*s' "$title_pad" '')"
    title_line+="${_BNR_BOLD}${_BNR_CYAN}${title}${_BNR_RESET}"
    title_line+="$(printf '%*s' $(( inner_width - title_pad - ${#title} )) '')"
    title_line+="${_BNR_BLUE}|${_BNR_RESET}"

    # Subtitle line
    local subtitle="Modular Service Orchestration Framework"
    local sub_pad=$(( (inner_width - ${#subtitle}) / 2 ))
    local subtitle_line="${_BNR_BLUE}|${_BNR_RESET}"
    subtitle_line+="$(printf '%*s' "$sub_pad" '')"
    subtitle_line+="${_BNR_DIM}${_BNR_GRAY}${subtitle}${_BNR_RESET}"
    subtitle_line+="$(printf '%*s' $(( inner_width - sub_pad - ${#subtitle} )) '')"
    subtitle_line+="${_BNR_BLUE}|${_BNR_RESET}"

    # Version + Environment line
    local ver_env="v${version}  |  ${environment}"
    local ve_pad=$(( (inner_width - ${#ver_env}) / 2 ))
    local ver_line="${_BNR_BLUE}|${_BNR_RESET}"
    ver_line+="$(printf '%*s' "$ve_pad" '')"
    ver_line+="${_BNR_MAGENTA}${ver_env}${_BNR_RESET}"
    ver_line+="$(printf '%*s' $(( inner_width - ve_pad - ${#ver_env} )) '')"
    ver_line+="${_BNR_BLUE}|${_BNR_RESET}"

    # Date line
    local date_pad=$(( (inner_width - ${#current_date}) / 2 ))
    local date_line="${_BNR_BLUE}|${_BNR_RESET}"
    date_line+="$(printf '%*s' "$date_pad" '')"
    date_line+="${_BNR_DIM}${_BNR_GRAY}${current_date}${_BNR_RESET}"
    date_line+="$(printf '%*s' $(( inner_width - date_pad - ${#current_date} )) '')"
    date_line+="${_BNR_BLUE}|${_BNR_RESET}"

    # Render the banner
    echo ""
    echo "  ${bar_top}"
    echo "  ${bar_mid}"
    echo "  ${accent_line}"
    echo "  ${title_line}"
    echo "  ${accent_line}"
    echo "  ${bar_mid}"
    echo "  ${subtitle_line}"
    echo "  ${ver_line}"
    echo "  ${date_line}"
    echo "  ${bar_mid}"
    echo "  ${bar_bot}"
    echo ""
}

# =============================================================================
# SHUTDOWN BANNER
# =============================================================================

show_shutdown_banner() {
    local version="${SCRIPT_VERSION:-2.0.0}"
    local inner_width=58

    local bar_top="${_BNR_RED}+$(_banner_repeat "-" "$inner_width")+${_BNR_RESET}"
    local bar_bot="${_BNR_RED}+$(_banner_repeat "-" "$inner_width")+${_BNR_RESET}"
    local bar_mid="${_BNR_RED}|$(_banner_repeat " " "$inner_width")|${_BNR_RESET}"

    local title="S H U T D O W N   S E Q U E N C E"
    local title_pad=$(( (inner_width - ${#title}) / 2 ))
    local title_line="${_BNR_RED}|${_BNR_RESET}"
    title_line+="$(printf '%*s' "$title_pad" '')"
    title_line+="${_BNR_BOLD}${_BNR_RED}${title}${_BNR_RESET}"
    title_line+="$(printf '%*s' $(( inner_width - title_pad - ${#title} )) '')"
    title_line+="${_BNR_RED}|${_BNR_RESET}"

    local subtitle="Gracefully stopping all services..."
    local sub_pad=$(( (inner_width - ${#subtitle}) / 2 ))
    local subtitle_line="${_BNR_RED}|${_BNR_RESET}"
    subtitle_line+="$(printf '%*s' "$sub_pad" '')"
    subtitle_line+="${_BNR_YELLOW}${subtitle}${_BNR_RESET}"
    subtitle_line+="$(printf '%*s' $(( inner_width - sub_pad - ${#subtitle} )) '')"
    subtitle_line+="${_BNR_RED}|${_BNR_RESET}"

    echo ""
    echo "  ${bar_top}"
    echo "  ${bar_mid}"
    echo "  ${title_line}"
    echo "  ${subtitle_line}"
    echo "  ${bar_mid}"
    echo "  ${bar_bot}"
    echo ""
}

# =============================================================================
# MINI BANNER (for section headers)
# =============================================================================

show_mini_banner() {
    local title="${1:-}"
    local color="${2:-blue}"  # blue, green, yellow, red, magenta

    [[ -z "$title" ]] && return

    local color_code
    case "$color" in
        green)   color_code="${_BNR_GREEN}" ;;
        yellow)  color_code="${_BNR_YELLOW}" ;;
        red)     color_code="${_BNR_RED}" ;;
        magenta) color_code="${_BNR_MAGENTA}" ;;
        cyan)    color_code="${_BNR_CYAN}" ;;
        *)       color_code="${_BNR_BLUE}" ;;
    esac

    local title_len=${#title}
    local total_width=$(( title_len + 8 ))
    local border
    border="$(_banner_repeat "-" "$total_width")"

    echo ""
    echo "  ${color_code}+${border}+${_BNR_RESET}"
    echo "  ${color_code}|${_BNR_RESET}    ${_BNR_BOLD}${color_code}${title}${_BNR_RESET}    ${color_code}|${_BNR_RESET}"
    echo "  ${color_code}+${border}+${_BNR_RESET}"
    echo ""
}

# =============================================================================
# COMPLETION BANNER
# =============================================================================

show_completion_banner() {
    local status="${1:-success}"  # success, warning, error
    local message="${2:-All operations completed successfully}"
    local duration="${3:-}"

    local inner_width=58

    local status_color status_icon status_text
    case "$status" in
        success)
            status_color="${_BNR_GREEN}"
            status_text="COMPLETE"
            ;;
        warning)
            status_color="${_BNR_YELLOW}"
            status_text="COMPLETED WITH WARNINGS"
            ;;
        error)
            status_color="${_BNR_RED}"
            status_text="COMPLETED WITH ERRORS"
            ;;
    esac

    local bar="${status_color}+$(_banner_repeat "-" "$inner_width")+${_BNR_RESET}"
    local empty="${status_color}|$(_banner_repeat " " "$inner_width")|${_BNR_RESET}"

    # Status line
    local status_pad=$(( (inner_width - ${#status_text}) / 2 ))
    local status_line="${status_color}|${_BNR_RESET}"
    status_line+="$(printf '%*s' "$status_pad" '')"
    status_line+="${_BNR_BOLD}${status_color}${status_text}${_BNR_RESET}"
    status_line+="$(printf '%*s' $(( inner_width - status_pad - ${#status_text} )) '')"
    status_line+="${status_color}|${_BNR_RESET}"

    # Message line
    local msg_pad=$(( (inner_width - ${#message}) / 2 ))
    (( msg_pad < 1 )) && msg_pad=1
    local msg_display="$message"
    if (( ${#msg_display} > inner_width - 2 )); then
        msg_display="${msg_display:0:$(( inner_width - 4 ))}.."
    fi
    local msg_line="${status_color}|${_BNR_RESET}"
    msg_line+="$(printf '%*s' "$msg_pad" '')"
    msg_line+="${_BNR_DIM}${_BNR_GRAY}${msg_display}${_BNR_RESET}"
    msg_line+="$(printf '%*s' $(( inner_width - msg_pad - ${#msg_display} )) '')"
    msg_line+="${status_color}|${_BNR_RESET}"

    echo ""
    echo "  ${bar}"
    echo "  ${empty}"
    echo "  ${status_line}"
    echo "  ${msg_line}"

    # Duration line (optional)
    if [[ -n "$duration" ]]; then
        local dur_text="Duration: ${duration}"
        local dur_pad=$(( (inner_width - ${#dur_text}) / 2 ))
        local dur_line="${status_color}|${_BNR_RESET}"
        dur_line+="$(printf '%*s' "$dur_pad" '')"
        dur_line+="${_BNR_DIM}${_BNR_GRAY}${dur_text}${_BNR_RESET}"
        dur_line+="$(printf '%*s' $(( inner_width - dur_pad - ${#dur_text} )) '')"
        dur_line+="${status_color}|${_BNR_RESET}"
        echo "  ${dur_line}"
    fi

    echo "  ${empty}"
    echo "  ${bar}"
    echo ""
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f show_startup_banner show_shutdown_banner show_mini_banner show_completion_banner
export -f _banner_init_colors _banner_center _banner_repeat _banner_no_colors
