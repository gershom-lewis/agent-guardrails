#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# CREDENTIAL AWARENESS — UserPromptSubmit Hook
# ═══════════════════════════════════════════════════════════════
# Injects credential inventory as factual context so Claude knows
# what services have credentials on file. Phrased as facts, not
# imperatives, to avoid false-positive prompt injection detection.
#
# Fires on EVERY user prompt. Two modes:
#   1. ALWAYS: Compact service list (~30 tokens)
#   2. ENHANCED: When user mentions a specific service or asks about availability

input=$(cat)
prompt=$(echo "$input" | jq -r '.prompt // ""' 2>/dev/null)

if [ -z "$prompt" ]; then
    echo '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":""}}'
    exit 0
fi

CRED_DIR="$HOME/.claude/credentials"

# ── Build compact service list ──
if [ -d "$CRED_DIR" ]; then
    services=$(ls "$CRED_DIR"/*.env 2>/dev/null | xargs -I{} basename {} .env | sort | tr '\n' ', ' | sed 's/,$//')
    count=$(ls "$CRED_DIR"/*.env 2>/dev/null | wc -l | tr -d ' ')
else
    services="CREDENTIAL_DIR_MISSING"
    count=0
fi

# ── Base context (always injected, factual tone) ──
ctx="Credential registry: ${count} services have API credentials at ~/.claude/credentials/: ${services}."

# ── Check for availability-related keywords ──
prompt_lower=$(echo "$prompt" | tr '[:upper:]' '[:lower:]')
avail_pattern="available|connected|set up|configured|credential|api key|not working|can.t access|unable to|no access|missing.*key|hook up|integrate with|connect to"

if echo "$prompt_lower" | grep -qEi "$avail_pattern"; then
    ctx="${ctx} This prompt references service availability. The claim-verifier Stop hook will block any response that claims a service is unavailable without first checking this directory."
fi

# ── Specific service mention → inject that service's key names (fully dynamic) ──
# Loop the customer's OWN credential files; if the prompt names a service, surface its keys.
# No hardcoded service list — adapts to whatever credentials the customer has on file.
if [ -d "$CRED_DIR" ]; then
    for svc_file in "$CRED_DIR"/*.env; do
        [ -f "$svc_file" ] || continue
        svc_name=$(basename "$svc_file" .env)
        svc_alias="${svc_name%%-*}"
        if echo "$prompt_lower" | grep -qiE "(${svc_name}|${svc_alias})"; then
            keys=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$svc_file" 2>/dev/null | cut -d= -f1 | tr '\n' ', ' | sed 's/,$//')
            ctx="${ctx} ${svc_name} credentials exist at ${svc_file} with keys: ${keys}."
        fi
    done
fi

# ── Output ──
echo "$ctx" | jq -Rs '{
    hookSpecificOutput: {
        hookEventName: "UserPromptSubmit",
        additionalContext: .
    }
}'
