# =====================================================================
#  Windows Telegram Alerts - one-file installer
#
#  Install (PowerShell as Administrator):
#    irm https://raw.githubusercontent.com/oyatsu-org/server-tg-alert/main/tg-alert-windows.ps1 | iex
#
#  Uninstall:
#    $env:TG_ALERT_UNINSTALL=1; irm https://raw.githubusercontent.com/oyatsu-org/server-tg-alert/main/tg-alert-windows.ps1 | iex
#    (or run C:\ProgramData\TgAlert\uninstall.ps1)
#
#  No questions (automation):
#    $env:BOT_TOKEN='123:ABC'; $env:CHAT_ID='987654321'; $env:SERVER_NAME='My Server'; irm ... | iex
#
#  Alerts: start / shutdown / restart / crash, Remote Desktop + console +
#          OpenSSH logins, failed logins (instant, with flood limit).
#  Works with Windows PowerShell 5.1 (Windows 10/11, Server 2016+).
# =====================================================================

& {
$ErrorActionPreference = 'Stop'
$Dir      = 'C:\ProgramData\TgAlert'
$TaskName = 'TgAlert'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Ok($m)   { Write-Host $m -ForegroundColor Green }
function Warn($m) { Write-Host $m -ForegroundColor Yellow }
function Err($m)  { Write-Host $m -ForegroundColor Red }

# ---------------------------------------------------------------------
#  Agent: runs in the background as SYSTEM (scheduled task "TgAlert")
# ---------------------------------------------------------------------
$AgentCode = @'
# TgAlert agent - started by the scheduled task "TgAlert" (runs as SYSTEM)
$ErrorActionPreference = 'Continue'
$Dir = 'C:\ProgramData\TgAlert'
$Cfg = Get-Content "$Dir\config.json" -Raw | ConvertFrom-Json
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function U([int]$cp) { [char]::ConvertFromUtf32($cp) }
$IC = @{ start = U 0x1F7E2; stop = U 0x1F534; reboot = U 0x1F504; warn = (U 0x26A0) + (U 0xFE0F)
         ok = U 0x2705; fail = U 0x274C; dot = U 0x2022; dash = U 0x2014 }
$ServerName = if ($Cfg.ServerName) { $Cfg.ServerName } else { $env:COMPUTERNAME }
$IgnoreIps  = @($Cfg.IgnoreLoginIps)
$BATCH = [int]$Cfg.FailBatchSeconds
$MAX   = if ($Cfg.FailInstantMax) { [int]$Cfg.FailInstantMax } else { 20 }

function Write-Log($m) {
    try {
        $f = "$Dir\agent.log"
        if ((Test-Path $f) -and (Get-Item $f).Length -gt 1MB) { Move-Item $f "$f.old" -Force }
        Add-Content $f ("{0}  {1}" -f (Get-Date -Format 's'), $m)
    } catch {}
}
function Now { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' UTC' + (Get-Date).ToString('zzz') }

function Send-Tg([string]$Text, [int]$RetrySeconds = 20) {
    $t = "[$ServerName]`n$Text"
    if ($t.Length -gt 4000) { $t = $t.Substring(0, 4000) }
    $body  = @{ chat_id = "$($Cfg.ChatId)"; text = $t; disable_web_page_preview = $true } | ConvertTo-Json -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $deadline = (Get-Date).AddSeconds($RetrySeconds)
    do {
        try {
            Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$($Cfg.BotToken)/sendMessage" `
                -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 10 -UseBasicParsing | Out-Null
            return $true
        } catch { Start-Sleep -Seconds 3 }
    } while ((Get-Date) -lt $deadline)
    Write-Log "failed to send: $($Text.Split("`n")[0])"
    return $false
}

function Get-Data($rec) {
    $h = @{}
    $x = [xml]$rec.ToXml()
    foreach ($d in $x.Event.EventData.Data) { if ($d.Name) { $h[$d.Name] = "$($d.'#text')" } }
    return $h
}

function Get-Uptime {
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $u = (Get-Date) - $boot
    return ('{0}d {1}h {2}m' -f $u.Days, $u.Hours, $u.Minutes)
}

# ----- logins -----
$LogonTypes = @{ '2' = 'Console'; '3' = 'Network'; '7' = 'Remote Desktop (reconnect)'; '8' = 'Network (cleartext)'
                 '10' = 'Remote Desktop'; '11' = 'Console (cached)' }
$SeenLogon = @{}

function Send-Login($user, $ip, $type) {
    $from = if ($ip) { $ip } else { 'local console' }
    Send-Tg "$($IC.ok) LOGIN`nUser: $user`nFrom: $from`nType: $type`nTime: $(Now)" | Out-Null
}

function On-Logon($rec) {
    $d = Get-Data $rec
    $t = $d['LogonType']; $ip = $d['IpAddress']; $user = $d['TargetUserName']; $dom = $d['TargetDomainName']
    if ($user -like '*$' -or $dom -in @('Window Manager', 'Font Driver Host', 'NT AUTHORITY')) { return }
    $remote = $ip -and ($ip -notin @('-', '127.0.0.1', '::1'))
    $wanted = ($t -in @('2', '10', '11')) -or ($t -eq '7' -and $remote) -or
              ($Cfg.NotifyNetworkLogons -and $t -in @('3', '8') -and $remote)
    if (-not $wanted) { return }
    # Admin logons create two linked events (normal + elevated token) -> alert once
    $linked = $d['TargetLinkedLogonId']
    if ($linked -and $linked -ne '0x0' -and $SeenLogon.ContainsKey($linked)) { return }
    $SeenLogon[$d['TargetLogonId']] = 1
    if ($SeenLogon.Count -gt 500) { $SeenLogon.Clear() }
    if ($remote -and $IgnoreIps -contains $ip) { return }
    $who = if ($dom -and $dom -ne $env:COMPUTERNAME) { "$dom\$user" } else { $user }
    Send-Login $who ($(if ($remote) { $ip } else { '' })) $LogonTypes[$t]
}

# ----- failed logins (instant with flood limit, or periodic summary) -----
$Reasons = @{ '0xc000006a' = 'wrong password'; '0xc0000064' = 'user does not exist'; '0xc0000234' = 'account locked out'
              '0xc0000072' = 'account disabled'; '0xc000006f' = 'outside allowed logon hours'; '0xc0000070' = 'not allowed from this computer'
              '0xc0000071' = 'password expired'; '0xc0000193' = 'account expired'; '0xc0000224' = 'password must be changed'
              '0xc0000133' = 'clock out of sync'; '0xc000015b' = 'logon type not allowed'; '0xc000006d' = 'wrong username or password' }
$FailSeen = @{}; $IpCount = @{}; $IpUsers = @{}
$script:FailTotal = 0; $script:WinSent = 0; $script:LastFlush = Get-Date

function Add-Summary($ip, $user) {
    $script:FailTotal++
    $IpCount[$ip] = 1 + $(if ($IpCount.ContainsKey($ip)) { $IpCount[$ip] } else { 0 })
    if (-not $IpUsers.ContainsKey($ip)) { $IpUsers[$ip] = New-Object System.Collections.ArrayList }
    if (-not $IpUsers[$ip].Contains($user)) { [void]$IpUsers[$ip].Add($user) }
}

function Record-Fail($key, $user, $ip, $reason, $type) {
    if (-not $ip -or $ip -eq '-') { $ip = 'unknown' }
    if ($FailSeen.ContainsKey($key)) { return }       # one alert per connection
    $FailSeen[$key] = 1
    if ($FailSeen.Count -gt 2000) { $FailSeen.Clear() }
    if ($BATCH -gt 0) { Add-Summary $ip $user; return }
    if ($script:WinSent -lt $MAX) {
        $script:WinSent++
        Send-Tg "$($IC.fail) FAILED LOGIN`nUser: $user`nFrom: $ip`nReason: $reason`nType: $type`nTime: $(Now)" | Out-Null
    } else {
        Add-Summary $ip $user                          # flood: send as one summary
    }
}

function Flush {
    $script:LastFlush = Get-Date
    $script:WinSent = 0
    if ($script:FailTotal -le 0) { return }
    if ($BATCH -gt 0) {
        $p = if ($BATCH -ge 60) { "$([int]($BATCH / 60)) min" } else { "${BATCH}s" }
        $msg = "$($IC.fail) $($script:FailTotal) FAILED LOGIN attempt(s) in the last $p"
    } else {
        $msg = "$($IC.fail) +$($script:FailTotal) MORE FAILED LOGIN attempt(s) in the last minute`n(too many to send one by one - likely a brute-force attack)"
    }
    $top = $IpCount.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 15
    foreach ($e in $top) {
        $users = ($IpUsers[$e.Key] -join ' ')
        if ($users.Length -gt 60) { $users = $users.Substring(0, 60) + '...' }
        $msg += "`n$($IC.dot) $($e.Key) $($IC.dash) $($e.Value)x (users: $users)"
    }
    if ($IpCount.Count -gt 15) { $msg += "`n...and $($IpCount.Count - 15) more IPs" }
    Send-Tg $msg | Out-Null
    $IpCount.Clear(); $IpUsers.Clear(); $script:FailTotal = 0
}

function On-Fail($rec) {
    $d = Get-Data $rec
    if ($script:HasSsh -and $d['ProcessName'] -match 'sshd') { return }   # reported from the OpenSSH log
    $code = "$($d['SubStatus'])".ToLower()
    if (-not $code -or $code -eq '0x0') { $code = "$($d['Status'])".ToLower() }
    $reason = if ($Reasons.ContainsKey($code)) { $Reasons[$code] } else { "failed ($code)" }
    $t = $d['LogonType']
    $type = if ($LogonTypes.ContainsKey($t)) { $LogonTypes[$t] } else { "logon type $t" }
    if ($t -eq '3' -and $d['IpAddress'] -and $d['IpAddress'] -ne '-') { $type = 'Network / Remote Desktop (NLA)' }
    Record-Fail "sec$($rec.RecordId)" $d['TargetUserName'] $d['IpAddress'] $reason $type
}

# ----- OpenSSH server (if installed) -----
function On-Ssh($rec) {
    $m = "$(($rec.Properties | Select-Object -Last 1).Value)"
    $key = "ssh$($rec.ProcessId)"
    if ($m -match 'Accepted (\S+) for (.+) from (\S+) port') {
        if ($IgnoreIps -contains $Matches[3]) { return }
        Send-Login $Matches[2] $Matches[3] "SSH ($($Matches[1]))"
    } elseif ($m -match 'Failed (\S+) for (invalid user )?(.+) from (\S+) port') {
        $r = if ($Matches[2]) { 'user does not exist' } elseif ($Matches[1] -eq 'publickey') { 'SSH key not accepted' } else { 'wrong password' }
        Record-Fail $key $Matches[3] $Matches[4] $r 'SSH'
    } elseif ($m -match 'Invalid user (.+) from (\S+) port') {
        Record-Fail $key $Matches[1] $Matches[2] 'user does not exist' 'SSH'
    } elseif ($m -match 'Connection closed by authenticating user (.+) (\S+) port \d+ \[preauth\]') {
        Record-Fail $key $Matches[1] $Matches[2] 'no valid SSH key / gave up' 'SSH'
    }
}

# ----- shutdown / restart -----
function On-Shutdown($rec) {
    $p = @($rec.Properties | ForEach-Object { "$($_.Value)" })
    $proc = $p[0]; $reason = $p[2]; $kind = $p[4]; $comment = $p[5]; $user = $p[6]
    $title = if ($kind -match 'restart|neustart|red.marr|reinic|riavv') { "$($IC.reboot) Server RESTARTING" } else { "$($IC.stop) Server SHUTTING DOWN" }
    $procName = Split-Path $proc -Leaf
    $msg = "$title`nType: $kind`nBy: $user ($procName)`nReason: $reason"
    if ($comment) { $msg += "`nComment: $comment" }
    $msg += "`nTime: $(Now)`nUptime: $(Get-Uptime)"
    Send-Tg $msg 8 | Out-Null
}

# ----- event watchers -----
function New-Watcher($log, $xpath, $id) {
    try {
        $q = New-Object System.Diagnostics.Eventing.Reader.EventLogQuery($log, [System.Diagnostics.Eventing.Reader.PathType]::LogName, $xpath)
        $w = New-Object System.Diagnostics.Eventing.Reader.EventLogWatcher($q)
        Register-ObjectEvent -InputObject $w -EventName EventRecordWritten -SourceIdentifier $id | Out-Null
        $w.Enabled = $true
        return $w
    } catch { Write-Log "cannot watch ${log}: $_"; return $null }
}

$script:HasSsh = [bool](Get-WinEvent -ListLog 'OpenSSH/Operational' -ErrorAction SilentlyContinue)
$Watchers = @(
    (New-Watcher 'Security' '*[System[(EventID=4624 or EventID=4625)]]' 'tg-sec'),
    (New-Watcher 'System'   '*[System[(EventID=1074)]]'                 'tg-sys')
)
if ($script:HasSsh) { $Watchers += New-Watcher 'OpenSSH/Operational' '*' 'tg-ssh' }
Write-Log "agent started (ssh log: $($script:HasSsh))"

# ----- startup message (once per boot) -----
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $bootId = $os.LastBootUpTime.ToString('o')
    $stateFile = "$Dir\last-boot.txt"
    $last = if (Test-Path $stateFile) { (Get-Content $stateFile -Raw).Trim() } else { '' }
    if ($last -ne $bootId) {
        Set-Content $stateFile $bootId
        $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
                 Select-Object -ExpandProperty IPAddress -First 3) -join ' '
        $msg = "$($IC.start) Server STARTED`nTime: $(Now)`nOS: $($os.Caption)`nIP: $ips"
        $unclean = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 6008; StartTime = $os.LastBootUpTime.AddMinutes(-2) } -MaxEvents 1 -ErrorAction SilentlyContinue
        if ($unclean) { $msg += "`n$($IC.warn) Previous shutdown was NOT clean (crash, hard reset or power loss)." }
        Send-Tg $msg 180 | Out-Null
    }
} catch { Write-Log "startup: $_" }

$Period = if ($BATCH -gt 0) { $BATCH } else { 60 }
while ($true) {
    $ev = Wait-Event -Timeout 2
    if ($ev) {
        $rec = $ev.SourceEventArgs.EventRecord
        $src = $ev.SourceIdentifier
        Remove-Event -EventIdentifier $ev.EventIdentifier
        if ($rec) {
            try {
                switch ($src) {
                    'tg-sec' { if ($rec.Id -eq 4624) { On-Logon $rec } else { On-Fail $rec } }
                    'tg-sys' { On-Shutdown $rec }
                    'tg-ssh' { On-Ssh $rec }
                }
            } catch { Write-Log "handler ($src): $_" }
        }
    }
    if (((Get-Date) - $script:LastFlush).TotalSeconds -ge $Period) { Flush }
}
'@

$UninstallCode = @'
$ErrorActionPreference = 'SilentlyContinue'
Stop-ScheduledTask -TaskName 'TgAlert'
Unregister-ScheduledTask -TaskName 'TgAlert' -Confirm:$false
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*TgAlert\agent.ps1*' } |
    ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null }
Start-Sleep -Seconds 1
Remove-Item 'C:\ProgramData\TgAlert' -Recurse -Force
Write-Host 'Telegram alerts removed.' -ForegroundColor Green
'@

# ---------------------------------------------------------------------
#  Installer
# ---------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Err 'Please run PowerShell as Administrator (right-click PowerShell > Run as administrator) and try again.'
    return
}

if ($env:TG_ALERT_UNINSTALL) {
    Remove-Item Env:\TG_ALERT_UNINSTALL
    & ([scriptblock]::Create($UninstallCode))
    return
}

Write-Host '=== Windows Telegram Alerts installer ===' -ForegroundColor Cyan

function Tg($token, $method) {
    Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/$method" -TimeoutSec 30 -UseBasicParsing
}
function Valid-ChatId($c) { return ("$c" -match '^-?\d+$' -or "$c" -match '^@\w{5,}$') }

# --- existing settings ---
$old = $null
if (Test-Path "$Dir\config.json") {
    $old = Get-Content "$Dir\config.json" -Raw | ConvertFrom-Json
    if (-not $env:BOT_TOKEN) {
        $a = Read-Host "Existing settings found. Keep them? [Y/n]"
        if ($a -match '^[Nn]') { $old = $null }
    }
}

# --- bot token ---
$token = if ($env:BOT_TOKEN) { $env:BOT_TOKEN } elseif ($old) { $old.BotToken } else { '' }
$botName = $null
while (-not $botName) {
    if (-not $token) {
        Write-Host ''
        Write-Host '1) In Telegram, open @BotFather and send /newbot'
        Write-Host '2) Copy the token it gives you (looks like 123456789:AAH...)'
        $sec = Read-Host 'Bot token' -AsSecureString
        $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    }
    $token = $token.Trim()
    if ($token -notmatch '^\d+:[A-Za-z0-9_-]+$') { Err "That doesn't look like a bot token."; $token = ''; continue }
    try { $botName = (Tg $token 'getMe').result.username; Ok "[OK] Bot: @$botName" }
    catch { Err 'Telegram rejected this token (or no internet). Try again.'; $token = '' }
}

# --- chat id ---
function Find-ChatId {
    Write-Host ''
    Write-Host "Now open https://t.me/$botName in Telegram and press START (or send any message)."
    Write-Host 'Waiting for your message... (or type your chat ID and press Enter)'
    $end = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $end) {
        $r = $null
        try { $r = Tg $token 'getUpdates' } catch {}
        if ($r -and $r.result) {
            $chat = $null; $lastId = 0
            foreach ($u in $r.result) {
                $lastId = $u.update_id
                foreach ($k in 'message', 'edited_message', 'channel_post', 'my_chat_member') {
                    if ($u.$k -and $u.$k.chat) { $chat = $u.$k.chat }
                }
            }
            if ($chat) {
                try { Tg $token "getUpdates?offset=$($lastId + 1)" | Out-Null } catch {}
                $who = @($chat.username, $chat.first_name, $chat.title) | Where-Object { $_ } | Select-Object -First 1
                Ok "[OK] Got chat ID: $($chat.id) ($who)"
                return "$($chat.id)"
            }
        }
        $until = (Get-Date).AddSeconds(3)
        while ((Get-Date) -lt $until) {
            $key = $false
            try { $key = [Console]::KeyAvailable } catch {}
            if ($key) {
                $typed = (Read-Host 'Chat ID').Trim()
                if (Valid-ChatId $typed) { return $typed }
                Err "'$typed' is not a valid chat ID (a number like 987654321)."
            }
            Start-Sleep -Milliseconds 200
        }
    }
    throw 'No message received in 5 minutes. Run the installer again.'
}

$chatId = if ($env:CHAT_ID) { $env:CHAT_ID } elseif ($old) { "$($old.ChatId)" } else { '' }
if ($chatId -and -not (Valid-ChatId $chatId)) { Warn "Ignoring invalid CHAT_ID '$chatId' - detecting it automatically."; $chatId = '' }
if (-not $chatId) { $chatId = Find-ChatId }

# --- server name ---
if ($env:SERVER_NAME) { $serverName = $env:SERVER_NAME }
else {
    $def = if ($old -and $old.ServerName) { $old.ServerName } else { $env:COMPUTERNAME }
    Write-Host ''
    $n = Read-Host "Server name shown in alerts [$def]"
    $serverName = if ($n.Trim()) { $n.Trim() } else { $def }
}
Ok "[OK] Server name: $serverName"

# --- failed login mode ---
if ($env:FAIL_BATCH_SECONDS) { $failBatch = [int]$env:FAIL_BATCH_SECONDS }
else {
    Write-Host ''
    Write-Host 'Failed login alerts:'
    Write-Host '  Y = instant - a message for every failed login, right away (default)'
    Write-Host '  n = summary - one message every 5 minutes (quieter)'
    $a = Read-Host 'Send failed login alerts instantly? [Y/n]'
    $failBatch = if ($a -match '^[Nn]') { 300 } else { 0 }
}
Ok $(if ($failBatch -eq 0) { '[OK] Failed logins: instant' } else { '[OK] Failed logins: summary every 5 min' })

# --- test message (before saving anything) ---
function Send-Test {
    Write-Host 'Sending test message...'
    $text = "[$serverName]`n" + [char]::ConvertFromUtf32(0x1F514) + ' Telegram alerts installed on this Windows server. This is a test message.'
    $body = [Text.Encoding]::UTF8.GetBytes((@{ chat_id = $chatId; text = $text } | ConvertTo-Json -Compress))
    try {
        Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$token/sendMessage" -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 20 -UseBasicParsing | Out-Null
        return $null
    } catch {
        $desc = $null
        try { $desc = ($_.ErrorDetails.Message | ConvertFrom-Json).description } catch {}
        if (-not $desc) { $desc = $_.Exception.Message }
        return $desc
    }
}
while ($true) {
    $e = Send-Test
    if (-not $e) { break }
    Err "Could not send to chat ${chatId}: $e"
    Write-Host "Make sure you pressed START in the chat with @$botName."
    $chatId = Find-ChatId
}
Ok '[OK] Test message sent - check Telegram'

# --- files ---
New-Item -ItemType Directory -Path $Dir -Force | Out-Null
# only SYSTEM and Administrators can read the folder (it contains the bot token)
& icacls.exe $Dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null

$cfg = [ordered]@{
    BotToken            = $token
    ChatId              = "$chatId"
    ServerName          = $serverName
    FailBatchSeconds    = $failBatch
    FailInstantMax      = $(if ($old -and $old.FailInstantMax) { [int]$old.FailInstantMax } else { 20 })
    IgnoreLoginIps      = @($(if ($old -and $old.IgnoreLoginIps) { $old.IgnoreLoginIps }))
    NotifyNetworkLogons = $(if ($old -and $old.NotifyNetworkLogons) { $true } else { $false })
}
$cfg | ConvertTo-Json | Set-Content "$Dir\config.json" -Encoding UTF8
Set-Content "$Dir\agent.ps1"     $AgentCode     -Encoding UTF8
Set-Content "$Dir\uninstall.ps1" ("#Requires -RunAsAdministrator`n" + $UninstallCode) -Encoding UTF8

# don't send a "Server STARTED" message for the current boot
Set-Content "$Dir\last-boot.txt" (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')

# --- make sure Windows logs successful + failed logons (Audit "Logon") ---
& auditpol.exe /set /subcategory:'{0CCE9215-69AE-11D9-BED3-505054503030}' /success:enable /failure:enable | Out-Null

# --- scheduled task: at startup + every 5 min as a watchdog (ignored while running) ---
try { Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue } catch {}
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*TgAlert\agent.ps1*' } |
    ForEach-Object { Invoke-CimMethod -InputObject $_ -MethodName Terminate | Out-Null }

$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
           -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Dir\agent.ps1`""
$watch = $null
try   { $watch = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) }
catch { $watch = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration (New-TimeSpan -Days 3650) }
$triggers  = @((New-ScheduledTaskTrigger -AtStartup), $watch)
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
             -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings `
    -Description 'Telegram alerts: start/shutdown, logins, failed logins' -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host ''
Ok '=== Done! ==='
Write-Host @"
You will now get Telegram alerts for:
  - server start / shutdown / restart / crash
  - Remote Desktop, console and OpenSSH logins
  - failed logins

Settings : $Dir\config.json
           after editing run:  Stop-ScheduledTask TgAlert; Start-ScheduledTask TgAlert
Log      : $Dir\agent.log
Uninstall: powershell -ExecutionPolicy Bypass -File $Dir\uninstall.ps1
"@
}
