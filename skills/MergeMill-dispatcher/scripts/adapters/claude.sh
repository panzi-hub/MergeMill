#!/bin/bash
# adapters/claude.sh — Claude Code CLI adapter ([INV-75]).
#
# All Claude-specific behavior lives here: argv assembly for the dev-new /
# dev-resume modes. Claude has no "lying mode" (it fails loudly), so it carries
# no drop-reason scraper. Session model: caller pre-mints --session-id <UUID>;
# the SAME id is used for --resume.
#
# PRECONDITION: sourced by lib-agent.sh (or a compat shim) AFTER lib-agent.sh's
# shared primitives are defined — adapter_invoke_claude calls _run_with_timeout
# and reads AGENT_PERMISSION_MODE / AGENT_LAUNCHER_ARGV, all owned by
# lib-agent.sh. Adapters never re-source lib-agent.sh (would recurse).

# adapter_invoke_claude <mode> <session_id> <prompt> <model> <session_name>
#   mode ∈ { dev-new, dev-resume }
#
# Prompt-channel contract ([INV-34]): prompt is fed on stdin, never argv.
adapter_invoke_claude() {
  local mode="$1" session_id="$2" prompt="$3" model="${4:-}" session_name="${5:-}"
  local extra_args=()
  if [[ "$mode" == "dev-resume" ]]; then
    _parse_extra_args AGENT_REVIEW_EXTRA_ARGS extra_args
  else
    _parse_extra_args AGENT_DEV_EXTRA_ARGS extra_args
  fi

  # Headless dispatcher runs must not inherit user-level Claude plugin
  # marketplaces. Claude may refresh an enabled/known marketplace before the
  # first tool call, which can leave a long-running Agent stuck in pre-flight
  # while cloning a remote repository. Preserve only the user's env settings
  # (auth/base URL/model) in a temporary settings file, while loading project
  # hooks and local settings normally. Conformance runs leave this opt-in off.
  local isolated_settings_file=""
  local isolated_settings_args=()
  if [[ "${MERGEMILL_DISABLE_CLAUDE_PLUGINS:-0}" == "1" ]]; then
    isolated_settings_args+=(--setting-sources project,local)
    if [[ -f "${HOME:-}/.claude/settings.json" ]] && command -v jq >/dev/null 2>&1; then
      isolated_settings_file="$(mktemp "${TMPDIR:-/tmp}/mergemill-claude-settings.XXXXXX")"
      if jq '{env: (.env // {})}' "${HOME}/.claude/settings.json" >"${isolated_settings_file}"; then
        isolated_settings_args+=(--settings "$isolated_settings_file")
      else
        rm -f "$isolated_settings_file"
        isolated_settings_file=""
      fi
    fi
  fi

  # Flag list is identical across both invocation paths — only the
  # command prefix differs (see below). `-p` is the headless flag;
  # claude reads the prompt from stdin when -p has no value. Session labels
  # are tracked by MergeMill's run metadata; current Claude CLI releases do
  # not support a `--name` option.
  local claude_args
  if [[ "$mode" == "dev-resume" ]]; then
    claude_args=(
      --resume "$session_id"
      "${isolated_settings_args[@]}"
      --permission-mode "$AGENT_PERMISSION_MODE"
      ${model:+--model "$model"}
      "${extra_args[@]}"
      -p
      --output-format json
    )
  else
    claude_args=(
      --session-id "$session_id"
      "${isolated_settings_args[@]}"
      --permission-mode "$AGENT_PERMISSION_MODE"
      ${model:+--model "$model"}
      "${extra_args[@]}"
      -p
      --output-format json
    )
  fi
  # Two invocation paths:
  #
  # (A) No AGENT_LAUNCHER → wrapper drives claude directly.
  #     `env -u CLAUDECODE` strips a parent-process env var that
  #     would otherwise make claude refuse to start (it treats
  #     CLAUDECODE-set parents as "already inside a Claude session").
  #     Only relevant when an operator runs the wrapper from inside
  #     an interactive claude — dispatcher's nohup path doesn't have it.
  #
  # (B) AGENT_LAUNCHER set → launcher invokes claude itself.
  #     The launcher (e.g. `cc` shell function) ends with
  #     `$CLAUDE_CMD "$@"`, so we pass ONLY flags as "$@" —
  #     NOT the binary name and NOT `env -u`. CLAUDECODE handling is
  #     delegated to the launcher.
  local rc=0
  if [[ ${#AGENT_LAUNCHER_ARGV[@]} -gt 0 ]]; then
    printf '%s' "$prompt" | _run_with_timeout "${claude_args[@]}" || rc=$?
  else
    printf '%s' "$prompt" | _run_with_timeout env -u CLAUDECODE "$AGENT_CMD" "${claude_args[@]}" || rc=$?
  fi
  [[ -z "$isolated_settings_file" ]] || rm -f "$isolated_settings_file"
  return "$rc"
}
