# Sidecar: publishes Herdr's agent detection to a file the WezTerm
# agent-deck plugin can read. WezTerm's Lua sandbox blocks shell-out, so
# the plugin reads this file instead (detect_via_herdr file fallback).
# Run once in the background:
#   pwsh -NoLogo -File C:\Users\mohit\git-repos\wezterm-agent-deck\herdr-agent-bridge.ps1
$HERDR = "C:\Users\mohit\AppData\Local\Programs\Herdr\bin\herdr.exe"
$tmp = $env:TEMP
while ($true) {
    try {
        & $HERDR agent list 2>$null | Out-File -FilePath "$tmp\herdr-agents.json" -Encoding utf8
    } catch {}
    Start-Sleep -Seconds 2
}
