# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository shape

Single-file Bash project: `glances-alert.sh` is the entire application. No build system, no tests, no linter. The script is intended to be copied to `/usr/local/bin/` on an Ubuntu host and run from cron every 2 minutes.

Runtime dependencies on the target host: `glances`, `jq`, `bc`, `curl` (installed via `apt`). `jq` is listed in the README as a dependency but is **not** used by the current script — see architecture note below before changing parsing.

## Common commands

```bash
# Run the script locally (requires glances + bc + curl on PATH)
bash glances-alert.sh

# Watch the debug log while iterating
tail -f /tmp/glances-alert.log

# Reset the throttle state so the next run can fire an alert
rm -f /tmp/glances-alert.last
```

There is nothing to build, test, or lint. Validation is done by running the script and inspecting `/tmp/glances-alert.log`.

## Architecture

The script is a straight-line pipeline executed once per cron tick:

1. **Sample** — runs `glances --stdout cpu.total,mem,fs --time 1` under `timeout $CPU_MEASURE_SECONDS` (default 5s) to get an averaged CPU reading; the last block of output is kept via `tail -n 3`. There is a fallback to a single 2-second reading if the windowed call produces no output.
2. **Parse** — extracts three numbers from Glances' text output (not JSON):
   - `CPU_USAGE` from the `cpu.total:` line (with a `sed` fallback path)
   - `MEM_USAGE` from the `'percent':` field inside the `mem:` section
   - `DISK_USAGE` from the `'percent':` field inside the `fs:` section
   All three must match `^[0-9.]+$` or the script logs an error and exits 1.
3. **Evaluate** — each `CHECK_*` flag gates its threshold comparison; comparisons use `bc -l` because values are floats. Triggered checks append a line to `ALERT_MSG`.
4. **Throttle + notify** — if `ALERT_MSG` is non-empty, compare `now - mtime_of_state_file` against `ALERT_COOLDOWN_MINUTES` (default 10). Only if the cooldown has elapsed does it POST to `SLACK_WEBHOOK_URL` and overwrite `STATE_FILE` (`/tmp/glances-alert.last`) with the current epoch.

Every step appends to `LOG_FILE` (`/tmp/glances-alert.log`); the final line is a `STATUS:` record of all three metrics regardless of whether an alert fired.

### Things that will bite you

- **README vs. script drift**: the README advertises `--stdout-json` + `jq` parsing, but the committed script uses `--stdout` text output parsed with `grep`/`sed`/`awk`. If you "fix" the parser to use `jq`, you're rewriting the working path — confirm with the user which direction is intended.
- **Placeholder webhook**: `SLACK_WEBHOOK_URL` in the repo is `https://hooks.slack.com/services/XXX/YYY/ZZZ`. Do not commit a real webhook in its place.
- **Throttle is global, not per-metric**: one alert for any metric resets the cooldown for all metrics. A CPU spike at T=0 will suppress a disk alert at T=2min.
- **`CPU_STEAL` exclusion** (per commit `0ab5e9a`): the current `cpu.total` field from Glances is what's monitored; steal time is deliberately not part of the alerting path. Keep that in mind before switching fields.
- Config lives inline at the top of `glances-alert.sh` (lines 3–17). There is no config file or env-var layer; edits to thresholds, webhook, or `CHECK_*` toggles are made in-place.
