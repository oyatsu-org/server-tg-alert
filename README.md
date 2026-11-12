# VPS Telegram Alerts

Get a Telegram message when your VPS:

- 🟢 starts (⚠️ also warns if the last shutdown was a crash or power loss)
- 🔴 shuts down / 🔄 reboots
- ✅ gets a successful SSH or console login
- ❌ gets failed SSH logins (grouped into one message every 5 min)

## Install (one command, on any new VPS)

```bash
curl -fsSL https://raw.githubusercontent.com/oyatsu-org/server-tg-alert/main/tg-alert.sh | sudo bash
```

The installer asks for your **bot token**, then tells you to press **START** in
your bot's chat. It finds your chat ID automatically, asks for a **server name**
(shown in every alert, press Enter to use the hostname), and sends a test message.

Don't have a bot yet? In Telegram, open **@BotFather**, send `/newbot`, and copy the token.

### Without any questions (for automation)
```bash
curl -fsSL https://raw.githubusercontent.com/oyatsu-org/server-tg-alert/main/tg-alert.sh | sudo BOT_TOKEN=123:ABC CHAT_ID=987654321 SERVER_NAME="My VPS" bash
```

### Uninstall
```bash
curl -fsSL https://raw.githubusercontent.com/oyatsu-org/server-tg-alert/main/tg-alert.sh | sudo bash -s uninstall
```

## Settings
Edit `/etc/tg-alert.conf`, then run `sudo systemctl restart tg-alert-failwatch`.

| Option | Default | Meaning |
|---|---|---|
| `FAIL_BATCH_SECONDS` | 300 | Group failed logins into one message every N seconds. `0` = one message per failed connection (noisy). |
| `NOTIFY_LOGOUT` | 0 | `1` = also alert on logout |
| `IGNORE_LOGIN_IPS` | empty | Your own IPs that shouldn't trigger login alerts |
| `SERVER_NAME` | hostname | Name shown in each message |

Test: `tg-alert-send "hello"`. Logs: `journalctl -u tg-alert-failwatch -u tg-alert-power`

## Notes
- Needs a systemd-based Linux (Ubuntu, Debian, CentOS/Rocky/Alma, …).
- A sudden power cut can't send a shutdown message. You get the ⚠️ warning at the next boot instead.
- SSH login alerts need `UsePAM yes` in sshd_config (the default on most distros).
