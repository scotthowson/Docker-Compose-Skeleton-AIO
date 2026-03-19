#!/bin/bash
# Enhanced Color Palette System v2.0
# Comprehensive color management for logging and terminal output
# Compatible with Enhanced Logger System v2.0

#===============================================================================
# PALETTE INITIALIZATION AND VALIDATION
#===============================================================================

# Validate terminal color support
_validate_color_support() {
    local color_support=true
    
    # Check if terminal supports colors
    if [[ ! -t 1 ]] || [[ "${TERM:-}" == "dumb" ]] || ! command -v tput >/dev/null 2>&1; then
        color_support=false
    fi
    
    # Check tput color capability
    if [[ "$color_support" == "true" ]]; then
        local colors
        colors="$(tput colors 2>/dev/null || echo 0)"
        [[ "$colors" -lt 8 ]] && color_support=false
    fi
    
    export COLOR_SUPPORT="$color_support"
    return 0
}

# Initialize color palette
_initialize_palette() {
    # Validate color support first
    _validate_color_support
    
    # If no color support, create empty palette
    if [[ "$COLOR_SUPPORT" != "true" ]]; then
        _create_no_color_palette
        return 0
    fi
    
    # Load settings if available
    if [[ -f "${BASE_DIR}/.config/settings.cfg" ]]; then
        source "${BASE_DIR}/.config/settings.cfg" 2>/dev/null || {
            echo "Warning: Failed to load settings.cfg, using defaults" >&2
        }
    fi
    
    # Create comprehensive color palette
    _create_color_palette
    
    return 0
}

# Create palette with no colors (for unsupported terminals)
_create_no_color_palette() {
    declare -gA COLOR_PALETTE
    
    # All colors are empty strings
    local log_levels=(
        "BLACK" "RED" "GREEN" "YELLOW" "BLUE" "PURPLE" "CYAN" "WHITE"
        "INFO" "SUCCESS" "WARNING" "ERROR" "DEBUG" "INFO_HEADER"
        "IMPORTANT" "NOTE" "TIP" "CONFIRMATION" "ALERT" "CAUTION"
        "FOCUS" "HIGHLIGHT" "NEUTRAL" "PROMPT" "STATUS" "VERBOSE"
        "QUESTION" "CRITICAL" "RESET"
    )
    
    for level in "${log_levels[@]}"; do
        COLOR_PALETTE["$level"]=""
        COLOR_PALETTE["BOLD_$level"]=""
        COLOR_PALETTE["DIM_$level"]=""
        COLOR_PALETTE["UNDERLINE_$level"]=""
    done
}

# Create comprehensive color palette
_create_color_palette() {
    declare -gA COLOR_PALETTE
    
    # Basic terminal colors (0-7)
    COLOR_PALETTE[BLACK]="$(tput setaf 0 2>/dev/null || echo '')"
    COLOR_PALETTE[RED]="$(tput setaf 1 2>/dev/null || echo '')"
    COLOR_PALETTE[GREEN]="$(tput setaf 2 2>/dev/null || echo '')"
    COLOR_PALETTE[YELLOW]="$(tput setaf 3 2>/dev/null || echo '')"
    COLOR_PALETTE[BLUE]="$(tput setaf 4 2>/dev/null || echo '')"
    COLOR_PALETTE[PURPLE]="$(tput setaf 5 2>/dev/null || echo '')"
    COLOR_PALETTE[CYAN]="$(tput setaf 6 2>/dev/null || echo '')"
    COLOR_PALETTE[WHITE]="$(tput setaf 7 2>/dev/null || echo '')"
    
    # Bright colors (8-15)
    COLOR_PALETTE[BRIGHT_BLACK]="$(tput setaf 8 2>/dev/null || echo '')"
    COLOR_PALETTE[BRIGHT_RED]="$(tput setaf 9 2>/dev/null || echo '')"
    COLOR_PALETTE[BRIGHT_GREEN]="$(tput setaf 10 2>/dev/null || echo '')"
    COLOR_PALETTE[BRIGHT_YELLOW]="$(tput setaf 11 2>/dev/null || echo '')"
    COLOR_PALETTE[BRIGHT_BLUE]="$(tput setaf 12 2>/dev/null || echo '')"
    COLOR_PALETTE[BRIGHT_PURPLE]="$(tput setaf 13 2>/dev/null || echo '')"
    COLOR_PALETTE[BRIGHT_CYAN]="$(tput setaf 14 2>/dev/null || echo '')"
    COLOR_PALETTE[BRIGHT_WHITE]="$(tput setaf 15 2>/dev/null || echo '')"
    
    # Extended colors for logging (using custom or fallback values)
    COLOR_PALETTE[INFO]="${COLOR_INFO:-$(tput setaf 119 2>/dev/null || tput setaf 2)}"
    COLOR_PALETTE[SUCCESS]="${COLOR_SUCCESS:-$(tput setaf 82 2>/dev/null || tput setaf 2)}"
    COLOR_PALETTE[WARNING]="${COLOR_WARNING:-$(tput setaf 208 2>/dev/null || tput setaf 3)}"
    COLOR_PALETTE[ERROR]="${COLOR_ERROR:-$(tput setaf 124 2>/dev/null || tput setaf 1)}"
    COLOR_PALETTE[DEBUG]="${COLOR_DEBUG:-$(tput setaf 200 2>/dev/null || tput setaf 5)}"
    COLOR_PALETTE[CRITICAL]="${COLOR_CRITICAL:-$(tput setaf 196 2>/dev/null || tput setaf 1)}"
    
    # Extended log levels with fallbacks
    COLOR_PALETTE[INFO_HEADER]="${COLOR_INFO_HEADER:-$(tput setaf 141 2>/dev/null || tput setaf 6)}"
    COLOR_PALETTE[IMPORTANT]="${COLOR_IMPORTANT:-$(tput setaf 80 2>/dev/null || tput setaf 6)}"
    COLOR_PALETTE[NOTE]="${COLOR_NOTE:-$(tput setaf 250 2>/dev/null || tput setaf 7)}"
    COLOR_PALETTE[TIP]="${COLOR_TIP:-$(tput setaf 245 2>/dev/null || tput setaf 7)}"
    COLOR_PALETTE[CONFIRMATION]="${COLOR_CONFIRMATION:-$(tput setaf 190 2>/dev/null || tput setaf 2)}"
    COLOR_PALETTE[ALERT]="${COLOR_ALERT:-$(tput setaf 214 2>/dev/null || tput setaf 3)}"
    COLOR_PALETTE[CAUTION]="${COLOR_CAUTION:-$(tput setaf 220 2>/dev/null || tput setaf 3)}"
    COLOR_PALETTE[FOCUS]="${COLOR_FOCUS:-$(tput setaf 33 2>/dev/null || tput setaf 4)}"
    COLOR_PALETTE[HIGHLIGHT]="${COLOR_HIGHLIGHT:-$(tput setaf 201 2>/dev/null || tput setaf 5)}"
    COLOR_PALETTE[NEUTRAL]="${COLOR_NEUTRAL:-$(tput setaf 244 2>/dev/null || tput setaf 7)}"
    COLOR_PALETTE[PROMPT]="${COLOR_PROMPT:-$(tput setaf 51 2>/dev/null || tput setaf 6)}"
    COLOR_PALETTE[STATUS]="${COLOR_STATUS:-$(tput setaf 163 2>/dev/null || tput setaf 5)}"
    COLOR_PALETTE[VERBOSE]="${COLOR_VERBOSE:-$(tput setaf 245 2>/dev/null || tput setaf 7)}"
    COLOR_PALETTE[QUESTION]="${COLOR_QUESTION:-$(tput setaf 172 2>/dev/null || tput setaf 3)}"
    
    # Formatting codes
    COLOR_PALETTE[RESET]="$(tput sgr0 2>/dev/null || echo '')"
    COLOR_PALETTE[BOLD]="$(tput bold 2>/dev/null || echo '')"
    COLOR_PALETTE[DIM]="$(tput dim 2>/dev/null || echo '')"
    COLOR_PALETTE[UNDERLINE]="$(tput smul 2>/dev/null || echo '')"
    COLOR_PALETTE[REVERSE]="$(tput rev 2>/dev/null || echo '')"
    COLOR_PALETTE[STANDOUT]="$(tput smso 2>/dev/null || echo '')"
    COLOR_PALETTE[BLINK]="$(tput blink 2>/dev/null || echo '')"
    
    # Background colors
    COLOR_PALETTE[BG_BLACK]="$(tput setab 0 2>/dev/null || echo '')"
    COLOR_PALETTE[BG_RED]="$(tput setab 1 2>/dev/null || echo '')"
    COLOR_PALETTE[BG_GREEN]="$(tput setab 2 2>/dev/null || echo '')"
    COLOR_PALETTE[BG_YELLOW]="$(tput setab 3 2>/dev/null || echo '')"
    COLOR_PALETTE[BG_BLUE]="$(tput setab 4 2>/dev/null || echo '')"
    COLOR_PALETTE[BG_PURPLE]="$(tput setab 5 2>/dev/null || echo '')"
    COLOR_PALETTE[BG_CYAN]="$(tput setab 6 2>/dev/null || echo '')"
    COLOR_PALETTE[BG_WHITE]="$(tput setab 7 2>/dev/null || echo '')"
    
    # Create formatted variants
    _create_formatted_variants
    
    # Create RGB and hex color functions if terminal supports it
    _create_extended_color_functions
}

# Create bold, dim, and underlined variants for all colors
_create_formatted_variants() {
    local base_colors=(
        "BLACK" "RED" "GREEN" "YELLOW" "BLUE" "PURPLE" "CYAN" "WHITE"
        "BRIGHT_BLACK" "BRIGHT_RED" "BRIGHT_GREEN" "BRIGHT_YELLOW" 
        "BRIGHT_BLUE" "BRIGHT_PURPLE" "BRIGHT_CYAN" "BRIGHT_WHITE"
        "INFO" "SUCCESS" "WARNING" "ERROR" "DEBUG" "CRITICAL"
        "INFO_HEADER" "IMPORTANT" "NOTE" "TIP" "CONFIRMATION" 
        "ALERT" "CAUTION" "FOCUS" "HIGHLIGHT" "NEUTRAL" 
        "PROMPT" "STATUS" "VERBOSE" "QUESTION"
    )
    
    for color in "${base_colors[@]}"; do
        # Bold variants
        COLOR_PALETTE["BOLD_$color"]="${COLOR_PALETTE[BOLD]}${COLOR_PALETTE[$color]}"
        
        # Dim variants
        COLOR_PALETTE["DIM_$color"]="${COLOR_PALETTE[DIM]}${COLOR_PALETTE[$color]}"
        
        # Underlined variants
        COLOR_PALETTE["UNDERLINE_$color"]="${COLOR_PALETTE[UNDERLINE]}${COLOR_PALETTE[$color]}"
        
        # Bold underlined variants
        COLOR_PALETTE["BOLD_UNDERLINE_$color"]="${COLOR_PALETTE[BOLD]}${COLOR_PALETTE[UNDERLINE]}${COLOR_PALETTE[$color]}"
    done
}

# Create extended color functions for RGB and hex values
_create_extended_color_functions() {
    # Check if terminal supports 256 colors
    local colors
    colors="$(tput colors 2>/dev/null || echo 0)"
    
    if [[ "$colors" -ge 256 ]]; then
        export EXTENDED_COLOR_SUPPORT=true
    else
        export EXTENDED_COLOR_SUPPORT=false
        return 0
    fi
}

#===============================================================================
# COLOR UTILITY FUNCTIONS
#===============================================================================

# Get color code by name
get_color() {
    local color_name="$1"
    echo "${COLOR_PALETTE[$color_name]:-}"
}

# Apply color to text
colorize() {
    local color="$1"
    local text="$2"
    local reset="${3:-true}"
    
    if [[ "$COLOR_SUPPORT" != "true" ]]; then
        echo "$text"
        return 0
    fi
    
    local color_code="${COLOR_PALETTE[$color]:-}"
    local reset_code=""
    
    [[ "$reset" == "true" ]] && reset_code="${COLOR_PALETTE[RESET]}"
    
    echo "${color_code}${text}${reset_code}"
}

# Apply multiple formatting options
format_text() {
    local text="$1"
    shift
    local formats=("$@")
    
    if [[ "$COLOR_SUPPORT" != "true" ]]; then
        echo "$text"
        return 0
    fi
    
    local format_codes=""
    for format in "${formats[@]}"; do
        format_codes+="${COLOR_PALETTE[$format]:-}"
    done
    
    echo "${format_codes}${text}${COLOR_PALETTE[RESET]}"
}

# RGB color function (for 256-color terminals)
rgb_color() {
    local r="$1" g="$2" b="$3"
    
    if [[ "$EXTENDED_COLOR_SUPPORT" != "true" ]]; then
        echo ""
        return 1
    fi
    
    # Convert RGB to 256-color palette
    local color_code
    color_code=$((16 + (36 * (r * 5 / 255)) + (6 * (g * 5 / 255)) + (b * 5 / 255)))
    
    tput setaf "$color_code" 2>/dev/null || echo ""
}

# Hex color function
hex_color() {
    local hex="$1"
    
    # Remove # if present
    hex="${hex#\#}"
    
    # Validate hex format
    if [[ ! "$hex" =~ ^[0-9A-Fa-f]{6}$ ]]; then
        echo ""
        return 1
    fi
    
    # Convert hex to RGB
    local r g b
    r=$((0x${hex:0:2}))
    g=$((0x${hex:2:2}))
    b=$((0x${hex:4:2}))
    
    rgb_color "$r" "$g" "$b"
}

#===============================================================================
# PALETTE TESTING AND VALIDATION
#===============================================================================

# Test color display
test_colors() {
    echo "Color Palette Test"
    echo "=================="
    echo
    
    if [[ "$COLOR_SUPPORT" != "true" ]]; then
        echo "❌ Color support not available in this terminal"
        return 1
    fi
    
    echo "✅ Color support: Available ($(tput colors) colors)"
    echo
    
    # Test basic colors
    echo "Basic Colors:"
    local basic_colors=("BLACK" "RED" "GREEN" "YELLOW" "BLUE" "PURPLE" "CYAN" "WHITE")
    for color in "${basic_colors[@]}"; do
        printf "%-12s: %s\n" "$color" "$(colorize "$color" "Sample text")"
    done
    echo
    
    # Test log level colors
    echo "Log Level Colors:"
    local log_colors=("INFO" "SUCCESS" "WARNING" "ERROR" "DEBUG" "CRITICAL")
    for color in "${log_colors[@]}"; do
        printf "%-12s: %s\n" "$color" "$(colorize "$color" "Sample $color message")"
    done
    echo
    
    # Test formatting
    echo "Text Formatting:"
    printf "%-12s: %s\n" "BOLD" "$(format_text "Bold text" "BOLD" "RED")"
    printf "%-12s: %s\n" "UNDERLINE" "$(format_text "Underlined text" "UNDERLINE" "BLUE")"
    printf "%-12s: %s\n" "DIM" "$(format_text "Dim text" "DIM" "GREEN")"
    echo
    
    # Test extended colors if available
    if [[ "$EXTENDED_COLOR_SUPPORT" == "true" ]]; then
        echo "Extended Colors (RGB):"
        printf "%-12s: %s\n" "Custom RGB" "$(colorize "$(rgb_color 255 100 50)" "Orange-ish text")"
        printf "%-12s: %s\n" "Custom Hex" "$(colorize "$(hex_color "#FF6432")" "Hex color text")"
        echo
    fi
}

# Validate palette configuration
validate_palette() {
    local errors=()
    
    # Check if COLOR_PALETTE is defined
    if [[ -z "${COLOR_PALETTE:-}" ]]; then
        errors+=("COLOR_PALETTE array not defined")
    fi
    
    # Check essential colors
    local essential_colors=("RESET" "INFO" "SUCCESS" "WARNING" "ERROR")
    for color in "${essential_colors[@]}"; do
        if [[ -z "${COLOR_PALETTE[$color]:-}" ]] && [[ "$COLOR_SUPPORT" == "true" ]]; then
            errors+=("Essential color '$color' not defined")
        fi
    done
    
    # Report validation results
    if [[ ${#errors[@]} -gt 0 ]]; then
        echo "❌ Palette validation errors:" >&2
        printf "   - %s\n" "${errors[@]}" >&2
        return 1
    fi
    
    echo "✅ Color palette validated successfully"
    return 0
}

# Display palette information
show_palette_info() {
    echo "Color Palette Information"
    echo "========================"
    echo "Color Support: ${COLOR_SUPPORT:-Unknown}"
    echo "Extended Color Support: ${EXTENDED_COLOR_SUPPORT:-Unknown}"
    echo "Terminal Colors: $(tput colors 2>/dev/null || echo "Unknown")"
    echo "Terminal Type: ${TERM:-Unknown}"
    echo "Palette Colors Defined: ${#COLOR_PALETTE[@]}"
    echo
    
    if [[ "${1:-}" == "--verbose" ]]; then
        echo "Available Colors:"
        for color in $(printf '%s\n' "${!COLOR_PALETTE[@]}" | sort); do
            printf "  %-20s: %s\n" "$color" "$(colorize "$color" "Sample")"
        done
    fi
}

#===============================================================================
# THEME SUPPORT
#===============================================================================

# Load a predefined theme
load_theme() {
    local theme="$1"
    
    case "$theme" in
        "dark")
            _apply_dark_theme
            ;;
        "light")
            _apply_light_theme
            ;;
        "high-contrast")
            _apply_high_contrast_theme
            ;;
        "minimal")
            _apply_minimal_theme
            ;;
        *)
            echo "❌ Unknown theme: $theme" >&2
            echo "Available themes: dark, light, high-contrast, minimal" >&2
            return 1
            ;;
    esac
    
    echo "✅ Theme '$theme' loaded successfully"
}

# Apply dark theme
_apply_dark_theme() {
    # Optimized for dark terminals
    COLOR_PALETTE[INFO]="$(tput setaf 117)"      # Light blue
    COLOR_PALETTE[SUCCESS]="$(tput setaf 82)"    # Bright green
    COLOR_PALETTE[WARNING]="$(tput setaf 214)"   # Orange
    COLOR_PALETTE[ERROR]="$(tput setaf 196)"     # Bright red
    COLOR_PALETTE[DEBUG]="$(tput setaf 205)"     # Pink
}

# Apply light theme
_apply_light_theme() {
    # Optimized for light terminals
    COLOR_PALETTE[INFO]="$(tput setaf 26)"       # Dark blue
    COLOR_PALETTE[SUCCESS]="$(tput setaf 28)"    # Dark green
    COLOR_PALETTE[WARNING]="$(tput setaf 130)"   # Dark orange
    COLOR_PALETTE[ERROR]="$(tput setaf 124)"     # Dark red
    COLOR_PALETTE[DEBUG]="$(tput setaf 90)"      # Dark purple
}

# Apply high contrast theme
_apply_high_contrast_theme() {
    # High contrast for accessibility
    COLOR_PALETTE[INFO]="$(tput setaf 15)"       # White
    COLOR_PALETTE[SUCCESS]="$(tput setaf 10)"    # Bright green
    COLOR_PALETTE[WARNING]="$(tput setaf 11)"    # Bright yellow
    COLOR_PALETTE[ERROR]="$(tput setaf 9)"       # Bright red
    COLOR_PALETTE[DEBUG]="$(tput setaf 13)"      # Bright magenta
}

# Apply minimal theme
_apply_minimal_theme() {
    # Minimal colors for subtle output
    COLOR_PALETTE[INFO]="$(tput setaf 7)"        # Light gray
    COLOR_PALETTE[SUCCESS]="$(tput setaf 2)"     # Green
    COLOR_PALETTE[WARNING]="$(tput setaf 3)"     # Yellow
    COLOR_PALETTE[ERROR]="$(tput setaf 1)"       # Red
    COLOR_PALETTE[DEBUG]="$(tput setaf 5)"       # Purple
}

#===============================================================================
# INITIALIZATION AND EXPORT
#===============================================================================

# Initialize palette when sourced
_initialize_palette

# Export functions for external use
export -f get_color colorize format_text rgb_color hex_color
export -f test_colors validate_palette show_palette_info load_theme

# Export variables
export COLOR_SUPPORT EXTENDED_COLOR_SUPPORT

# Mark palette as loaded
export PALETTE_LOADED=true

# Auto-validate if not in quiet mode
if [[ "${PALETTE_QUIET:-false}" != "true" ]]; then
    validate_palette >/dev/null 2>&1 || {
        echo "⚠️  Warning: Color palette validation failed" >&2
    }
fi