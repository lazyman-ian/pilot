#!/usr/bin/env bash
# scripts/lib/error-fmt.sh
# Shared AI-friendly error formatting for validation scripts.
# Source this file, then call blocked/warn functions.

pilot_blocked() {
  local reason="$1" why="$2" fix="$3" context="$4"
  echo "[BLOCKED] $reason"
  echo "WHY: $why"
  echo "FIX: $fix"
  [ -n "$context" ] && echo "CONTEXT: $context"
}

pilot_warn() {
  local reason="$1" detail="$2"
  echo "[WARNING] $reason"
  [ -n "$detail" ] && echo "DETAIL: $detail"
}
