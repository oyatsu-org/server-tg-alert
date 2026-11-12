#!/usr/bin/env bash
# =====================================================================
#  VPS Telegram Alerts - one-file installer
#
#  Install:    curl -fsSL https://raw.githubusercontent.com/oyatsu-org/server-tg-alert/main/tg-alert.sh | sudo bash
#  Uninstall:  curl -fsSL https://raw.githubusercontent.com/oyatsu-org/server-tg-alert/main/tg-alert.sh | sudo bash -s uninstall
#  Non-interactive:
#     curl -fsSL https://raw.githubusercontent.com/oyatsu-org/server-tg-alert/main/tg-alert.sh | sudo BOT_TOKEN=xxx CHAT_ID=yyy bash
#
#  Alerts: server start / shutdown / reboot / unclean shutdown,
#          successful SSH + console login, failed SSH logins.
# =====================================================================
set -euo pipefail

CONF=/etc/tg-alert.conf
BIN=/usr/local/bin
STATE=/var/lib/tg-alert
UNITS=/etc/systemd/system

c_ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
c_warn() { printf '\033[33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
die()    { c_err "ERROR: $*"; exit 1; }

# Read from the keyboard even when this script is piped into bash.
ask() {  # ask VAR "prompt"
    local __v
    if [ -r /dev/tty ]; then read -rp "$2" __v </dev/tty || true
    else die "no terminal available - pass BOT_TOKEN=... CHAT_ID=... as environment variables"; fi
    printf -v "$1" '%s' "$__v"
}

[ "$(id -u)" -eq 0 ] || die "please run as root (use: ... | sudo bash)"
command -v systemctl >/dev/null && command -v journalctl >/dev/null || die "systemd is required"

# =====================================================================
#  Embedded files
# =====================================================================
write_files() {

cat > "$BIN/tg-alert-send" <<'EOF_SEND'
#!/usr/bin/env bash
# Send a message to Telegram.  Usage: tg-alert-send "text"   or   echo text | tg-alert-send
CONF=/etc/tg-alert.conf
[ -r "$CONF" ] || { echo "tg-alert: cannot read $CONF" >&2; exit 1; }
. "$CONF"
[ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ] || { echo "tg-alert: BOT_TOKEN/CHAT_ID not set" >&2; exit 1; }

if [ $# -gt 0 ]; then TEXT="$*"; else TEXT="$(cat)"; fi
[ -n "$TEXT" ] || exit 0
HOST="${SERVER_NAME:-$(hostname -f 2>/dev/null || hostname)}"
TEXT="[$HOST]
$TEXT"
TEXT="${TEXT:0:4000}"

deadline=$(( $(date +%s) + ${RETRY_SECONDS:-60} ))
while :; do
    if curl -fsS --max-time 10 "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" --data-urlencode "text=${TEXT}" \
        -d "disable_web_page_preview=true" >/dev/null 2>&1; then
        exit 0
    fi
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 3
done
echo "tg-alert: failed to send message to Telegram" >&2
logger -t tg-alert "failed to send message to Telegram" 2>/dev/null
exit 1
EOF_SEND

cat > "$BIN/tg-alert-power" <<'EOF_POWER'
#!/usr/bin/env bash
# tg-alert-power start|stop   (called by tg-alert-power.service)
STATE_DIR=/var/lib/tg-alert
MARKER="$STATE_DIR/clean-shutdown"
mkdir -p "$STATE_DIR"
now() { date '+%Y-%m-%d %H:%M:%S %Z'; }
ips() { hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' | head -3 | paste -sd ' '; }

case "$1" in
start)
    prev=""
    if [ -f "$STATE_DIR/was-running" ] && [ ! -f "$MARKER" ]; then
        prev="⚠️ Previous shutdown was NOT clean (crash, hard reset or power loss)."
    fi
    rm -f "$MARKER"
    touch "$STATE_DIR/was-running"
    if [ -f "$STATE_DIR/skip-start-msg" ]; then rm -f "$STATE_DIR/skip-start-msg"; exit 0; fi
    msg="🟢 Server STARTED
Time: $(now)
Kernel: $(uname -r)
IP: $(ips)"
    [ -n "$prev" ] && msg="$msg
$prev"
    /usr/local/bin/tg-alert-send "$msg"
    ;;
stop)
    touch "$MARKER"
    if systemctl list-jobs 2>/dev/null | grep -qE 'reboot\.target|kexec\.target'; then
        what="🔄 Server REBOOTING"
    elif systemctl list-jobs 2>/dev/null | grep -qE 'poweroff\.target|halt\.target'; then
        what="🔴 Server SHUTTING DOWN"
    else
        what="🔴 Server SHUTTING DOWN / alert service stopped"
    fi
    RETRY_SECONDS=10 /usr/local/bin/tg-alert-send "$what
Time: $(now)
Uptime: $(uptime -p 2>/dev/null)"
    ;;
esac
exit 0
EOF_POWER

cat > "$BIN/tg-alert-login" <<'EOF_LOGIN'
#!/usr/bin/env bash
# Called by PAM (pam_exec) on session open/close.
CONF=/etc/tg-alert.conf
[ -r "$CONF" ] && . "$CONF"
case "$PAM_TYPE" in
open_session)  icon="✅"; title="LOGIN" ;;
close_session) [ "${NOTIFY_LOGOUT:-0}" = "1" ] || exit 0; icon="👋"; title="LOGOUT" ;;
*) exit 0 ;;
esac
for ip in ${IGNORE_LOGIN_IPS:-}; do [ "$ip" = "$PAM_RHOST" ] && exit 0; done
msg="$icon $title
User: ${PAM_USER:-?}
From: ${PAM_RHOST:-local console}
Service: ${PAM_SERVICE:-?}  TTY: ${PAM_TTY:-?}
Time: $(date '+%Y-%m-%d %H:%M:%S %Z')"
# background so login is never delayed
setsid /usr/local/bin/tg-alert-send "$msg" </dev/null >/dev/null 2>&1 &
exit 0
EOF_LOGIN

cat > "$BIN/tg-alert-failwatch" <<'EOF_FAIL'
#!/usr/bin/env bash
# Watches sshd logs for failed logins; groups them every FAIL_BATCH_SECONDS (0 = instant).
. /etc/tg-alert.conf
BATCH=${FAIL_BATCH_SECONDS:-300}
declare -A CONN_IP IP_COUNT IP_USERS
total=0
last_flush=$(date +%s)

record() {  # pid user ip
    local pid=$1 user=$2 ip=$3
    if [ "$BATCH" -eq 0 ]; then
        [ -n "${CONN_IP[$pid]}" ] && return
        CONN_IP[$pid]=$ip
        [ "${#CONN_IP[@]}" -gt 1000 ] && CONN_IP=()
        /usr/local/bin/tg-alert-send "❌ FAILED LOGIN
User: $user
From: $ip
Time: $(date '+%Y-%m-%d %H:%M:%S %Z')" &
        return
    fi
    if [ -z "${CONN_IP[$pid]}" ]; then
        CONN_IP[$pid]=$ip
        IP_COUNT[$ip]=$(( ${IP_COUNT[$ip]:-0} + 1 ))
        total=$((total + 1))
    fi
    case " ${IP_USERS[$ip]} " in
        *" $user "*) ;;
        *) IP_USERS[$ip]="${IP_USERS[$ip]:+${IP_USERS[$ip]} }$user" ;;
    esac
}

flush() {
    last_flush=$(date +%s)
    [ "$total" -gt 0 ] || return
    local period lines ip users msg cnt
    if [ "$BATCH" -ge 60 ]; then period="$((BATCH / 60)) min"; else period="${BATCH}s"; fi
    msg="❌ $total FAILED SSH LOGIN attempt(s) in the last $period"
    lines=$(for ip in "${!IP_COUNT[@]}"; do echo "${IP_COUNT[$ip]} $ip"; done | sort -rn | head -15)
    while read -r cnt ip; do
        users=${IP_USERS[$ip]}
        [ ${#users} -gt 60 ] && users="${users:0:60}…"
        msg="$msg
• $ip — ${cnt}x (users: $users)"
    done <<< "$lines"
    [ "${#IP_COUNT[@]}" -gt 15 ] && msg="$msg
…and $(( ${#IP_COUNT[@]} - 15 )) more IPs"
    /usr/local/bin/tg-alert-send "$msg" &
    CONN_IP=(); IP_COUNT=(); IP_USERS=(); total=0
}

journalctl -f -n0 -o short -t sshd -t sshd-session -t sshd-auth 2>/dev/null |
while :; do
    if IFS= read -r -t 5 line; then
        pid=$(sed -nE 's/.*sshd(-session|-auth)?\[([0-9]+)\]:.*/\2/p' <<< "$line")
        [ -n "$pid" ] || pid=$RANDOM
        if [[ $line =~ Failed\ [a-z/-]+\ for\ (invalid\ user\ )?(.*)\ from\ ([0-9a-fA-F.:]+)\ port ]]; then
            record "$pid" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
        elif [[ $line =~ Invalid\ user\ (.*)\ from\ ([0-9a-fA-F.:]+)\ port ]]; then
            record "$pid" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        elif [[ $line =~ Connection\ closed\ by\ authenticating\ user\ (.*)\ ([0-9a-fA-F.:]+)\ port\ [0-9]+\ \[preauth\] ]]; then
            record "$pid" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
        fi
    elif [ $? -le 128 ]; then
        flush; wait
        exit 1
    fi
    [ "$BATCH" -gt 0 ] && [ $(( $(date +%s) - last_flush )) -ge "$BATCH" ] && flush
done
EOF_FAIL

chmod 755 "$BIN"/tg-alert-send "$BIN"/tg-alert-power "$BIN"/tg-alert-login "$BIN"/tg-alert-failwatch

cat > "$UNITS/tg-alert-power.service" <<'EOF_U1'
[Unit]
Description=Telegram alert on server start / shutdown / reboot
Wants=network-online.target
After=network-online.target nss-lookup.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/tg-alert-power start
ExecStop=/usr/local/bin/tg-alert-power stop
TimeoutStartSec=90
TimeoutStopSec=20

[Install]
WantedBy=multi-user.target
EOF_U1

cat > "$UNITS/tg-alert-failwatch.service" <<'EOF_U2'
[Unit]
Description=Telegram alert on failed SSH logins
Wants=network-online.target
After=network-online.target systemd-journald.service

[Service]
Type=simple
ExecStart=/usr/local/bin/tg-alert-failwatch
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF_U2
}

# =====================================================================
#  Telegram setup helpers
# =====================================================================
tg_api() { curl -fsS --max-time 30 "https://api.telegram.org/bot${BOT_TOKEN}/$1" "${@:2}"; }

get_token() {
    while :; do
        if [ -z "${BOT_TOKEN:-}" ]; then
            echo
            echo "1) In Telegram, open @BotFather and send /newbot"
            echo "2) Copy the token it gives you (looks like 123456789:AAH...)"
            ask BOT_TOKEN "Bot token: "
        fi
        BOT_TOKEN="$(echo "$BOT_TOKEN" | tr -d '[:space:]')"
        if [[ ! $BOT_TOKEN =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then
            c_err "That doesn't look like a bot token."; BOT_TOKEN=""; continue
        fi
        local me
        if me=$(tg_api getMe 2>/dev/null); then
            BOT_NAME=$(echo "$me" | grep -o '"username":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
            c_ok "✔ Bot OK: @$BOT_NAME"
            return
        fi
        c_err "Telegram rejected this token (or no internet). Try again."
        BOT_TOKEN=""
    done
}

get_chat_id() {
    [ -n "${CHAT_ID:-}" ] && return
    echo
    echo "Now open https://t.me/$BOT_NAME in Telegram and press START (or send any message)."
    echo "Waiting for your message... (or type your chat ID and press Enter)"
    # clear old updates so we pick up the new message
    local offset=0 upd id
    upd=$(tg_api getUpdates 2>/dev/null || true)
    id=$(echo "$upd" | grep -o '"update_id":[0-9]*' | tail -1 | cut -d: -f2 || true)
    [ -n "$id" ] && offset=$((id + 1))

    local end=$(( $(date +%s) + 300 )) typed=""
    while [ "$(date +%s)" -lt "$end" ]; do
        upd=$(tg_api "getUpdates?offset=$offset&timeout=0" 2>/dev/null || true)
        CHAT_ID=$(echo "$upd" | grep -o '"chat":{"id":-\?[0-9]*' | tail -1 | grep -o -- '-\?[0-9]*$' || true)
        if [ -n "$CHAT_ID" ]; then
            c_ok "✔ Got chat ID: $CHAT_ID"
            # acknowledge so the message is not seen again
            id=$(echo "$upd" | grep -o '"update_id":[0-9]*' | tail -1 | cut -d: -f2 || true)
            [ -n "$id" ] && { tg_api "getUpdates?offset=$((id + 1))" >/dev/null 2>&1 || true; }
            return
        fi
        # let the user type an ID instead (3s window per loop)
        if [ -r /dev/tty ] && read -r -t 3 typed </dev/tty; then
            typed=$(echo "$typed" | tr -d '[:space:]')
            if [[ $typed =~ ^-?[0-9]+$ ]]; then CHAT_ID=$typed; return; fi
        fi
    done
    die "no message received in 5 minutes. Run the installer again."
}

write_conf() {
    cat > "$CONF" <<EOF
# Telegram VPS alerts - settings  (after editing: systemctl restart tg-alert-failwatch)
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"

# Name shown in every message (empty = hostname)
SERVER_NAME="${SERVER_NAME:-}"

# Failed logins are grouped into one message every N seconds (0 = one message per failure)
FAIL_BATCH_SECONDS=${FAIL_BATCH_SECONDS:-300}

# 1 = also notify on logout
NOTIFY_LOGOUT=${NOTIFY_LOGOUT:-0}

# Space separated IPs whose successful logins should NOT trigger an alert
IGNORE_LOGIN_IPS="${IGNORE_LOGIN_IPS:-}"
EOF
    chown root:root "$CONF"; chmod 600 "$CONF"
}

# =====================================================================
#  Commands
# =====================================================================
PAM_LINE="session optional pam_exec.so quiet /usr/local/bin/tg-alert-login"

do_install() {
    echo "=== VPS Telegram Alerts installer ==="

    if ! command -v curl >/dev/null; then
        echo "Installing curl..."
        if command -v apt-get >/dev/null; then apt-get update -qq && apt-get install -y -qq curl
        elif command -v dnf >/dev/null; then dnf install -y -q curl
        elif command -v yum >/dev/null; then yum install -y -q curl
        else die "please install curl first"; fi
    fi

    # Reuse existing config on re-install?
    if [ -f "$CONF" ] && [ -z "${BOT_TOKEN:-}" ]; then
        local ans; ask ans "Existing settings found in $CONF. Keep them? [Y/n] "
        if [[ ! $ans =~ ^[Nn] ]]; then
            # shellcheck source=/dev/null
            . "$CONF"
        fi
    fi

    get_token
    get_chat_id
    write_conf

    mkdir -p "$BIN" "$STATE"
    write_files

    echo "Sending test message..."
    if ! RETRY_SECONDS=5 "$BIN/tg-alert-send" "🔔 Telegram alerts installed on this server. This is a test message."; then
        die "could not send to chat $CHAT_ID. Did you press START in the bot chat?"
    fi
    c_ok "✔ Test message sent - check Telegram"

    # Successful logins (SSH + console) via PAM
    local f
    for f in /etc/pam.d/sshd /etc/pam.d/login; do
        [ -f "$f" ] || continue
        if ! grep -qF tg-alert-login "$f"; then
            cp -a "$f" "$f.tg-alert.bak"
            printf '\n# Telegram login alert\n%s\n' "$PAM_LINE" >> "$f"
        fi
    done
    if command -v sshd >/dev/null && ! sshd -T 2>/dev/null | grep -qi '^usepam yes'; then
        c_warn "WARNING: 'UsePAM yes' is not active in sshd_config - SSH login alerts will not work."
    fi

    systemctl daemon-reload
    systemctl enable tg-alert-power.service tg-alert-failwatch.service >/dev/null 2>&1
    systemctl restart tg-alert-failwatch.service
    if ! systemctl is-active -q tg-alert-power.service; then
        touch "$STATE/skip-start-msg"   # no "Server STARTED" message right now
        systemctl start tg-alert-power.service
    fi

    echo
    c_ok "=== Done! ==="
    cat <<EOF
You will now get Telegram alerts for:
  🟢 server start   🔴 shutdown   🔄 reboot   ⚠️ crash / power loss
  ✅ SSH / console login   ❌ failed SSH logins (grouped every 5 min)

Settings : $CONF
Test     : tg-alert-send "hello"
Uninstall: curl -fsSL https://raw.githubusercontent.com/oyatsu-org/server-tg-alert/main/tg-alert.sh | sudo bash -s uninstall
EOF
}

do_uninstall() {
    mkdir -p "$STATE" && touch "$STATE/clean-shutdown"
    systemctl disable --now tg-alert-failwatch.service 2>/dev/null || true
    systemctl disable tg-alert-power.service 2>/dev/null || true   # not stopped: would send "shutting down"
    rm -f "$UNITS/tg-alert-power.service" "$UNITS/tg-alert-failwatch.service"
    systemctl daemon-reload
    local f
    for f in /etc/pam.d/sshd /etc/pam.d/login; do
        [ -f "$f" ] || continue
        sed -i '/# Telegram login alert/d; /tg-alert-login/d' "$f"
        rm -f "$f.tg-alert.bak"
    done
    rm -f "$BIN"/tg-alert-send "$BIN"/tg-alert-power "$BIN"/tg-alert-login "$BIN"/tg-alert-failwatch
    rm -rf "$STATE" "$CONF"
    c_ok "Telegram alerts removed."
}

case "${1:-install}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    *) echo "usage: tg-alert.sh [install|uninstall]"; exit 2 ;;
esac
