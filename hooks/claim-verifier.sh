#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# CLAIM VERIFIER — Stop Hook
# ═══════════════════════════════════════════════════════════════
# HARD LAYER enforcement. Fires when Claude finishes responding.
# Scans the last response for unverified availability claims.
# If Claude said "not available" without checking credentials,
# BLOCKS the stop and forces a correction.
#
# Anti-loop: checks if we already intervened OR if credentials
# were actually examined this turn.
#
# This is the safety net. If Layers 1-3 all fail and Claude
# still makes an unverified claim, this catches it.

input=$(cat)

transcript_path=$(echo "$input" | jq -r '.transcript_path // ""')
session_id=$(echo "$input" | jq -r '.session_id // "unknown"')

# ── Bail if no transcript available ──
if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    exit 0
fi

# ── Anti-loop: check if we already intervened this turn ──
# Look for our specific enforcement message in recent transcript
if tail -20 "$transcript_path" | grep -q "HARD RULE ENFORCEMENT: UNVERIFIED CLAIM"; then
    exit 0
fi

# ── Extract ONLY the text of Claude's LAST assistant message ──
# The transcript is JSONL. We must judge what Claude actually SAID to the user —
# NOT tool outputs, file contents, web-search results, or thinking blocks, all
# of which routinely contain phrases like "not available" and used to trigger
# false positives that blocked legitimate replies (and derailed the agent on the
# Telegram bridge). Fail OPEN: on any parse error, emit empty → allow the stop.
last_response=$(python3 - "$transcript_path" <<'PYEOF' 2>/dev/null
import sys, json
path = sys.argv[1]
out = ""
try:
    with open(path) as f:
        lines = f.readlines()
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("type") != "assistant":
            continue
        content = obj.get("message", {}).get("content", [])
        texts = []
        if isinstance(content, list):
            for b in content:
                if isinstance(b, dict) and b.get("type") == "text":
                    texts.append(b.get("text", ""))
        elif isinstance(content, str):
            texts.append(content)
        if texts:
            out = "\n".join(texts)
            break
except Exception:
    out = ""
print(out)
PYEOF
)

# ── Availability claim patterns ──
# These are the specific phrases that indicate Claude claimed something
# is unavailable. Now matched ONLY against Claude's final user-facing message.
claim_patterns="not connected|not available|no credentials found|isn't set up|isn't connected|aren't available|not configured|no API key|unable to connect to|cannot access.*api|don't have.*credentials|don't have access to|isn't integrated|no integration"

if ! echo "$last_response" | grep -qEi "$claim_patterns"; then
    # No availability claim in Claude's actual reply — allow the stop
    exit 0
fi

# ── Claim found. Check if credentials were actually examined this turn. ──
# Look for evidence that Claude ran a credential check
cred_check_evidence="credentials/|credential-preflight|\.env|CREDENTIAL INVENTORY"

# Check recent tool calls for credential examination
recent_tools=$(tail -50 "$transcript_path" 2>/dev/null)

if echo "$recent_tools" | grep -qEi "$cred_check_evidence"; then
    # Claude DID check credentials — the claim is legitimate. Allow.
    exit 0
fi

# ── VIOLATION: Unverified availability claim ──
# Block the stop and force a correction.

CRED_DIR="$HOME/.claude/credentials"
services=$(ls "$CRED_DIR"/*.env 2>/dev/null | xargs -I{} basename {} .env | sort | tr '\n' ', ' | sed 's/,$//')

enforcement_msg="HARD RULE ENFORCEMENT: UNVERIFIED CLAIM DETECTED. You claimed a service is unavailable WITHOUT checking credentials. This is blocked. You MUST now: (1) Run: ls ~/.claude/credentials/ (2) Run: ~/.claude/hooks/credential-preflight.sh [service-name] for any service you claimed is unavailable (3) If credentials exist, use them and correct your response (4) If genuinely not found after checking, explain what you checked. Available credential files: ${services}"

echo "$enforcement_msg" | jq -Rs '{
    decision: "block",
    systemMessage: ("🔴 " + .)
}'
