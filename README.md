# Sixi AI agent scan — GitHub Action

Red-teams an LLM agent endpoint from Sixi's hosted service and files the findings as SARIF in the
repository's Security tab. One hosted scan per workflow run, gated on an exit code.

The action is a thin client over the hosted API: two files, `action.yml` and `action/scan.sh`, only
`curl` and `jq`. It runs no binary. The attack library never leaves the service.

```yaml
name: agent-security
on:
  schedule:
    - cron: "0 5 * * 1"        # Monday 05:00 UTC, so the diff has a fresh baseline every week
  workflow_dispatch:

permissions:
  security-events: write       # the SARIF upload
  contents: read

jobs:
  sixi:
    runs-on: ubuntu-latest
    steps:
      - uses: sixi-ai/scan-action@v1
        id: sixi
        with:
          target: https://assistant.example.com/api/chat
          api-token: ${{ secrets.SIXI_API_TOKEN }}
          name: support-assistant
          profile: quick
          fail-on: high
          target-bearer-token: ${{ secrets.ASSISTANT_TOKEN }}   # only if the agent needs one

      - uses: github/codeql-action/upload-sarif@v3
        if: always() && steps.sixi.outputs.sarif-path != ''
        with:
          sarif_file: ${{ steps.sixi.outputs.sarif-path }}
          category: sixi
```

`if: always()` matters: the upload step must run when the scan step exits 1, which is the run that
has something to show.

Create a pipeline token in the dashboard (Settings → Pipeline tokens) and store it as a repository
secret. A token acts as you, with your plan, and expires on its own.

## Exit codes

A job that treats every non-zero exit as "fix the agent" is wrong about two of them.

| Exit | Meaning | What to do |
|---|---|---|
| 0 | Assessed, nothing at or above `fail-on` | Nothing |
| 1 | Findings at or above `fail-on` | Open the report; the finding names the technique and the fix |
| 2 | Nothing was assessed. The target was never reached, the scan failed, or it did not finish in time | Check the endpoint, its credential and the network path. This is not a clean result |
| 3 | The service refused the run, or the upload failed | Read the message: an expired token, a trial that is used up, a plan limit |

Exit 2 always wins. A scan that reached nothing exits 2 even if the gate would have passed, and even
if a proxy's error page carried something that looked like a finding.

## Inputs

| Input | Default | |
|---|---|---|
| `target` | required | The endpoint. REST, MCP, A2A or WebSocket, reachable from the internet |
| `api-token` | required | From a secret, never a literal |
| `api-url` | `https://sixi.ch` | A self-host names its own |
| `transport` | `rest` | `rest`, `mcp`, `a2a`, `websocket` |
| `name` | the target host | The label the dashboard files the scan under; the diff joins runs by it |
| `profile` | `quick` | `smoke`, `quick`, `deep`, `compliance`, `sharp`. `smoke` is a wiring check and is not evidence |
| `fail-on` | `high` | `critical`, `high`, `medium`, `low`, `none` |
| `assurance` | `false` | Compare with the last scan of the same target and fail for a weakness that is new since then. Needs a deployment whose licence carries the platform claim |
| `message-field` / `reply-path` | `message` / `response` | REST only: where the message goes and where the reply comes back |
| `target-bearer-token` | | A credential the target needs. Stored encrypted with the scan and masked in every response |
| `target-api-key-header` / `target-api-key-value` | | The API-key alternative |
| `timeout-minutes` | `90` | The scan keeps running in the dashboard if the job gives up |
| `sarif-path` | `sixi.sarif` | |

Outputs: `scan-id`, `report-url`, `findings`, `risk-rating`, `sarif-path`, and `drift-new` when
assurance is on.

## What it does, in order

`POST /api/scans` with the target, polls `GET /api/scans/{id}`, downloads the SARIF, and gates on the
file's own `attempts_delivered` and severities. Every request body is built by `jq` from variables,
so a target URL or a label cannot break out of the JSON it is placed in, and inputs reach the script
through the environment rather than being pasted into a shell line.

The SARIF carries technique ids, titles, severities and a link to the report. It never carries a
payload, the target's reply or the attacker's notes, because a code-scanning tab is read by everyone
with read access to the repository.

## Any other CI

`action/scan.sh` has no GitHub dependency beyond two optional output files. Set the `SIXI_*`
variables the script reads (they mirror the inputs above) and run it from GitLab, Jenkins or a
terminal.

## Web chat and private endpoints

The hosted service cannot scan a chat widget on a web page, and cannot reach an endpoint that is not
on the internet. Both are the job of the deployed package, which runs `sixi scan --format sarif
--upload` in your own network and files the result in the same dashboard.

## Where this comes from

This repository is published from Sixi's main tree, where the script is exercised against a real
service by an acceptance suite before every release. Issues and pull requests are welcome here;
the fix lands upstream first and is published back.

Licensed under the Apache License, Version 2.0. See `LICENSE`.
