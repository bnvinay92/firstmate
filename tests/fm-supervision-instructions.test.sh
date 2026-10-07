#!/usr/bin/env bash
# Tests for harness-aware supervision instruction rendering.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-instructions)
RENDER="$ROOT/bin/fm-supervision-instructions.sh"

test_selected_harness_block_only() {
  local out
  out=$("$RENDER" --harness codex)
  assert_contains "$out" "SUPERVISION OPERATING INSTRUCTIONS - primary harness: codex" "codex heading missing"
  assert_contains "$out" "Mode: Codex foreground checkpoint." "codex snippet missing"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh" "codex checkpoint helper missing"
  assert_not_contains "$out" "Mode: Claude Stop-hook-owned supervision." "renderer printed the claude snippet too"
  assert_not_contains "$out" "Mode: Pi extension background wake." "renderer printed the pi snippet too"
  pass "renderer prints exactly the selected harness block"
}

# A Claude home runs the host by default, so its block carries the host
# protocol with no file, exactly as with an opting-in file; an off file
# renders the plain block.
test_supervision_host_protocol_on_a_claude_home_unless_off() {
  local home config plain hosted other
  home="$TMP_ROOT/host-home"
  config="$TMP_ROOT/host-config"
  mkdir -p "$home/state" "$config"
  : > "$config/supervision-host-off"
  plain=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness claude)
  assert_not_contains "$plain" "Supervision host" "a claude home opted out by config/supervision-host-off rendered the host protocol"
  rm -f "$config/supervision-host-off"
  hosted=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness claude)
  : > "$config/supervision-host"
  assert_equals "$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness claude)" "$hosted" \
    "a claude home without config/supervision-host must render exactly what an opted-in claude home renders"
  assert_contains "$hosted" "- Supervision host: on;" "an opted-in claude home did not render the host state line"
  assert_contains "$hosted" "Mode: Claude Stop-hook-owned supervision." "the host protocol replaced the claude protocol instead of adding to it"
  assert_contains "$hosted" "supervision-host: cycle boundary" "the host protocol did not tell main how to handle a park boundary"
  assert_contains "$hosted" "never run the return from it" "the host protocol did not say a handed-back wake is not the captain's return"
  [ "$(printf '%s\n' "$hosted" | grep -vF -e '- Supervision host: on;' | head -n "$(printf '%s\n' "$plain" | wc -l)")" = "$plain" ] \
    || fail "the host protocol changed the claude block it should only append to"
  other=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness pi)
  assert_not_contains "$other" "Supervision host" "a pi primary rendered the host protocol"
  rm -f "$config/supervision-host"
  other=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness pi)
  assert_not_contains "$other" "Supervision host" "a pi primary without config/supervision-host rendered the host protocol"
  pass "renderer adds the supervision-host protocol on a claude home unless config/supervision-host-off opts it out, leaving the claude block intact"
}

# Each non-Pi arm owner gets the host protocol in its own terms, and only its
# own terms; Grok's model-owned arm command becomes the host; a home with
# config/supervision-host-off, or a non-Claude home without the file, renders exactly what
# it did before, with no tag or placeholder.
test_supervision_host_protocol_on_every_arm_owner() {
  local home config harness plain hosted body
  home="$TMP_ROOT/host-owners-home"
  config="$TMP_ROOT/host-owners-config"
  mkdir -p "$home/state" "$config"
  for harness in claude opencode codex; do
    : > "$config/supervision-host-off"
    plain=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness "$harness")
    assert_not_contains "$plain" "Supervision host" "$harness: a home opted out by config/supervision-host-off rendered the host protocol"
    assert_not_contains "$plain" "__FM_" "$harness: a placeholder leaked into the rendered block"
    if [ "$harness" != claude ]; then
      rm -f "$config/supervision-host" "$config/supervision-host-off"
      assert_equals "$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness "$harness")" "$plain" \
        "$harness: a home without config/supervision-host must render the plain block"
    fi
    rm -f "$config/supervision-host-off"
    : > "$config/supervision-host"
    hosted=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness "$harness")
    assert_contains "$hosted" "- Supervision host: on; it takes away-posture wakes and, where the dialog mirror is verified, eligible attended wakes itself, and hands the rest to you (protocol at the end of this block)." \
      "$harness: an opted-in home did not render the host state line naming both postures it takes"
    body=$(printf '%s\n' "$hosted" | sed -n '/^Supervision host: on for this home/,$p')
    [ -n "$body" ] || fail "$harness: the host protocol is missing"
    printf '%s\n' "$body" | grep -E '^\{[a-z,]+\} ' >/dev/null && fail "$harness: a harness tag leaked into the rendered protocol: $body"
    [ "$(printf '%s\n' "$body" | grep -c 'runs the supervision host')" -eq 1 ] \
      || fail "$harness: the protocol must name exactly one arm owner: $body"
    [ "$(printf '%s\n' "$body" | grep -c '^ *Only a wake the host hands back reaches you')" -eq 1 ] \
      || fail "$harness: the protocol must name exactly one wake path: $body"
    [ "$(printf '%s\n' "$body" | grep -c '^3\. ')" -eq 1 ] || fail "$harness: the protocol must say once how the park boundary arrives: $body"
    [ "$(printf '%s\n' "$body" | grep -c '^6\. ./afk. writes only the record here')" -eq 1 ] \
      || fail "$harness: the protocol must say once what /afk does here: $body"
  done
  rm -f "$config/supervision-host"
  : > "$config/supervision-host"
  hosted=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness codex)
  assert_contains "$hosted" 'FM_CODEX_WATCH_CHECKPOINT_AWAY' "codex must learn that an away checkpoint holds longer"
  assert_contains "$hosted" 'checkpoint: no actionable wake within' "codex must learn how the park boundary arrives"
  pass "renderer gives each arm owner the host protocol in its own terms"
}

test_unknown_fallback() {
  local out
  out=$("$RENDER" --harness not-real)
  assert_contains "$out" "primary harness: unknown" "unknown heading missing"
  assert_contains "$out" "Mode: Unknown harness fallback." "unknown fallback snippet missing"
  pass "renderer falls back to unknown.md for unverified harness names"
}

test_conditional_stanzas() {
  local home config out
  home="$TMP_ROOT/conditional-home"
  config="$TMP_ROOT/conditional-config"
  mkdir -p "$home/state" "$home/config" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness codex --read-only 1 --afk 1)
  assert_contains "$out" "- Lock: read-only" "read-only stanza missing"
  assert_contains "$out" "- Away mode: active" "afk stanza missing"
  assert_contains "$out" 'Mode: Codex foreground checkpoint.' "codex snippet missing"
  pass "renderer includes read-only and afk current-state stanzas"
}

test_quiet_mode_stanzas() {
  local home config out
  home="$TMP_ROOT/quiet-home"
  config="$TMP_ROOT/quiet-config"
  mkdir -p "$home/state" "$config"
  out=$(FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" "$RENDER" --harness codex --afk 1 --afk-mode quiet)
  assert_contains "$out" "- Quiet mode: active" "quiet stanza missing"
  assert_contains "$out" "load /quiet" "quiet stanza did not name the /quiet skill"
  assert_contains "$out" "Ordinary captain chat does NOT exit it" "quiet stanza lost the explicit-only exit rule"
  assert_not_contains "$out" "- Away mode: active" "quiet mode incorrectly rendered as away mode"
  out=$(FM_HOME="$home" "$RENDER" --harness codex --afk 1 --afk-mode quiet --repair-line)
  assert_contains "$out" "Quiet mode owns watcher supervision; load /quiet" "quiet repair line did not name /quiet"

  out=$(FM_HOME="$home" "$RENDER" --harness codex --afk 1)
  assert_contains "$out" "- Away mode: active" "omitting --afk-mode did not default to away (regression)"
  assert_not_contains "$out" "Quiet mode" "omitting --afk-mode leaked quiet-mode text"

  out=$(FM_HOME="$home" "$RENDER" --harness codex --afk 1 --afk-mode not-a-real-mode)
  assert_contains "$out" "- Away mode: active" "unrecognized --afk-mode value did not fall back to away"

  out=$(FM_HOME="$home" "$RENDER" --harness codex --afk 0)
  assert_contains "$out" "- Away/quiet mode: inactive" "inactive stanza missing"
  pass "renderer's away/quiet stanzas are mode-aware, default to away, and fall back safely on garbage input"
}

test_repair_lines() {
  local home out
  home="$TMP_ROOT/repair-home"
  mkdir -p "$home/state" "$home/config"
  out=$(FM_HOME="$home" FM_CODEX_WATCH_CHECKPOINT=7 "$RENDER" --harness codex --repair-line)
  assert_contains "$out" "bin/fm-watch-checkpoint.sh --seconds 7" "codex repair line did not use checkpoint helper and env override"

  out=$(FM_HOME="$home" "$RENDER" --harness claude --queue-pending 1 --repair-line)
  assert_contains "$out" "After draining queued wakes" "queue-pending prefix missing"
  assert_contains "$out" "watcher supervision needs Stop-owned automatic recovery" "claude pre-verification repair line is not neutral"
  assert_not_contains "$out" "is broken" "claude pre-verification repair line claimed a verified mechanism failure"
  assert_not_contains "$out" "FAILED" "claude pre-verification repair line emitted a verified failure notice"
  assert_not_contains "$out" "manual background" "claude pre-verification repair line directed a manual background arm"
  assert_not_contains "$out" "bin/fm-watch-arm.sh" "claude pre-verification repair line directed an arm command"

  out=$(FM_HOME="$home" FM_CODEX_WATCH_CHECKPOINT=7 "$RENDER" --harness codex --repair-line)
  assert_contains "$out" "bin/fm-watch-checkpoint.sh --seconds 7" "codex repair line lost the checkpoint helper"

  out=$(FM_HOME="$home" "$RENDER" --harness opencode --read-only 1 --repair-line)
  assert_contains "$out" "session holding the fleet lock" "read-only repair line missing"

  pass "renderer repair-line mode is harness-aware and honors conditional state"
}

test_cross_harness_ordinary_continuation_and_repair_matrix() {
  local ordinary out

  out=$("$RENDER" --harness opencode)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "plugin already owns watcher continuity" "opencode ordinary-wake line does not leave continuity to the plugin"
  assert_not_contains "$ordinary" "bin/fm-watch-arm.sh" "opencode ordinary-wake line incorrectly calls the recovery probe"
  out=$("$RENDER" --harness opencode --repair-line)
  assert_contains "$out" "manual recovery probe" "opencode recovery line lost its manual probe"

  out=$("$RENDER" --harness claude)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "Stop-owned auto-arm" "claude ordinary-wake line does not leave continuity to the Stop hook"
  assert_contains "$ordinary" "bin/fm-claude-stop-autoarm.sh" "claude ordinary-wake line lost the auto-arm script name"
  assert_contains "$ordinary" "do not arm another cycle" "claude ordinary-wake line does not forbid a model re-arm"
  assert_not_contains "$ordinary" "bin/fm-watch-arm.sh" "claude ordinary-wake line incorrectly calls the manual arm"
  out=$("$RENDER" --harness claude --repair-line)
  assert_contains "$out" "watcher supervision needs Stop-owned automatic recovery" "claude recovery line lost its neutral automatic-recovery guidance"
  assert_not_contains "$out" "is broken" "claude recovery line claimed failure before verification"
  assert_not_contains "$out" "bin/fm-watch-arm.sh" "claude recovery line must not create a repeatable manual arm loop"

  out=$("$RENDER" --harness codex)
  ordinary=$(printf '%s\n' "$out" | grep -F -- '- Ordinary wake:')
  assert_contains "$ordinary" "next foreground" "codex ordinary-wake line lost its foreground checkpoint"
  assert_contains "$ordinary" "bin/fm-watch-checkpoint.sh" "codex ordinary-wake line lost the checkpoint command"
  assert_not_contains "$ordinary" "bin/fm-watch-arm.sh" "codex ordinary-wake line incorrectly uses a background arm"
  out=$("$RENDER" --harness codex --repair-line)
  assert_contains "$out" "foreground checkpoint" "codex recovery line lost its checkpoint repair"
  assert_contains "$out" "bin/fm-watch-checkpoint.sh" "codex recovery line lost the checkpoint command"

  pass "renderer preserves every harness ordinary-continuation and missing-cycle repair path"
}

test_supervision_host_protocol_on_a_claude_home_unless_off
test_supervision_host_protocol_on_every_arm_owner
test_selected_harness_block_only
test_unknown_fallback
test_conditional_stanzas
test_quiet_mode_stanzas
test_repair_lines
test_cross_harness_ordinary_continuation_and_repair_matrix
