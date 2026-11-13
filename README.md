# VPS Telegram Alerts

Get a Telegram message when your VPS:

- 🟢 starts (⚠️ also warns if the last shutdown was a crash or power loss)
- 🔴 shuts down / 🔄 reboots
- ✅ gets a successful SSH or console login
- ❌ gets a failed SSH login (instantly, or as a summary every 5 min - you choose)

## Install (one command, on any new VPS)

```bash
curl -fsSL https://raw.githubusercontent.com/oyatsu-org/server-tg-alert/main/tg-alert.sh | sudo bash
```

The installer asks for your **bot token**, then tells you to press **START** in
your bot's chat. It finds your chat ID automatically, asks for a **server name**
(shown in every alert, press Enter to use the hostname), and sends a test message.

Don't have a bot yet? In Telegram, open **@BotFather**, send `/newbot`, and copy the token.

### Without any questions (for automation)
Replace the three values with your own. Most people should use the command above instead.
```bash
curl -fsSL https://raw.githubusercontent.com/oyatsu-org/server-tg-alert/main/tg-alert.sh | sudo BOT_TOKEN=123:ABC CHAT_ID=987654321 SERVER_NAME="My VPS" ENABLE_USEPAM=yes bash
```

### Uninstall
```bash
curl -fsSL https://raw.githubusercontent.com/oyatsu-org/server-tg-alert/main/tg-alert.sh | sudo bash -s uninstall
```

## Settings
Edit `/etc/tg-alert.conf`, then run `sudo systemctl restart tg-alert-failwatch`.

| Option | Default | Meaning |
|---|---|---|
| `FAIL_BATCH_SECONDS` | 0 | `0` = instant message for every failed login. `300` = one summary every 5 min. |
| `FAIL_INSTANT_MAX` | 20 | Instant mode: max messages per minute. Extra failures (e.g. a brute-force attack) arrive as one summary. |
| `NOTIFY_LOGOUT` | 0 | `1` = also alert on logout |
| `IGNORE_LOGIN_IPS` | empty | Your own IPs that shouldn't trigger login alerts |
| `SERVER_NAME` | hostname | Name shown in each message |

Test: `tg-alert-send "hello"`. Logs: `journalctl -u tg-alert-failwatch -u tg-alert-power`

## Notes
- Needs a systemd-based Linux (Ubuntu, Debian, CentOS/Rocky/Alma, …).
- A sudden power cut can't send a shutdown message. You get the ⚠️ warning at the next boot instead.
- SSH login alerts need `UsePAM yes` in the SSH config (the default on most distros). If it's off, the
  installer asks whether to turn it on. It keeps a backup, keeps password logins off if they were off,
  and undoes the change if the new config doesn't pass `sshd -t`.

---

# Windows version

Same alerts for Windows servers (Windows 10/11, Server 2016+):

- 🟢 start, 🔴 shutdown, 🔄 restart (shows who restarted it and why), ⚠️ crash / power loss
- ✅ Remote Desktop, console and OpenSSH logins
- ❌ failed logins with the reason (wrong password, user does not exist, account locked, …)

## Install (one command)
Open **PowerShell as Administrator** (right-click Start → *Terminal (Admin)* or *Windows PowerShell (Admin)*) and run:
```powershell
irm https://raw.githubusercontent.com/oyatsu-org/server-tg-alert/main/tg-alert-windows.ps1 | iex
```
It asks the same questions as the Linux version (token shown as `*****`, chat ID found automatically,
server name, instant or summary failed-login alerts) and sends a test message.

### Uninstall
```powershell
powershell -ExecutionPolicy Bypass -File C:\ProgramData\TgAlert\uninstall.ps1
```

### Settings
`C:\ProgramData\TgAlert\config.json` (only Administrators can read it). After editing, run
`Stop-ScheduledTask TgAlert; Start-ScheduledTask TgAlert`.

| Option | Default | Meaning |
|---|---|---|
| `FailBatchSeconds` | 0 | `0` = instant, `300` = summary every 5 min |
| `FailInstantMax` | 20 | Instant mode: max messages per minute, the rest come as one summary |
| `IgnoreLoginIps` | `[]` | IPs whose successful logins don't alert, e.g. `["100.64.0.5"]` |
| `NotifyNetworkLogons` | false | `true` = also alert on network logons (file shares, WinRM). Can be noisy. |
| `ServerName` | computer name | Name shown in each message |

### How it works
A scheduled task `TgAlert` runs a small PowerShell agent as SYSTEM at startup (re-checked every 5 min
in case it stopped). It listens to the Windows event logs: Security 4624/4625 (logins), System 1074
(shutdown/restart), 6008 (crash), and `OpenSSH/Operational` if OpenSSH Server is installed. The
installer turns on Windows logon auditing so these events are recorded. Log: `C:\ProgramData\TgAlert\agent.log`.
