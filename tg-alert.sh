#!/usr/bin/env bash
# =====================================================================
#  VPS Telegram Alerts - one-file installer
#
#  Install:    curl -fsSL https://raw.githubusercontent.com/oyatsu-org/server-tg-alert/main/tg-alert.sh | sudo bash
#  Uninstall:  curl -fsSL https://raw.githubusercontent.com/oyatsu-org/server-tg-alert/main/tg-alert.sh | sudo bash -s uninstall
#  Non-interactive:
#     curl -fsSL https://raw.githubusercontent.com/oyatsu-org/server-tg-alert/main/tg-alert.sh | sudo BOT_TOKEN=xxx CHAT_ID=yyy SERVER_NAME="My VPS" ENABLE_USEPAM=yes bash
#
#  Alerts: server start / shutdown / reboot / unclean shutdown,
#          successful SSH + console login, failed SSH logins.
# =====================================================================
set -euo pipefail

CONF=/etc/tg-alert.conf
ENV_SERVER_NAME="${SERVER_NAME:-}"   # set when passed as SERVER_NAME=... on the command line
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

# Like ask, but shows * for each character (for the bot token).
ask_secret() {  # ask_secret VAR "prompt"
    [ -r /dev/tty ] || die "no terminal available - pass BOT_TOKEN=... CHAT_ID=... as environment variables"
    local __v="" __c
    printf '%s' "$2" >/dev/tty
    while IFS= read -rsn1 __c </dev/tty; do
        case "$__c" in
            ""|$'\n'|$'\r') break ;;
            $'\x7f'|$'\b') if [ -n "$__v" ]; then __v="${__v%?}"; printf '\b \b' >/dev/tty; fi ;;
            *) __v+="$__c"; printf '*' >/dev/tty ;;
        esac
    done
    echo >/dev/tty
    # drop terminal "bracketed paste" markers if the terminal added them
    __v="${__v//$'\e[200~'/}"; __v="${__v//$'\e[201~'/}"
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
            ask_secret BOT_TOKEN "Bot token: "
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

valid_chat_id() { [[ $1 =~ ^-?[0-9]+$ || $1 =~ ^@[A-Za-z0-9_]{5,}$ ]]; }

get_chat_id() {
    if [ -n "${CHAT_ID:-}" ]; then
        valid_chat_id "$CHAT_ID" && return
        c_warn "Ignoring invalid CHAT_ID '$CHAT_ID' (must be a number like 987654321) - detecting it automatically."
        CHAT_ID=""
    fi
    echo
    echo "Now open https://t.me/$BOT_NAME in Telegram and press START (or send any message)."
    echo "Waiting for your message... (or type your chat ID and press Enter)"

    local end=$(( $(date +%s) + 300 )) typed="" upd chat who id warned=""
    while [ "$(date +%s)" -lt "$end" ]; do
        upd=$(curl -sS --max-time 30 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates" 2>/dev/null || true)
        if [ -z "$warned" ] && grep -q '"ok":false' <<<"$upd"; then
            c_warn "Telegram: $(grep -o '"description":"[^"]*"' <<<"$upd" | cut -d'"' -f4 || true)"
            c_warn "Type your chat ID manually instead."
            warned=1
        fi
        # newest chat that wrote to the bot (messages already sent before this step count too)
        chat=$(grep -o '"chat":{[^}]*}' <<<"$upd" | tail -1 || true)
        CHAT_ID=$(grep -o '"id":-\?[0-9]*' <<<"$chat" | head -1 | cut -d: -f2 || true)
        if [ -n "$CHAT_ID" ]; then
            who=$(grep -o '"\(username\|first_name\|title\)":"[^"]*"' <<<"$chat" | head -1 | cut -d'"' -f4 || true)
            c_ok "✔ Got chat ID: $CHAT_ID${who:+ ($who)}"
            # acknowledge so the message is not seen again
            id=$(grep -o '"update_id":[0-9]*' <<<"$upd" | tail -1 | cut -d: -f2 || true)
            [ -n "$id" ] && { tg_api "getUpdates?offset=$((id + 1))" >/dev/null 2>&1 || true; }
            return
        fi
        # let the user type an ID instead (3s window per loop)
        if [ -r /dev/tty ] && read -r -t 3 typed </dev/tty; then
            typed=$(echo "$typed" | tr -d '[:space:]')
            if valid_chat_id "$typed"; then CHAT_ID=$typed; return; fi
            [ -n "$typed" ] && c_err "'$typed' is not a valid chat ID (a number like 987654321)."
        fi
    done
    die "no message received in 5 minutes. Run the installer again."
}

send_test() {
    echo "Sending test message..."
    local resp
    resp=$(curl -sS --max-time 20 "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "text=[${SERVER_NAME}]
🔔 Telegram alerts installed on this server. This is a test message." 2>&1 || true)
    grep -q '"ok":true' <<<"$resp" && return 0
    TG_ERR=$(grep -o '"description":"[^"]*"' <<<"$resp" | cut -d'"' -f4 || true)
    [ -n "$TG_ERR" ] || TG_ERR=$(head -c 200 <<<"$resp")
    return 1
}

get_server_name() {
    # Given on the command line (SERVER_NAME=... bash) -> don't ask
    if [ -z "$ENV_SERVER_NAME" ]; then
        local def="${SERVER_NAME:-$(hostname)}" n=""
        if [ -r /dev/tty ]; then
            echo
            ask n "Server name shown in alerts [$def]: "
        fi
        SERVER_NAME="${n:-$def}"
    fi
    # strip characters that would break the config file
    SERVER_NAME="$(printf '%s' "$SERVER_NAME" | tr -d '"$`\\')"
    c_ok "✔ Server name: $SERVER_NAME"
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

# value of an sshd setting from "sshd -T" output:  sshd_opt "$output" usepam
sshd_opt() { awk -v k="$2" 'tolower($1)==k {print tolower($2); exit}' <<<"$1"; }

sshd_dump() {
    # sshd -T fails on socket-activated systems (Ubuntu 24.04+) if this dir is missing
    [ -d /run/sshd ] || mkdir -p -m 0755 /run/sshd
    sshd -T 2>&1
}

check_usepam() {
    command -v sshd >/dev/null || return 0
    local out cur ans="n"
    if ! out=$(sshd_dump); then
        c_warn "Could not check the SSH server config: $(head -1 <<<"$out")"
        return 0
    fi
    cur=$(sshd_opt "$out" usepam)
    [ "$cur" = yes ] && return 0
    if [ -z "$cur" ]; then
        c_warn "This SSH server was built without PAM support - SSH login alerts will not work."
        return 0
    fi

    echo
    c_warn "SSH login alerts need 'UsePAM yes' in the SSH server config, but it is turned off."
    if [ -n "${ENABLE_USEPAM:-}" ]; then
        ans=$ENABLE_USEPAM
    elif [ -r /dev/tty ]; then
        ask ans "Turn it on now? Your current SSH session stays connected. [Y/n] "
        ans=${ans:-y}
    fi
    if [[ ! $ans =~ ^[Yy] ]]; then
        c_warn "Skipped - SSH login alerts will not work. (Run the installer again to enable it later.)"
        return 0
    fi
    enable_usepam "$out"
}

enable_usepam() {
    local before=$1 cfg=${SSHD_CONFIG:-/etc/ssh/sshd_config} ts f out kbd_key kbd pw
    local files=("$cfg")
    ts=$(date +%Y%m%d-%H%M%S)
    for f in "$cfg.d"/*.conf; do [ -f "$f" ] && files+=("$f"); done

    for f in "${files[@]}"; do cp -a "$f" "$f.tg-alert-$ts.bak"; done
    restore() {
        for f in "${files[@]}"; do cp -a "$f.tg-alert-$ts.bak" "$f"; rm -f "$f.tg-alert-$ts.bak"; done
    }

    # 1) change any "UsePAM no" to "UsePAM yes"
    for f in "${files[@]}"; do
        sed -i -E 's/^([[:space:]]*)usepam[[:space:]]+no([[:space:]]|$).*/\1UsePAM yes/I' "$f"
    done
    # 2) still off (no line at all)? add it at the top of sshd_config
    out=$(sshd_dump || true)
    if [ "$(sshd_opt "$out" usepam)" != yes ]; then
        { printf '# Added by tg-alert (Telegram login alerts)\nUsePAM yes\n\n'; cat "$cfg"; } > "$cfg.tg-alert.tmp"
        cat "$cfg.tg-alert.tmp" > "$cfg"; rm -f "$cfg.tg-alert.tmp"
        out=$(sshd_dump || true)
    fi
    # 3) safety: with PAM on, keyboard-interactive auth could allow password logins.
    #    If password login was off before, make sure it stays off.
    pw=$(sshd_opt "$before" passwordauthentication)
    kbd_key=kbdinteractiveauthentication
    kbd=$(sshd_opt "$out" $kbd_key)
    if [ -z "$kbd" ]; then kbd_key=challengeresponseauthentication; kbd=$(sshd_opt "$out" $kbd_key); fi
    if [ "$pw" = no ] && [ "$kbd" = yes ]; then
        local kw=KbdInteractiveAuthentication
        [ "$kbd_key" = challengeresponseauthentication ] && kw=ChallengeResponseAuthentication
        { printf '# Added by tg-alert: keep password logins disabled\n%s no\n' "$kw"; cat "$cfg"; } > "$cfg.tg-alert.tmp"
        cat "$cfg.tg-alert.tmp" > "$cfg"; rm -f "$cfg.tg-alert.tmp"
    fi

    # 4) validate, or roll back
    if ! sshd -t 2>/dev/null || [ "$(sshd_opt "$(sshd_dump)" usepam)" != yes ]; then
        restore
        c_err "Could not enable UsePAM safely - SSH config restored, nothing changed."
        return 0
    fi

    # keep backups only of files that actually changed
    for f in "${files[@]}"; do
        cmp -s "$f" "$f.tg-alert-$ts.bak" && rm -f "$f.tg-alert-$ts.bak"
    done

    # 5) apply (reload keeps existing connections; socket-activated sshd picks it up on next login)
    local s
    for s in ssh sshd; do
        systemctl is-active -q "$s" 2>/dev/null && systemctl reload "$s" 2>/dev/null || true
    done
    c_ok "✔ UsePAM enabled. Backup of the old SSH config:"
    for f in "${files[@]}"; do [ -f "$f.tg-alert-$ts.bak" ] && echo "    $f.tg-alert-$ts.bak"; done; true
}

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
    get_server_name

    # Test before saving anything; on failure ask for the chat again.
    until send_test; do
        c_err "Could not send to chat $CHAT_ID: ${TG_ERR:-no answer from Telegram}"
        [ -r /dev/tty ] || die "fix BOT_TOKEN / CHAT_ID and run again."
        echo "Make sure you pressed START in the chat with @$BOT_NAME."
        CHAT_ID=""
        get_chat_id
    done
    c_ok "✔ Test message sent - check Telegram"

    write_conf
    mkdir -p "$BIN" "$STATE"
    write_files

    # Successful logins (SSH + console) via PAM
    local f
    for f in /etc/pam.d/sshd /etc/pam.d/login; do
        [ -f "$f" ] || continue
        if ! grep -qF tg-alert-login "$f"; then
            cp -a "$f" "$f.tg-alert.bak"
            printf '\n# Telegram login alert\n%s\n' "$PAM_LINE" >> "$f"
        fi
    done
    check_usepam

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
