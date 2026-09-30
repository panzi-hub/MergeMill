#!/bin/bash
# Shared utility functions for hook scripts
# Note: Does not use 'set -e' as this is a library meant to be sourced

# Read the hook's JSON payload from stdin, bounded by a timeout.
# [Lane-GC PR-1, RC6] A bare `input=$(cat)` spins at ~99% CPU reading from an
# EOF'd non-blocking stdin (the proximate driver of the load-241 incident: four
# such hook processes spinning for >10h under a live lane). Bounded via the
# bash builtin `read -t` (not the external `timeout` binary) so the guard is
# unconditional — no feature-detection, no host without it, no degraded
# fallback that could reintroduce the exact spin this closes. `-d ''` reads
# until NUL/EOF so multi-line JSON payloads come through intact.
# Usage: input=$(read_hook_stdin)
read_hook_stdin() {
  local input
  IFS= read -r -t 5 -d '' input
  printf '%s' "$input"
}

# Resolve main project root (works from worktrees and subdirectories).
# Git worktrees have their own .git file pointing to the main repo's .git/worktrees/<name>.
# --git-common-dir returns the main repo's .git directory in both cases.
resolve_project_root() {
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    echo "$CLAUDE_PROJECT_DIR"
  else
    git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||' || git rev-parse --show-toplevel 2>/dev/null || pwd
  fi
}

# Parse JSON input and extract a field
# Usage: parse_json_field "field.path" "$json_input"
# Returns: field value or empty string
# Requires: jq (mandatory - no fallback to avoid security issues)
parse_json_field() {
  local field_path="$1"
  local json_input="$2"

  if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed" >&2
    echo ""
    return 1
  fi

  # Validate field path to prevent injection - only allow alphanumeric, dots, underscores, and brackets
  if [[ ! "$field_path" =~ ^[]a-zA-Z0-9._[\"]+$ ]]; then
    echo "Error: Invalid field path" >&2
    echo ""
    return 1
  fi

  # Use jq's getpath with proper variable binding to prevent injection
  echo "$json_input" | jq -r --arg path "$field_path" 'getpath($path | split(".")) // ""'
}

# Parse tool input command from hook JSON
# Usage: parse_command "$json_input"
parse_command() {
  parse_json_field "tool_input.command" "$1"
}

# Parse exit code from tool response
# Usage: parse_exit_code "$json_input"
# Requires: jq
parse_exit_code() {
  local json_input="$1"

  if ! command -v jq &> /dev/null; then
    echo "1"
    return 1
  fi

  echo "$json_input" | jq -r '.tool_response.exitCode // .tool_response.exit_code // "1"'
}

# Parse file path from tool input
# Usage: parse_file_path "$json_input"
parse_file_path() {
  parse_json_field "tool_input.file_path" "$1"
}

# Check if command invokes a given git subcommand.
# Usage: is_git_command "commit" "$command"
#
# Matches when `git <operation>` appears as an actual invocation in the
# command line. Ignores occurrences inside quoted strings or as
# substrings of other tokens (e.g. `push-something`, or `git push`
# inside an issue body). Supports global flags before the subcommand
# (`git -c key=val push`, `git --git-dir=/x push`) and command chains
# (`cd /tmp && git push`).
#
# [INV-122] Also matches behind the wrapper forms agents habitually emit —
# no adversarial intent is needed to hit any of these:
#   - PATH-qualified interpreters: `/usr/bin/git push` (basename match on
#     the interpreter token);
#   - command substitution / subshells: `$(git push …)`, backticks (their
#     delimiters are segment separators, same as `&&`/`;`/`|`);
#   - `-c` payload strings of bash/sh/env wrappers:
#     `bash -c "git push origin main"` — such payloads are scanned as
#     candidate command strings, recursively (nested wrappers, depth ≤ 3).
# Quoted mentions behind OTHER commands' arguments (`gh issue create
# --body "see git push docs"`, `echo "git push"`) still never match, and
# only bash/sh/env wrappers are unwrapped — a quoted arg after some other
# command's `-c`-like flag stays inert.
#
# Limitation: the quote-stripping pass does not fully understand escaped
# quotes (`"see \"git push\" docs"`) — the ERE treats `\"` as a region
# boundary, so a missed strip is possible. This is acceptable because the
# intent is defense-in-depth against incidental mentions, not adversarial
# bypass (any workflow author who wants to dodge the hook can use
# `--no-verify`). The strip MUST still terminate on every input — see the
# quoted-substitution note inside the function (#266).
is_git_command() {
  _is_git_command_scan "$1" "$2" 0
}

# Internal scanner behind is_git_command. depth bounds the recursive `-c`
# payload scan (`bash -c 'bash -c "git push …"'`). Not for external use.
_is_git_command_scan() {
  local operation="$1"
  local command="$2"
  local depth="${3:-0}"

  # Pass 1 [INV-122]: unwrap `-c` payloads of bash/sh/env wrappers. Runs on
  # the RAW text (quotes intact), so a payload may itself contain `&&`/`;`
  # and nested wrappers resolve recursively. The match-and-literal-replace
  # loops follow the #266 quoting discipline and therefore always terminate.
  if (( depth < 3 )); then
    local sq="'" scan payload
    # The middle group is optional-but-space-terminated: `bash -c "…"` (flag
    # immediately after the wrapper), `bash --norc -c "…"` and
    # `env FOO=1 bash -c "…"` must all resolve to the SAME payload.
    local re_dq='(^|[^A-Za-z0-9_])(bash|sh|env)[[:space:]]+([^;|&]*[[:space:]])?-c[[:space:]]+("[^"]*")'
    local re_sq="(^|[^A-Za-z0-9_])(bash|sh|env)[[:space:]]+([^;|&]*[[:space:]])?-c[[:space:]]+(${sq}[^${sq}]*${sq})"
    scan="$command"
    # NOTE: capture BASH_REMATCH before the recursive call — the callee's own
    # `[[ =~ ]]` overwrites it in this same shell (a stale/unbound reference
    # here would break under `set -u`, see #266's discipline). The payload is
    # group 4 (1 = leading boundary, 2 = wrapper word, 3 = optional middle
    # flags/env-assignments, 4 = quoted payload).
    while [[ "$scan" =~ $re_dq ]]; do
      local _whole="${BASH_REMATCH[0]}" _inner="${BASH_REMATCH[4]:1:${#BASH_REMATCH[4]}-2}"
      _is_git_command_scan "$operation" "$_inner" $(( depth + 1 )) && return 0
      scan="${scan/"$_whole"/ }"
    done
    scan="$command"
    while [[ "$scan" =~ $re_sq ]]; do
      local _whole_sq="${BASH_REMATCH[0]}" _inner_sq="${BASH_REMATCH[4]:1:${#BASH_REMATCH[4]}-2}"
      _is_git_command_scan "$operation" "$_inner_sq" $(( depth + 1 )) && return 0
      scan="${scan/"$_whole_sq"/ }"
    done
  fi

  # Strip single- and double-quoted regions so mentions inside quoted
  # strings (e.g. `--body "see git push docs"`) cannot match.
  #
  # The match MUST be quoted inside the substitution — `${var/"$x"/ }`, not
  # `${var/$x/ }`. The first operand of `${var/pattern/repl}` is interpreted as
  # a glob pattern, but BASH_REMATCH[0] is literal matched text. An unquoted
  # match containing a glob-significant char (a backslash from an escaped quote
  # `\"`, or `[`, `?`, `*`) would match nothing, leave `stripped` unchanged, and
  # the `while [[ … =~ … ]]` test would re-match the same region forever — a
  # 100%-CPU infinite loop. Quoting forces a literal substitution. See #266.
  local stripped="$command"
  while [[ "$stripped" =~ \"[^\"]*\" ]]; do
    stripped="${stripped/"${BASH_REMATCH[0]}"/ }"
  done
  while [[ "$stripped" =~ \'[^\']*\' ]]; do
    stripped="${stripped/"${BASH_REMATCH[0]}"/ }"
  done

  # Split on shell separators so each segment can be scanned independently.
  # [INV-122] command-substitution delimiters (`$(`, `(`, `)`, backtick) are
  # separators too — a git invocation inside `$(…)` is still an invocation.
  local normalised
  normalised=$(printf '%s' "$stripped" | sed -E 's/(\$\(|\(|\)|`|\|\||&&|;|\||&)/\n/g')

  local segment
  while IFS= read -r segment; do
    local -a tokens
    read -ra tokens <<<"$segment"
    local i=0 n=${#tokens[@]}
    # Find the `git` token (whole token — basename match, so PATH-qualified
    # interpreters like /usr/bin/git count as `git` [INV-122] — not a
    # substring of other tokens).
    while (( i < n )) && [[ "${tokens[i]##*/}" != "git" ]]; do
      ((i++))
    done
    (( i >= n )) && continue
    ((i++))
    # Skip git global flags before the subcommand. Two-token forms
    # (-c key=val, -C path, --git-dir path) consume two slots;
    # attached forms (--git-dir=path) consume one. Bounds are clamped
    # to n so a stray trailing flag cannot skip past the end.
    while (( i < n )); do
      case "${tokens[i]}" in
        -c|-C|--git-dir|--work-tree|--namespace|--super-prefix)
          i=$(( i + 2 > n ? n : i + 2 ))
          ;;
        --*=*|--*)
          ((i++))
          ;;
        *)
          break
          ;;
      esac
    done
    (( i >= n )) && continue
    if [[ "${tokens[i]}" == "$operation" ]]; then
      return 0
    fi
  done <<<"$normalised"
  return 1
}

# Get the project root directory (delegates to resolve_project_root)
# Usage: get_project_root
get_project_root() {
  resolve_project_root
}

# Resolve state directory (works across IDEs)
# Prefers IDE-specific state dir if it exists, falls back to .agents/state/
resolve_state_dir() {
  local project_root
  project_root=$(resolve_project_root)
  if [[ -z "$project_root" || ! -d "$project_root" ]]; then
    echo "Error: Could not resolve project root directory" >&2
    return 1
  fi
  if [[ -d "$project_root/.claude/state" ]]; then
    echo "$project_root/.claude/state"
  elif [[ -d "$project_root/.kiro/state" ]]; then
    echo "$project_root/.kiro/state"
  else
    if ! mkdir -p "$project_root/.agents/state" 2>/dev/null; then
      echo "Error: Could not create state directory at $project_root/.agents/state" >&2
      return 1
    fi
    echo "$project_root/.agents/state"
  fi
}
