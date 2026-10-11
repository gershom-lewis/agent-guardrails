#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# CREDENTIAL PRE-FLIGHT — Deterministic Inventory Script
# ═══════════════════════════════════════════════════════════════
# Standalone script. Called by other hooks and by Claude directly.
# Usage: ./credential-preflight.sh [service-name]
# Returns structured inventory of all credentials (or specific match).
#
# HARD LAYER: This is deterministic code, not an LLM suggestion.
# If this script says a credential exists, it exists. Period.

CRED_DIR="$HOME/.claude/credentials"
ENV_LOCATIONS=(
    "$HOME/Desktop/claude-agent-system/telegram-bridge/.env"
    "$HOME/Desktop/claude-agent-system/.env"
)

if [ ! -d "$CRED_DIR" ]; then
    echo "ERROR: Credential directory not found at $CRED_DIR"
    exit 1
fi

service_filter="${1:-}"

if [ -n "$service_filter" ]; then
    # ── Targeted search for a specific service ──
    filter_lower=$(echo "$service_filter" | tr '[:upper:]' '[:lower:]')
    found=0

    for env_file in "$CRED_DIR"/*.env; do
        [ -f "$env_file" ] || continue
        basename_lower=$(basename "$env_file" .env | tr '[:upper:]' '[:lower:]')

        if echo "$basename_lower" | grep -q "$filter_lower"; then
            found=1
            keys=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$env_file" 2>/dev/null | cut -d= -f1 | tr '\n' ', ' | sed 's/,$//')
            echo "FOUND: $env_file"
            echo "  Keys: $keys"
        fi
    done

    # Also check project .env files
    for env_file in "${ENV_LOCATIONS[@]}"; do
        if [ -f "$env_file" ] && grep -qi "$filter_lower" "$env_file" 2>/dev/null; then
            found=1
            keys=$(grep -i "$filter_lower" "$env_file" | grep -E '^[A-Za-z_]' | cut -d= -f1 | tr '\n' ', ' | sed 's/,$//')
            echo "FOUND: $env_file"
            echo "  Matching keys: $keys"
        fi
    done

    if [ "$found" -eq 0 ]; then
        echo "NOT FOUND: No credentials matching '$service_filter'"
        echo ""
        echo "Available services:"
        ls "$CRED_DIR"/*.env 2>/dev/null | xargs -I{} basename {} .env | sort | column
    fi
else
    # ── Full inventory ──
    echo "=== CREDENTIAL INVENTORY ==="
    echo "Directory: $CRED_DIR"
    echo "Count: $(ls "$CRED_DIR"/*.env 2>/dev/null | wc -l | tr -d ' ') credential files"
    echo ""

    for env_file in "$CRED_DIR"/*.env; do
        [ -f "$env_file" ] || continue
        svc=$(basename "$env_file" .env)
        keys=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$env_file" 2>/dev/null | cut -d= -f1 | tr '\n' ', ' | sed 's/,$//')
        printf "  %-25s %s\n" "$svc:" "$keys"
    done

    echo ""
    echo "Project .env files:"
    for env_file in "${ENV_LOCATIONS[@]}"; do
        if [ -f "$env_file" ]; then
            echo "  $env_file"
        fi
    done
fi
