#!/usr/bin/env bash
# Failure taxonomy shared by wrappers and the dispatcher.
# classify_failure <context> <rc> <text> -> transient|agent|code|policy|configuration
classify_failure() {
  local context="${1:-}" rc="${2:-1}" text="${3:-}"
  case "$text" in
    *"Can not approve your own pull request"*|*"protected branch"*|*"approval"*) echo policy; return 0 ;;
    *"401"*|*"403"*|*"credentials"*|*"token"*|*"not found"*) echo configuration; return 0 ;;
    *"timed out"*|*"timeout"*|*"rate limit"*|*"connection"*|*"502"*|*"503"*) echo transient; return 0 ;;
  esac
  case "$context" in
    ci|test|lint|review-finding) echo code ;;
    dev|review|agent) echo agent ;;
    *) [[ "$rc" -eq 124 ]] && echo transient || echo agent ;;
  esac
}
