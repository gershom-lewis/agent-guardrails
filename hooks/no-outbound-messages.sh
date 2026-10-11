#!/bin/bash

# No Outbound Messages — Hard-Layer Safety Hook
# PreToolUse hook that BLOCKS any tool call that would send a message
# to a person without explicit approval.
#
# SOP: ~/.claude/brain/sops/no-outbound-messages.md
# Incident: Agent sent unauthorized test message to a contact.
# This hook enforces the rule at the ENGINE level — LLM cannot bypass it.
#
# ENFORCEMENT (fixed 2026-06-10): blocks emit PreToolUse permissionDecision:"deny",
# which DENIES the pending tool call (the send never fires) and lets the turn
# continue so Claude can explain and ask for approval.
# NEVER use {"continue": false} for blocks — in the current hooks protocol it
# halts the agent loop WITHOUT denying the tool call (the send would still go out).
# All blocks are appended to ~/.claude/hooks/gate-decisions.log.

GATE_LOG="$HOME/.claude/hooks/gate-decisions.log"

input=$(cat)

tool_name=$(echo "$input" | jq -r '.tool_name // "unknown"')
session_id=$(echo "$input" | jq -r '.session_id // ""' 2>/dev/null | cut -c1-8)

glog() { # $1 = decision, $2 = reason
  printf '%s\tno-outbound\t%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "${session_id:-?}" "${tool_name:-?}" "$2" \
    >> "$GATE_LOG" 2>/dev/null || true
}

deny() { # $1 = short tag for log, $2 = full reason shown to Claude
  glog "BLOCK" "$1"
  jq -n --arg r "$2" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("🛑 BLOCKED — this tool call was DENIED and did NOT execute: " + $r)
    }
  }'
  exit 0
}

# ── Phase 3: global TEST MODE overlay (shared policy in gate_testmode.py) ──
# When test mode is on, sends to non-test recipients are denied; verified test
# targets pass. Decided by the SAME module the tier3 gate uses (single source of
# truth). "none" => test mode off or not a send → fall through to normal rules.
# Fast-path: only spawn the python check when the state file says test mode is ON
# (the common case is OFF — skip the subprocess entirely then).
TM_STATE="$HOME/.claude/hooks/.gate-testmode.json"
if ! grep -qs '"on": *true' "$TM_STATE" 2>/dev/null; then
    tm_decision="none"
else
    tm_out=$(printf '%s' "$input" | python3 "$HOME/.claude/hooks/gate_testmode.py" --check 2>/dev/null)
    tm_decision=$(printf '%s' "$tm_out" | jq -r '.decision // "none"' 2>/dev/null)
fi
if [ "$tm_decision" = "deny" ]; then
    tm_reason=$(printf '%s' "${tm_out:-}" | jq -r '.reason // ""' 2>/dev/null)
    glog "BLOCK" "testmode deny ($tool_name)"
    jq -n --arg r "$tm_reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    exit 0
elif [ "$tm_decision" = "allow" ]; then
    tm_reason=$(printf '%s' "$tm_out" | jq -r '.reason // ""' 2>/dev/null)
    glog "ALLOW-TESTTARGET" "$tool_name"
    jq -n --arg r "$tm_reason" '{continue: true, systemMessage: $r}'
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# C1: iMessage / SMS send — ask-tier (gate map). An active C1 approval scope
# (minted by gate-approve after the owner's explicit ok, or the agent's buttons) lets
# the send proceed with an FYI; otherwise hard-deny with mint instructions.
# ═══════════════════════════════════════════════════════════════
if echo "$tool_name" | grep -qi "send_imessage"; then
    c1_scope=$(python3 -c "import sys; sys.path.insert(0,'$HOME/.claude/hooks'); import gate_scopes; s=gate_scopes.match('C1'); print(s['id'] if s else '')" 2>/dev/null)
    if [ -n "$c1_scope" ]; then
        glog "ALLOW-SCOPED" "imessage-send via scope $c1_scope"
        cat <<'WARN'
{
    "continue": true,
    "systemMessage": "🟢 NO-OUTBOUND GATE: iMessage send approved by an active C1 scope (the owner's prior approval) — proceeding. Confirm the message matches what the owner approved."
}
WARN
        exit 0
    fi
    deny "imessage-send" "iMessage send intercepted (C1). Sending messages to ANY person requires the owner's explicit approval for THAT specific message to THAT specific recipient. If the owner approves in conversation, mint: ~/.claude/hooks/gate-approve C1 --quote \"<the owner's exact words>\" --by owner-desktop-chat — then retry."
fi

# ═══════════════════════════════════════════════════════════════
# HARD BLOCK: Bash commands that send messages
# ═══════════════════════════════════════════════════════════════
if [ "$tool_name" = "Bash" ] || [ "$tool_name" = "PowerShell" ] || [ "$tool_name" = "Cmd" ]; then
    command_text=$(echo "$input" | jq -r '.tool_input.command // ""')
    [ "$tool_name" = "PowerShell" ] && command_text="powershell -Command $command_text"
    [ "$tool_name" = "Cmd" ] && command_text="cmd /c $command_text"

    # Is this command an ACTUAL send (curl/wget write, real send-script, inline send
    # code) vs. a read that merely MENTIONS a channel (grep pattern, echo, filename)?
    # Same detector the tier3 gate uses (gate_shared.command_sends). Only computed
    # when a channel keyword is even present, so reads pay nothing. This is what stops
    # `grep "curl -X POST ... resend.com/emails" file` from being treated as a send.
    real_send=0
    if echo "$command_text" | grep -qiE "resend\.com/emails|api\.telegram\.org|bluebubbles|circle\.so|localhost:1234|/api/v1/(message|chat)"; then
        real_send=$(GATE_CMD="$command_text" python3 -c "import os,sys; sys.path.insert(0,os.path.expanduser('~/.claude/hooks')); import gate_shared; print('1' if gate_shared.command_sends(os.environ.get('GATE_CMD','')) else '0')" 2>/dev/null)
        [ "$real_send" = "1" ] || real_send=0
    fi

    # C4 (gate map 2026-06-10): single Resend email sends are WARN — they proceed
    # with an FYI. the owner's #1 rule still applies at the behavior layer: confirm THIS
    # message to THIS recipient in conversation before sending. TARGET: per-map.
    if [ "$real_send" = "1" ] && echo "$command_text" | grep -qi "resend\.com/emails"; then
        glog "WARN" "resend-email-send"
        cat <<'WARN'
{
    "continue": true,
    "systemMessage": "⚠️ EMAIL SEND (C4 — warn tier): Resend API send proceeding. the owner's #1 rule still applies — this exact message to this exact recipient must have been approved in conversation. If it wasn't, stop and ask BEFORE the next send."
}
WARN
        exit 0
    fi

    # C11: raw Telegram API sends are blocked — EXCEPT sendMessage to the owner's OWN
    # chat (<owner-chat>). That's the /notify path; messaging the owner himself is never an
    # unauthorized outbound to "another person," so it must NOT be gated (this was
    # the catch-22 that hard-stopped turns right before the session report — the gate
    # blocked the one approved notify path). Any OTHER chat_id stays hard-blocked
    # (the real risk: the bot DMing someone else). real_send guards out grep/echo reads.
    # D-1 fix: cover sendPhoto/sendDocument/sendVideo/etc, not just sendMessage — a real
    # media send to a non-the owner chat is the same outbound risk.
    if [ "$real_send" = "1" ] && echo "$command_text" | grep -qiE "api\.telegram\.org.*send(Message|Photo|Document|Video|Audio|Voice|Animation|MediaGroup|Sticker|Location|Contact)"; then
        # Owner's own chat is the only allowed raw-Telegram target (the /notify path).
        # Read it from gate-config.json. Empty => NO carve-out => every raw send is blocked.
        owner_chat=$(python3 -c "import os,sys; sys.path.insert(0,os.path.expanduser('~/.claude/hooks')); import gate_config; print(gate_config.OWNER_TELEGRAM_CHAT_ID)" 2>/dev/null)
        if [ -n "$owner_chat" ] && echo "$command_text" | grep -qE "chat_id[^0-9]{0,4}${owner_chat}"; then
            glog "ALLOW-SELF" "telegram notify to owner chat ($owner_chat) — approved /notify path"
            echo '{"continue": true}'
            exit 0
        fi
        deny "telegram-api-send" "Telegram API send (message/photo/document/etc) to a non-owner chat intercepted. Only the owner's own configured chat (gate-config.json owner_telegram_chat_id) is allowed; everything else is blocked."
    fi

    # Block osascript message sends — VERB-aware: osascript must actually be INVOKED and
    # involve messaging (A3 fix), so `echo 'osascript … send a message'` / greps fall through.
    if echo "$command_text" | grep -qi "osascript"; then
        osa_send=$(GATE_CMD="$command_text" python3 -c "import os,sys; sys.path.insert(0,os.path.expanduser('~/.claude/hooks')); import gate_shared; print('1' if gate_shared.osascript_sends(os.environ.get('GATE_CMD','')) else '0')" 2>/dev/null)
        if [ "$osa_send" = "1" ]; then
            deny "osascript-send" "AppleScript message send intercepted. Sending messages via osascript is blocked. Ask the owner for explicit approval."
        fi
    fi

    # D-3 fix: BlueBubbles real sends — the keyword OR the localhost message/chat send path.
    # real_send (command_sends) guards out reads/greps; localhost path now triggers real_send.
    if [ "$real_send" = "1" ] && echo "$command_text" | grep -qiE "bluebubbles|localhost:1234/api/v1/(message|chat)|/api/v1/message/text|/api/v1/chat/new"; then
        deny "bluebubbles-send" "BlueBubbles/iMessage API send intercepted (incl. the localhost:1234 message path). This is the exact API that caused the original incident. Blocked — get the owner's explicit approval."
    fi

    # C7: Circle production posts are WARN — proceed with FYI. Posts to the configured
    # QA staging space (gate-config.json test_circle_space_id) stay fully free. Empty =>
    # all Circle posts warn. real_send guards out grep/echo reads.
    if [ "$real_send" = "1" ] && echo "$command_text" | grep -qi "circle\.so.*posts"; then
        qa_space=$(python3 -c "import os,sys; sys.path.insert(0,os.path.expanduser('~/.claude/hooks')); import gate_config; print(gate_config.TEST_CIRCLE_SPACE)" 2>/dev/null)
        if [ -z "$qa_space" ] || ! echo "$command_text" | grep -q "$qa_space"; then
            glog "WARN" "circle-prod-post"
            cat <<'WARN'
{
    "continue": true,
    "systemMessage": "⚠️ CIRCLE PROD POST (C7 — warn tier): posting to a production Circle space. QA-first practice still applies — verify in your QA space before production, and confirm the owner approved this post."
}
WARN
            exit 0
        fi
    fi
fi

# ═══════════════════════════════════════════════════════════════
# WARN: Gmail draft creation (allowed but flagged)
# ═══════════════════════════════════════════════════════════════
if echo "$tool_name" | grep -qi "create_draft"; then
    glog "WARN" "gmail-draft-creation"
    cat <<'WARN'
{
    "continue": true,
    "systemMessage": "⚠️ NO-OUTBOUND-MESSAGES HOOK: Gmail draft creation detected. Drafts are allowed (they don't auto-send), but remember:\n- NEVER auto-send. Drafts only.\n- Confirm recipient and content with the owner before creating.\n- The draft will appear in the owner's Gmail — make sure it's intentional."
}
WARN
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
# WARN: Agent spawning with messaging context
# ═══════════════════════════════════════════════════════════════
if [ "$tool_name" = "Agent" ]; then
    agent_prompt=$(echo "$input" | jq -r '.tool_input.prompt // ""')
    if echo "$agent_prompt" | grep -qi "\(send.*message\|send.*email\|imessage\|bluebubbles\|resend.*api\|telegram.*send\|circle.*post\|outbound\)"; then
        glog "WARN" "subagent-with-messaging-context"
        cat <<'WARN'
{
    "continue": true,
    "systemMessage": "⚠️ NO-OUTBOUND-MESSAGES HOOK: Sub-agent with messaging context detected. Ensure the agent prompt includes the mandatory no-send block from ~/.claude/brain/sops/no-outbound-messages.md:\n\n'ABSOLUTE RULE: Do NOT send any messages, emails, texts, DMs, or any outbound communication to ANY person. This is READ-ONLY validation. No POST requests to message/send endpoints. No test messages. No exceptions.'\n\nIf this agent needs to SEND anything, get the owner's explicit approval first."
}
WARN
        exit 0
    fi
fi

# ═══════════════════════════════════════════════════════════════
# ALLOW: Everything else passes through
# ═══════════════════════════════════════════════════════════════
echo '{"continue": true}'
