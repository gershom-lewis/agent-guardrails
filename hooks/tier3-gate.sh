#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# TIER-3 ACTION GATE — PreToolUse hook (Phase 2: ask machinery)
# ═══════════════════════════════════════════════════════════════
# Policy lives in tier3_gate.py (single source of truth, shared with the Telegram
# bridge). Map: ~/.claude/brain/sops/governance-gate-map.md
#
# Decisions:
#   block → permissionDecision "deny"  (tool never runs; turn continues with the reason)
#   ask   → active approval scope? handled in python (becomes scoped allow).
#           No scope → permissionDecision "ask": desktop shows the native prompt,
#           the bridge routes to can_use_tool (the agent approve/deny buttons),
#           cron/headless fails closed (deny — see ENGRAM_SKIP_EXTRACT guard).
#   warn  → runs + systemMessage FYI
#   allow → runs silently (scoped allows are logged as ALLOW-SCOPED)
#
# NEVER use {"continue": false} for blocks — it halts the loop WITHOUT denying the
# tool (the 2026-06-10 incident). Audit: ~/.claude/hooks/gate-decisions.log
# (TSV: time · hook · decision · session · tool · reason)

GATE_LOG="$HOME/.claude/hooks/gate-decisions.log"

input=$(cat)

tool_name=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)
session_id=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null | cut -c1-8)

glog() { # $1 = decision, $2 = reason
  printf '%s\ttier3\t%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "${session_id:-?}" "${tool_name:-?}" "$2" \
    >> "$GATE_LOG" 2>/dev/null || true
}

# Fast-path: pure read/inert tools can never be Tier-3 — skip the python eval.
case "$tool_name" in
  Read|Glob|Grep|LS|WebSearch|WebFetch|TodoRead|TodoWrite|NotebookRead|Task|TaskOutput|AskUserQuestion|ExitPlanMode|EnterPlanMode)
    echo '{"continue": true}'; exit 0 ;;
esac

out=$(printf '%s' "$input" | python3 "$HOME/.claude/hooks/tier3_gate.py" --full 2>>"$GATE_LOG")
if [ -z "$out" ]; then
    glog "ERROR-FAILOPEN" "tier3_gate.py produced no output — allowed by fail-open (python stderr, if any, is logged above)"
    echo '{"continue": true}'; exit 0
fi

decision=$(printf '%s' "$out" | jq -r '.decision // "allow"' 2>/dev/null)
reason=$(printf '%s' "$out" | jq -r '.reason // ""' 2>/dev/null)
rule=$(printf '%s' "$out" | jq -r '.rule // ""' 2>/dev/null)
scoped=$(printf '%s' "$out" | jq -r '.scoped // false' 2>/dev/null)

# Surface-aware ask handling:
#  • cron (ENGRAM_SKIP_EXTRACT set by cron wrappers): an ask can't be answered — fail closed.
#  • bridge (GATE_SURFACE=bridge, set by the agent's SDK env): step aside so the ask reaches
#    can_use_tool, where the Telegram approve/deny buttons live. Emitting "allow" here would
#    BYPASS can_use_tool entirely — never do that; plain continue keeps the permission flow.
#  • desktop (neither): emit permissionDecision "ask" → native prompt.
if [ "$decision" = "ask" ] && [ -n "$ENGRAM_SKIP_EXTRACT" ]; then
    decision="block"
    reason="$reason [Headless run — ask-tier fails closed. Pre-mint a scope with gate-approve for this job, or surface this to the owner.]"
fi
if [ "$decision" = "ask" ] && [ "$GATE_SURFACE" = "bridge" ]; then
    glog "ASK-DEFERRED" "[$rule] deferred to bridge can_use_tool (Telegram buttons)"
    echo '{"continue": true}'
    exit 0
fi

case "$decision" in
  block)
    glog "BLOCK" "[$rule] $reason"
    jq -n --arg r "$reason" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: ("🛑 TIER-3 GATE — DENIED, this tool call did NOT execute: " + $r + " Do not retry or work around the gate. Tell the owner exactly what was blocked and why.")
      }
    }' ;;
  ask)
    glog "ASK" "[$rule] $reason"
    jq -n --arg r "$reason" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "ask",
        permissionDecisionReason: ("🟣 TIER-3 GATE — needs the owner'\''s approval: " + $r)
      }
    }' ;;
  warn)
    glog "WARN" "[$rule] $reason"
    jq -n --arg r "$reason" '{continue: true, systemMessage: ("⚠️ TIER-3 GATE: " + $r)}' ;;
  *)
    if [ "$scoped" = "true" ]; then
      glog "ALLOW-SCOPED" "[$rule] $reason"
      jq -n --arg r "$reason" '{continue: true, systemMessage: ("🟢 TIER-3 GATE: " + $r)}'
    else
      echo '{"continue": true}'
    fi ;;
esac
exit 0
