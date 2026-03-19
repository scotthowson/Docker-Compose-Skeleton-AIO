#!/bin/bash
# =============================================================================
# Plugin System v1.0
# Discover, install, and manage extensions for Docker Compose Skeleton
# Plugins live in .plugins/ and follow a standard manifest format (plugin.json)
#
# Dependencies: git (for install from URL)
# Requires: Bash 4+
# =============================================================================

if [[ -z "${BASE_DIR:-}" ]]; then
    BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

PLUGINS_DIR="${BASE_DIR}/.plugins"
PLUGINS_HOOKS_ENABLED="${PLUGINS_HOOKS_ENABLED:-true}"

# =============================================================================
# INITIALIZATION
# =============================================================================

plugins_init() {
    if [[ ! -d "$PLUGINS_DIR" ]]; then
        mkdir -p "$PLUGINS_DIR"
    fi
    if [[ ! -f "$PLUGINS_DIR/.gitignore" ]]; then
        echo '*/' > "$PLUGINS_DIR/.gitignore"
    fi
}

# =============================================================================
# DISCOVERY & LISTING
# =============================================================================

# Scan plugins directory and return JSON array
plugins_scan() {
    plugins_init
    local result="["
    local first=true

    for plugin_dir in "$PLUGINS_DIR"/*/; do
        [[ ! -d "$plugin_dir" ]] && continue
        local manifest="$plugin_dir/plugin.json"
        [[ ! -f "$manifest" ]] && continue

        local name version description author
        name=$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest" | head -1 | cut -d'"' -f4)
        version=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest" | head -1 | cut -d'"' -f4)
        description=$(grep -o '"description"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest" | head -1 | cut -d'"' -f4)
        author=$(grep -o '"author"[[:space:]]*:[[:space:]]*"[^"]*"' "$manifest" | head -1 | cut -d'"' -f4)

        name="${name:-$(basename "$plugin_dir")}"
        version="${version:-0.0.0}"
        description="${description:-}"
        author="${author:-}"

        # Count templates
        local templates="["
        local tfirst=true
        for tmpl_dir in "$plugin_dir/templates"/*/; do
            [[ ! -d "$tmpl_dir" ]] && continue
            [[ "$tfirst" == "true" ]] && tfirst=false || templates+=","
            templates+="\"$(basename "$tmpl_dir")\""
        done
        templates+="]"

        # Count hooks
        local hooks="["
        local hfirst=true
        for hook_file in "$plugin_dir/hooks"/*; do
            [[ ! -f "$hook_file" ]] && continue
            [[ "$hfirst" == "true" ]] && hfirst=false || hooks+=","
            hooks+="\"$(basename "$hook_file")\""
        done
        hooks+="]"

        # Check enabled state
        local enabled="true"
        [[ -f "$plugin_dir/.disabled" ]] && enabled="false"

        [[ "$first" == "true" ]] && first=false || result+=","
        result+="{\"name\":\"$name\",\"version\":\"$version\",\"description\":\"$description\",\"author\":\"$author\",\"templates\":$templates,\"hooks\":$hooks,\"enabled\":$enabled}"
    done

    result+="]"
    echo "$result"
}

# List all installed plugins
plugins_list() {
    plugins_scan
}

# Get details of a specific plugin
plugins_get() {
    local name="$1"
    local plugin_dir="$PLUGINS_DIR/$name"

    if [[ ! -d "$plugin_dir" ]]; then
        echo '{"error":"Plugin not found"}'
        return 1
    fi

    local manifest="$plugin_dir/plugin.json"
    if [[ -f "$manifest" ]]; then
        cat "$manifest"
    else
        echo "{\"name\":\"$name\",\"error\":\"No manifest found\"}"
    fi
}

# =============================================================================
# INSTALL / REMOVE
# =============================================================================

# Install a plugin from a git URL
# Usage: plugins_install git_url
plugins_install() {
    local source="$1"
    plugins_init

    # Extract name from URL
    local name
    name=$(basename "$source" .git)
    name="${name:-unknown-plugin}"

    local target="$PLUGINS_DIR/$name"

    if [[ -d "$target" ]]; then
        echo "{\"success\":false,\"message\":\"Plugin '$name' already installed\",\"plugin\":{\"name\":\"$name\"}}"
        return 1
    fi

    # Clone
    if git clone --depth 1 "$source" "$target" 2>/dev/null; then
        # Validate
        if [[ ! -f "$target/plugin.json" ]]; then
            rm -rf "$target"
            echo "{\"success\":false,\"message\":\"Invalid plugin: no plugin.json manifest found\"}"
            return 1
        fi

        local plugin_json
        plugin_json=$(plugins_get "$name")
        echo "{\"success\":true,\"message\":\"Plugin '$name' installed successfully\",\"plugin\":$plugin_json}"
    else
        echo "{\"success\":false,\"message\":\"Failed to clone from: $source\"}"
        return 1
    fi
}

# Remove a plugin
plugins_remove() {
    local name="$1"
    local target="$PLUGINS_DIR/$name"

    if [[ ! -d "$target" ]]; then
        echo "{\"success\":false,\"name\":\"$name\",\"message\":\"Plugin not found\"}"
        return 1
    fi

    rm -rf "$target"
    echo "{\"success\":true,\"name\":\"$name\"}"
}

# =============================================================================
# ENABLE / DISABLE
# =============================================================================

plugins_enable() {
    local name="$1"
    local marker="$PLUGINS_DIR/$name/.disabled"
    if [[ -f "$marker" ]]; then
        rm -f "$marker"
    fi
    plugins_get "$name"
}

plugins_disable() {
    local name="$1"
    local marker="$PLUGINS_DIR/$name/.disabled"
    touch "$marker" 2>/dev/null
    plugins_get "$name"
}

# =============================================================================
# HOOKS
# =============================================================================

# Run all hooks matching an event across enabled plugins
# Events: pre-start, post-start, pre-stop, post-stop, pre-update, post-update, pre-deploy, post-deploy
# Usage: plugins_run_hook event_name [context_json]
plugins_run_hook() {
    local event="$1"
    local context="${2:-{}}"

    [[ "$PLUGINS_HOOKS_ENABLED" != "true" ]] && return 0

    local results="["
    local first=true

    for plugin_dir in "$PLUGINS_DIR"/*/; do
        [[ ! -d "$plugin_dir" ]] && continue
        [[ -f "$plugin_dir/.disabled" ]] && continue

        local hook_script="$plugin_dir/hooks/$event"
        [[ -f "$hook_script" && -x "$hook_script" ]] || {
            # Also try with .sh extension
            hook_script="$plugin_dir/hooks/${event}.sh"
            [[ -f "$hook_script" && -x "$hook_script" ]] || continue
        }

        local plugin_name
        plugin_name=$(basename "$plugin_dir")
        local output
        output=$(echo "$context" | "$hook_script" 2>&1) || true

        local esc_output
        esc_output=$(printf '%s' "$output" | head -c 500 | sed 's/"/\\"/g; s/\n/\\n/g')

        [[ "$first" == "true" ]] && first=false || results+=","
        results+="{\"plugin\":\"$plugin_name\",\"hook\":\"$event\",\"output\":\"$esc_output\"}"
    done

    results+="]"
    echo "$results"
}

# =============================================================================
# TEMPLATE AGGREGATION
# =============================================================================

# List all templates from all enabled plugins
plugins_list_templates() {
    local result="["
    local first=true

    for plugin_dir in "$PLUGINS_DIR"/*/; do
        [[ ! -d "$plugin_dir" ]] && continue
        [[ -f "$plugin_dir/.disabled" ]] && continue

        local plugin_name
        plugin_name=$(basename "$plugin_dir")

        for tmpl_dir in "$plugin_dir/templates"/*/; do
            [[ ! -d "$tmpl_dir" ]] && continue
            local tmpl_name
            tmpl_name=$(basename "$tmpl_dir")

            [[ "$first" == "true" ]] && first=false || result+=","
            result+="{\"name\":\"$tmpl_name\",\"plugin\":\"$plugin_name\",\"path\":\"$tmpl_dir\"}"
        done
    done

    result+="]"
    echo "$result"
}

# =============================================================================
# VALIDATION
# =============================================================================

# Validate a plugin's structure
plugins_validate() {
    local name="$1"
    local plugin_dir="$PLUGINS_DIR/$name"
    local issues="["
    local first=true
    local valid=true

    if [[ ! -d "$plugin_dir" ]]; then
        echo '{"valid":false,"issues":["Plugin directory not found"]}'
        return 1
    fi

    if [[ ! -f "$plugin_dir/plugin.json" ]]; then
        [[ "$first" == "true" ]] && first=false || issues+=","
        issues+="\"Missing plugin.json manifest\""
        valid=false
    fi

    # Check hooks are executable
    for hook in "$plugin_dir/hooks"/*; do
        [[ ! -f "$hook" ]] && continue
        if [[ ! -x "$hook" ]]; then
            [[ "$first" == "true" ]] && first=false || issues+=","
            issues+="\"Hook not executable: $(basename "$hook")\""
            valid=false
        fi
    done

    issues+="]"
    echo "{\"valid\":$valid,\"name\":\"$name\",\"issues\":$issues}"
}
