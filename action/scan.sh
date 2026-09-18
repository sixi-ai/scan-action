#!/usr/bin/env bash
# Copyright 2026 Sixi AI. SPDX-License-Identifier: Apache-2.0 (LICENSE and NOTICE: github.com/sixi-ai/scan-action).
#
# The body of the GitHub Action (../action.yml): launch, wait, download the SARIF, gate.
#
# Only curl and jq, both on every GitHub-hosted runner. Every request body is built by jq from
# variables, never by string interpolation, so a target URL or a label cannot break out of the JSON it
# is placed in. The token travels in the X-Firebase-Token header the API reads pipeline tokens from.
#
# Exit codes are the CLI's: 0 clean, 1 findings at or above --fail-on, 2 the scan did not assess the
# target (failed, cancelled, or never finished in time), 3 the service refused the run. A pipeline
# that treats every non-zero as "fix the agent" is wrong about 2 and 3, and the summary says which.
set -euo pipefail

: "${SIXI_TARGET:?target is required}"
: "${SIXI_API_TOKEN:?api-token is required}"
api="${SIXI_API_URL:-https://sixi.ch}"
api="${api%/}"
transport="${SIXI_TRANSPORT:-rest}"
profile="${SIXI_PROFILE:-quick}"
fail_on="${SIXI_FAIL_ON:-high}"
timeout_min="${SIXI_TIMEOUT_MINUTES:-90}"
sarif_path="${SIXI_SARIF_PATH:-sixi.sarif}"
assurance="${SIXI_ASSURANCE:-false}"
name="${SIXI_NAME:-}"
if [ -z "$name" ]; then
  name=$(printf '%s' "$SIXI_TARGET" | sed -E 's#^[a-z]+://##; s#[/?].*$##')
fi

case "$transport" in
  rest|mcp|a2a|websocket) ;;
  ws) transport=websocket ;;
  *) echo "::error::transport must be rest, mcp, a2a or websocket (got '$transport')"; exit 3 ;;
esac
case "$fail_on" in
  critical|high|medium|low|none) ;;
  *) echo "::error::fail-on must be critical, high, medium, low or none (got '$fail_on')"; exit 3 ;;
esac
case "$assurance" in
  true|false) ;;
  *) echo "::error::assurance must be true or false (got '$assurance')"; exit 3 ;;
esac

out() { if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi; }
summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"; fi; }
api_call() { # method path [body-file]
  local method=$1 path=$2 body=${3:-}
  if [ -n "$body" ]; then
    curl -sS -X "$method" "$api$path" -H "X-Firebase-Token: $SIXI_API_TOKEN" \
      -H "Content-Type: application/json" -H "User-Agent: sixi-action" \
      --data-binary "@$body" -w '\n%{http_code}' --max-time 60
  else
    curl -sS -X "$method" "$api$path" -H "X-Firebase-Token: $SIXI_API_TOKEN" \
      -H "User-Agent: sixi-action" -w '\n%{http_code}' --max-time 60
  fi
}
# split_reply reads the "body\nstatus" shape api_call prints into REPLY_BODY and REPLY_STATUS.
split_reply() { REPLY_STATUS=${1##*$'\n'}; REPLY_BODY=${1%$'\n'*}; }
detail() { printf '%s' "$1" | jq -r 'if type=="object" then (.detail // .error // .message // empty) else empty end' 2>/dev/null || true; }

# --- 1. Launch ---------------------------------------------------------------------------------------
auth='{"type":"none"}'
if [ -n "${SIXI_TARGET_BEARER_TOKEN:-}" ]; then
  auth=$(jq -cn --arg t "$SIXI_TARGET_BEARER_TOKEN" '{type:"bearer",token:$t}')
elif [ -n "${SIXI_TARGET_API_KEY_HEADER:-}" ]; then
  auth=$(jq -cn --arg h "$SIXI_TARGET_API_KEY_HEADER" --arg v "${SIXI_TARGET_API_KEY_VALUE:-}" '{type:"api_key",api_key_header:$h,api_key_value:$v}')
fi
launch=$(mktemp)
jq -n --arg name "$name" --arg endpoint "$SIXI_TARGET" --arg transport "$transport" \
  --arg profile "$profile" --arg mf "${SIXI_MESSAGE_FIELD:-message}" --arg rp "${SIXI_REPLY_PATH:-response}" \
  --argjson auth "$auth" '
  {name:$name,
   connector:({type:$transport,endpoint:$endpoint,auth:$auth}
     + (if $transport=="rest" then {request_mapping:{message_field:$mf},response_mapping:{message_field:$rp}} else {} end)),
   scan:{profile:$profile,source:"github-action"}}' > "$launch"

# Assurance runs go through /api/continuous/runs, which needs a SAVED target: a run is a comparison
# with the last scan of the same target, and an inline body records no target to compare against. So
# the target is created (or found) first, then the run is launched by id. Everything after this — the
# wait, the SARIF, the gate — is identical, because an assurance run IS a scan with a baseline.
if [ "$assurance" = "true" ]; then
  split_reply "$(api_call POST /api/targets "$launch")"
  rm -f "$launch"
  if [ "$REPLY_STATUS" != "201" ]; then
    why=$(detail "$REPLY_BODY")
    echo "::error::Sixi refused the target ($REPLY_STATUS): ${why:-$REPLY_BODY}"
    exit 3
  fi
  target_id=$(printf '%s' "$REPLY_BODY" | jq -r '.target_id // empty')
  if [ -z "$target_id" ]; then
    echo "::error::Sixi answered 201 without a target id: $REPLY_BODY"
    exit 3
  fi
  run_body=$(mktemp)
  jq -n --arg t "$target_id" '{target_id:$t}' > "$run_body"
  split_reply "$(api_call POST /api/continuous/runs "$run_body")"
  rm -f "$run_body"
  if [ "$REPLY_STATUS" = "404" ]; then
    echo "::error::this deployment does not offer continuous assurance (the licence carries no platform claim); run without assurance: true"
    exit 3
  fi
  if [ "$REPLY_STATUS" = "402" ]; then
    why=$(detail "$REPLY_BODY")
    echo "::error::Sixi refused the assurance run: ${why:-$REPLY_BODY}"
    summary "Sixi: the platform licence has lapsed — ${why}"
    exit 3
  fi
else
  split_reply "$(api_call POST /api/scans "$launch")"
  rm -f "$launch"
fi
if [ "$REPLY_STATUS" != "201" ]; then
  why=$(detail "$REPLY_BODY")
  echo "::error::Sixi refused the scan ($REPLY_STATUS): ${why:-$REPLY_BODY}"
  if [ "$REPLY_STATUS" = "402" ]; then
    summary "Sixi: free trial exhausted — ${why}. Plans: ${api}/pricing"
  fi
  exit 3
fi
scan_id=$(printf '%s' "$REPLY_BODY" | jq -r '.scan_id // empty')
if [ -z "$scan_id" ]; then
  echo "::error::Sixi answered 201 without a scan id: $REPLY_BODY"
  exit 3
fi
out scan-id "$scan_id"
echo "Sixi: scan $scan_id launched against $name ($transport, $profile)"

# --- 2. Wait ------------------------------------------------------------------------------------------
deadline=$(( $(date +%s) + timeout_min * 60 ))
status=running
polls=0
while :; do
  split_reply "$(api_call GET "/api/scans/$scan_id")"
  if [ "$REPLY_STATUS" = "200" ]; then
    status=$(printf '%s' "$REPLY_BODY" | jq -r '.status // "unknown"')
    case "$status" in
      completed|failed|cancelled) break ;;
      awaiting_approval)
        echo "::error::scan $scan_id is waiting for a plan approval in the dashboard; a pipeline cannot give one"
        exit 2 ;;
    esac
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "::error::scan $scan_id did not finish within $timeout_min minutes; it keeps running in the dashboard"
    summary "Sixi: scan \`$scan_id\` did not finish within $timeout_min minutes. It keeps running: ${api}/scans/$scan_id"
    exit 2
  fi
  # A smoke scan is over in seconds and a deep one in an hour: poll quickly at first, then settle.
  polls=$((polls + 1))
  if [ "$polls" -le 12 ]; then sleep 5; else sleep 20; fi
done

findings=$(printf '%s' "$REPLY_BODY" | jq -r '.findings_count // 0')
rating=$(printf '%s' "$REPLY_BODY" | jq -r '.risk_rating // "unknown"')
report_url="$api/scans/$scan_id"
out report-url "$report_url"
out findings "$findings"
out risk-rating "$rating"

if [ "$status" != "completed" ]; then
  why=$(printf '%s' "$REPLY_BODY" | jq -r '.error_message // empty')
  echo "::error::scan $scan_id ended $status${why:+: $why} — the target was not assessed, so this is not a clean result"
  summary "Sixi: scan \`$scan_id\` ended **$status**${why:+ — $why}. Nothing was assessed. $report_url"
  exit 2
fi

# --- 3. The SARIF -------------------------------------------------------------------------------------
tmp=$(mktemp)
code=$(curl -sS "$api/api/scans/$scan_id/report/download/sarif" -H "X-Firebase-Token: $SIXI_API_TOKEN" \
  -H "User-Agent: sixi-action" -o "$tmp" -w '%{http_code}' --max-time 120)
if [ "$code" != "200" ]; then
  echo "::error::could not download the SARIF for $scan_id ($code): $(detail "$(cat "$tmp")")"
  rm -f "$tmp"
  exit 3
fi
mv "$tmp" "$sarif_path"
out sarif-path "$sarif_path"

# --- 4. The gate ---------------------------------------------------------------------------------------
# Delivered attempts come from the SARIF's own run properties. Zero delivered is exit 2 whatever the
# findings say, because a finding on a target nothing reached is a finding about a proxy page.
delivered=$(jq -r '.runs[0].properties.attempts_delivered // empty' "$sarif_path")
if [ "${delivered:-0}" = "0" ]; then
  echo "::error::scan $scan_id delivered no attempt to the target; nothing was assessed"
  summary "Sixi: scan \`$scan_id\` reached the target with **no** attempt. Not a clean result. $report_url"
  exit 2
fi

rank() { case "$1" in critical) echo 4 ;; high) echo 3 ;; medium) echo 2 ;; low) echo 1 ;; *) echo 0 ;; esac; }
failing=0
if [ "$fail_on" != "none" ]; then
  min=$(rank "$fail_on")
  failing=$(jq -r --argjson min "$min" '
    def rank: if .=="critical" then 4 elif .=="high" then 3 elif .=="medium" then 2 elif .=="low" then 1 else 0 end;
    [.runs[0].results[]? | .properties.severity | rank | select(. >= $min)] | length' "$sarif_path")
fi

summary "## Sixi agent scan — \`$name\`"
summary ""
summary "| | |"
summary "|---|---|"
summary "| Scan | [\`$scan_id\`]($report_url) |"
summary "| Profile | \`$profile\` |"
summary "| Attempts delivered | $delivered |"
summary "| Findings | $findings (rating: $rating) |"
summary "| At or above \`$fail_on\` | $failing |"

# The drift, when this was an assurance run. A weakness that is NEW since the baseline fails the
# pipeline even when its severity would have passed the gate, because appearing is the event
# assurance exists to catch — the same rule `sixi scan --assurance` applies at the terminal.
drift_new=0
if [ "$assurance" = "true" ]; then
  split_reply "$(api_call GET "/api/continuous/runs/arun-$scan_id")"
  if [ "$REPLY_STATUS" = "200" ]; then
    fixed=$(printf '%s' "$REPLY_BODY" | jq -r '.drift.fixed // 0')
    still=$(printf '%s' "$REPLY_BODY" | jq -r '.drift.still_open // 0')
    drift_new=$(printf '%s' "$REPLY_BODY" | jq -r '.drift.new // 0')
    notre=$(printf '%s' "$REPLY_BODY" | jq -r '.drift.not_retested // 0')
    base=$(printf '%s' "$REPLY_BODY" | jq -r '.baseline_scan_id // empty')
    if [ -n "$base" ]; then
      summary "| Since \`$base\` | fixed $fixed · still open $still · new $drift_new · not retested $notre |"
    else
      summary "| Drift | no earlier scan of this target — this run is the baseline for the next |"
    fi
    printf '%s' "$REPLY_BODY" | jq -r '.drift.caveats[]? | "> " + .' | while read -r line; do summary "$line"; done
    out drift-new "$drift_new"
  else
    # The run record is written when the scan closes; a miss here is worth saying rather than
    # reporting a drift of zero that was never measured.
    summary "| Drift | not recorded for this run — the comparison is missing, not empty |"
    echo "::warning::assurance run arun-$scan_id has no record; drift was not measured"
  fi
fi
summary ""
summary "The SARIF carries technique ids, titles and severities. Payloads and the target's replies are in the report."

echo "Sixi: $findings finding(s), $failing at or above $fail_on — $report_url"
if [ "$failing" -gt 0 ]; then
  exit 1
fi
if [ "${drift_new:-0}" -gt 0 ]; then
  echo "Sixi: $drift_new weakness(es) are new since the baseline"
  exit 1
fi
exit 0
