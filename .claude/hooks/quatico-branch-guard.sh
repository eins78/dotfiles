#!/bin/bash
# Quatico branch guard (DEC-003a, decided by Max 2026-08-07).
#
# In the Quatico company workspace the standing "commit and push to the trunk"
# rule is INVERTED: a q- delegate works on a branch and pushes only there. It
# must never push develop. Max: "in long session this sometimes needs to be
# repeated, but in my experience being on a branch is the best mitigation."
# An instruction that needs repeating is a rule, and rules drift — CLAUDE.md
# "Gates Over Rules" says make it a gate. This is that gate.
#
# SCOPE: only fires when cwd is inside ~/OPS/quatico-company-workspace (which
# covers its .claude/worktrees/* too). Every other repo is untouched — home's
# own push-to-main rule keeps working.
#
# SEMANTICS: the test is "not develop", NOT "matches some branch prefix".
# Max accepted worktree-* branch names on 2026-08-07, so a prefix allowlist
# would reject the branch `agi -w` actually creates.
#
# THIS IS A TRIPWIRE, NOT A PROOF. It catches the common forms (a push naming
# develop as a ref; any push made while standing on develop; checking develop
# out). A sufficiently indirect command can still get through. It raises the
# floor; it does not make the constraint unreachable.
#
# FAIL OPEN, ALWAYS. This runs PreToolUse on every Bash call in every session
# on this machine, including homebot's own. A crash here that exited non-zero
# would block all shell use. So: no `set -e`, no `set -u`, no pipefail, and
# `exit 0` is unconditionally reachable at the end.

INPUT=$(cat 2>/dev/null)
[ -z "$INPUT" ] && exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)

[ -z "$COMMAND" ] && exit 0
[ -z "$CWD" ] && exit 0

# Scope: Quatico workspace only (root or any worktree beneath it).
case "$CWD" in
  "$HOME"/OPS/quatico-company-workspace | "$HOME"/OPS/quatico-company-workspace/*) ;;
  *) exit 0 ;;
esac

# Match `develop` only as a whole ref token: preceded by start / whitespace /
# `:` (HEAD:develop) / `/` (refs/heads/develop), and followed by whitespace or
# end. This deliberately does NOT match a branch merely containing the word,
# e.g. `worktree-develop-notes`.
DEVELOP_REF='(^|[[:space:]]|:|/)develop([[:space:]]|$)'

deny() {
  echo "GATE (quatico-branch-guard): $1" >&2
  echo "" >&2
  echo "The Quatico workspace inverts the usual push rule: work on a branch," >&2
  echo "push only there, never to develop. Merging to develop is Max's call." >&2
  echo "The rule is 'not develop' — any other branch name is fine, including" >&2
  echo "the worktree-<task> branch that 'agi -w' creates." >&2
  echo "" >&2
  echo "Ref: home CLAUDE.md 'Gates Over Rules'; delegate skill" >&2
  echo "'Local delegates — Quatico workspace (q- sessions)'; DEC-003a." >&2
  exit 2
}

if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:];&|])git[[:space:]]+push'; then
  # Form 1: the command names develop as a ref.
  if printf '%s' "$COMMAND" | grep -qE "$DEVELOP_REF"; then
    deny "blocked a git push naming 'develop'."
  fi

  # Form 2: a bare `git push` made while standing on develop. This is the
  # sneaky one — nothing in the command text says 'develop'.
  BRANCH=$(git -C "$CWD" symbolic-ref --short HEAD 2>/dev/null)
  if [ "$BRANCH" = "develop" ]; then
    deny "blocked a git push while HEAD is on 'develop'."
  fi
fi

# Checking develop out is how a session ends up on it in the first place.
# `git checkout -b foo develop` / `git switch -c foo develop` are legitimate
# (branching off develop) and stay allowed.
if printf '%s' "$COMMAND" | grep -qE '(^|[[:space:];&|])git[[:space:]]+(checkout|switch)'; then
  if printf '%s' "$COMMAND" | grep -qE "$DEVELOP_REF"; then
    if ! printf '%s' "$COMMAND" | grep -qE '[[:space:]]-(b|c|-track)([[:space:]]|=|$)'; then
      deny "blocked checking out 'develop'. Branch off it instead: git checkout -b <name> develop"
    fi
  fi
fi

exit 0
