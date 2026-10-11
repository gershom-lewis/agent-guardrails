#!/bin/bash

# Automation Hardening Verification Hook
# Triggers when user mentions automation-related keywords
# Receives user prompt via stdin JSON: {"prompt": "user message"}

# Read JSON from stdin
input=$(cat)

# Extract the prompt text using jq
prompt=$(echo "$input" | jq -r '.prompt // .message // ""' 2>/dev/null)

if [[ -z "$prompt" ]]; then
    # No prompt found, exit silently
    exit 0
fi

# Convert to lowercase for case-insensitive matching
prompt_lower=$(echo "$prompt" | tr '[:upper:]' '[:lower:]')

# Define automation keywords to detect
keywords=(
    "automate"
    "automation"
    "schedule"
    "cron"
    "persistent"
    "harden"
    "hardening"
    "crontab"
    "cronjob"
    "background"
    "daemon"
    "service"
    "systemd"
    "launchd"
    "recurring"
    "repeat"
    "periodic"
)

# Define context indicators that suggest automation work (action-oriented)
automation_contexts=(
    "set up"
    "setting up"
    "create"
    "creating"
    "build"
    "building"
    "make it"
    "make this"
    "ensure this"
    "implement"
    "configure"
    "establish"
    "install"
    "deploy"
    "setup"
    "add"
    "enable"
)

# Check for automation keywords
keyword_found=false
for keyword in "${keywords[@]}"; do
    if [[ "$prompt_lower" == *"$keyword"* ]]; then
        keyword_found=true
        break
    fi
done

# If no keyword found, exit silently
if [[ "$keyword_found" == false ]]; then
    exit 0
fi

# Check if it's in an automation context (not just casual mention)
context_found=false
for context in "${automation_contexts[@]}"; do
    if [[ "$prompt_lower" == *"$context"* ]]; then
        context_found=true
        break
    fi
done

# If keyword found but no automation context, exit silently
if [[ "$context_found" == false ]]; then
    exit 0
fi

# Automation keyword + context detected - trigger hardening verification
echo "🔍 **Automation Hardening Alert**: You mentioned automation-related keywords. The automation-hardening skill will be triggered to ensure reliability and persistence." >&2

# Return JSON to inject context about automation hardening into the conversation
cat << 'EOF'
{
  "systemMessage": "⚠️ Automation keywords detected. The automation hardening verification process will be triggered automatically.",
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "AUTOMATION HARDENING TRIGGER: The user mentioned automation-related keywords in their request. Before proceeding with any automation setup, you MUST use the automation-hardening skill to ensure proper reliability verification, persistence checking, error handling, and monitoring setup. Read ~/.claude/skills/automation-hardening/SKILL.md for the complete checklist. This is MANDATORY for all automation tasks - no exceptions."
  }
}
EOF