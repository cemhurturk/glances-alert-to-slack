# Changelog

All notable changes to this project will be documented here.

## v1.1 — Fix orphaned `glances` process leak

### Background

The previous sampling line used a shell pipeline:

```bash
RAW_OUTPUT=$(timeout "$CPU_MEASURE_SECONDS" glances --stdout cpu.total,mem,fs --time 1 2>/dev/null | tail -n 3)
```

Under cron, this had a race:

1. `tail -n 3` closes its stdin once it has received 3 lines.
2. `timeout`'s SIGPIPE/SIGTERM to the child `glances` process was not
   always propagated quickly enough.
3. The command-substitution subshell exited while the `glances` python
   process (and sometimes `timeout` itself) remained running.
4. Each cron tick could therefore leak a full process chain:
   `sh → bash → bash → timeout → python`.

One production deployment accumulated roughly 45 orphaned `glances`
processes over 127 days, consuming about 1.5 CPU cores and 7.9 GB of RAM
continuously. Load average on the host sat near 4.0 until the orphans
were killed manually.

A secondary config-layout bug had also surfaced in at least one deployed
copy: `CHECK_CPU=1CHECK_MEM=1` ended up collapsed onto a single line,
silently disabling the memory check.

### Fix

- **No more `glances | tail` pipeline.** Glances output is written to a
  tempfile (`mktemp`) and read back with `tail -n 20`. This removes the
  SIGPIPE race entirely.
- **`timeout --kill-after`** is now used on every `glances` invocation
  so SIGKILL is guaranteed if SIGTERM is ignored.
- **EXIT/INT/TERM trap** reaps any leftover children of the current
  script using `pgrep -P $$`. The `-P $$` filter is intentional: it
  never touches unrelated `glances` processes on the host (for example,
  a `glances -s -B 127.0.0.1` server).
- **`flock`** on `/tmp/glances-alert.lock` prevents overlapping runs if
  one tick runs longer than the cron interval.
- **`curl --max-time 10`** stops a slow Slack webhook from hanging the
  script.
- **`set -u`** is now enabled to catch undefined-variable bugs.
- Each `CHECK_*` config flag is explicitly kept on its own line.

### Upgrade steps for existing deployments

Before deploying the new script, clean up any orphans left by the old
version. The `pkill` patterns below are deliberately specific — they
match the invocation pattern used by this script and will not touch a
separately-running `glances -s -B …` server on the same host.

1. Disable the cron entry:
   ```bash
   crontab -e          # prefix the glances-alert line with #
   ```

2. Count existing orphans:
   ```bash
   ps -eo pid,cmd | grep "glances --stdout" | grep -v grep | wc -l
   ```

3. Kill orphans:
   ```bash
   pkill -9 -f "python3 /usr/bin/glances --stdout"
   pkill -9 -f "timeout .* glances --stdout"
   ```

4. Deploy the new `glances-alert.sh`.

5. Re-enable the cron entry.

6. After ~10 minutes, verify no new leaks have appeared:
   ```bash
   ps -eo pid,etime,cmd | grep "glances --stdout" | grep -v grep
   ```
   Any matching process should show an `ELAPSED` value smaller than the
   cron interval.

### New dependencies

- `flock` (`util-linux`)
- `timeout` with `--kill-after` support (`coreutils` ≥ 8.5 — satisfied
  by all currently-supported Ubuntu releases)
