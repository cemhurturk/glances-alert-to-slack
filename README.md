# Glances Alert to Slack 🚨📥️

This project provides a lightweight Bash script that monitors **CPU**, **memory**, and **disk usage** on your Ubuntu server using [Glances](https://github.com/nicolargo/glances), and sends **Slack alerts** when thresholds are exceeded.

## 🔧 Features

* ✅ Uses `glances` with `--stdout` mode
* ✅ Parses CPU, memory, and disk usage from the text output
* ✅ Sends alerts to a Slack channel using Incoming Webhooks
* ✅ Throttles alerts to avoid spam (default: 10-minute interval)
* ✅ Includes a detailed debug log (`/tmp/glances-alert.log`)
* ✅ Adds hostname to the Slack alert for easy server identification

---

## ⚠️ Known issue fixed in v1.1

Versions prior to v1.1 used a `timeout … glances … | tail -n 3` pipeline
to sample Glances. A race between `tail` closing its input and `timeout`
signalling its child could leave orphaned `glances` python processes
behind on every cron tick. One production host accumulated ~45 leaked
processes over 127 days (~1.5 cores and ~7.9 GB RAM, load average ~4.0).

**If you are running an older copy of this script, please upgrade and
follow the steps in [`CHANGELOG.md`](./CHANGELOG.md) to clean up any
orphans before the new version starts running.** The new version
captures Glances output to a tempfile, uses `timeout --kill-after` to
guarantee a SIGKILL fallback, reaps its own children on exit, and uses
`flock` to prevent overlapping runs.

---

## 📦 Requirements

Install dependencies:

```bash
sudo apt update
sudo apt install -y glances bc curl util-linux coreutils
```

* `flock` ships with `util-linux`
* `timeout` (with `--kill-after`) requires `coreutils` ≥ 8.5, which all
  currently-supported Ubuntu releases provide

---

## 🚀 Installation

1. **Download the script**:

```bash
curl -o /usr/local/bin/glances-alert.sh https://raw.githubusercontent.com/cemhurturk/glances-alert-to-slack/refs/heads/main/glances-alert.sh
chmod +x /usr/local/bin/glances-alert.sh
```

2. **Edit the script** and add your Slack Webhook URL:

```bash
nano /usr/local/bin/glances-alert.sh
```

Replace:

```bash
SLACK_WEBHOOK_URL="https://hooks.slack.com/services/XXX/YYY/ZZZ"
```

3. **Set up cron** to run it every 2 minutes:

```bash
crontab -e
```

Add:

```cron
*/2 * * * * /usr/local/bin/glances-alert.sh
```

---

## 🧪 Testing

Run the script manually:

```bash
/usr/local/bin/glances-alert.sh
```

Tail the log:

```bash
tail -f /tmp/glances-alert.log
```

---

## 📜 Example Slack Alert

```
🚨 Alert from server123:
⚠️ High CPU usage: 91.2%
⚠️ High Disk usage: 88.0%
```

---

## 📂 Files

* `glances-alert.sh`: Main monitoring script
* `/tmp/glances-alert.log`: Debug log (auto-created)

---

## 🔐 Security Note

The script only runs locally and requires no elevated privileges beyond installing system utilities. No data is shared beyond the Slack webhook.

---

## 👤 Author

Maintained by [Cem Hurturk](https://github.com/cemhurturk).

