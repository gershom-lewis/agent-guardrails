#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# CREDENTIAL GUARD — PostToolUse Hook (Bash matcher)
# ═══════════════════════════════════════════════════════════════
# Fires after Bash commands complete. Detects auth-related failures
# and injects credential check instructions before Claude gives up.
#
# This catches the pattern: Claude tries an API call → gets 401/403 →
# concludes the service isn't available → never checks credentials.

input=$(cat)

tool_name=$(echo "$input" | jq -r '.tool_name // "unknown"')

# Only process Bash tool results
if [ "$tool_name" != "Bash" ]; then
    echo '{"continue": true}'
    exit 0
fi

# Get the tool input (command that was run)
command_text=$(echo "$input" | jq -r '.tool_input.command // ""')

# Check if this was an API/curl command
if ! echo "$command_text" | grep -qEi "curl|wget|http|api|fetch"; then
    echo '{"continue": true}'
    exit 0
fi

# Read stdout/stderr from the tool result
# PostToolUse receives tool_output in some implementations
tool_output=$(echo "$input" | jq -r '.tool_output // .stdout // ""' 2>/dev/null)
tool_error=$(echo "$input" | jq -r '.stderr // ""' 2>/dev/null)
combined="$tool_output $tool_error"

# Auth failure patterns
auth_patterns="401|403|unauthorized|forbidden|invalid.*token|invalid.*key|authentication.*fail|access.*denied|not.*authenticated|invalid.*credentials|expired.*token|api.*key.*invalid|permission.*denied"

if echo "$combined" | grep -qEi "$auth_patterns"; then
    # Auth failure detected — inject credential check instructions
    CRED_DIR="$HOME/.claude/credentials"
    services=$(ls "$CRED_DIR"/*.env 2>/dev/null | xargs -I{} basename {} .env | sort | tr '\n' ', ' | sed 's/,$//')

    msg="AUTH FAILURE DETECTED in API call. Before concluding this service is unavailable, check credentials: ls ~/.claude/credentials/ (available: ${services}). Run ~/.claude/hooks/credential-preflight.sh [service-name] for details. The credential may exist but not be loaded — source the .env file and retry."

    echo "$msg" | jq -Rs '{
        continue: true,
        systemMessage: ("🔑 " + .)
    }'
    exit 0
fi

echo '{"continue": true}'
