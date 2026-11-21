<#
.SYNOPSIS
    Antigravity Lifecycle Hook Handler for ATLAS Continuous Learning Engine (ACLE).
.DESCRIPTION
    Runs on execution termination (Stop hook). Logs lifecycle execution and ensures
    compliant JSON stdout is emitted to satisfy the Antigravity hook contract.
#>
$ErrorActionPreference = "SilentlyContinue"

$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$LogDir = Join-Path $RepoRoot "logs"
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
$LogFile = Join-Path $LogDir "acle-lifecycle.log"

# Read stdin JSON payload from Antigravity runtime if available
$RawInput = ""
try {
    if ([Console]::IsInputRedirected) {
        $RawInput = [Console]::In.ReadToEnd()
    }
} catch {
    # Non-blocking if stdin is empty or not redirected
}

$Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$LogPayload = "[$Timestamp] [HOOK:Stop] ACLE Lifecycle Hook Triggered."
if ($RawInput) {
    try {
        $JsonObj = $RawInput | ConvertFrom-Json
        $LogPayload += " ConversationId: $($JsonObj.conversationId) | Reason: $($JsonObj.terminationReason)"
    } catch {
        $LogPayload += " Raw Payload Length: $($RawInput.Length) bytes"
    }
}

try {
    [System.IO.File]::AppendAllText($LogFile, "$LogPayload`r`n", [System.Text.Encoding]::UTF8)
} catch {
    # Non-blocking fallback
}

# Antigravity Stop Hook Contract requires a JSON object on stdout (e.g., {})
# to allow normal termination without blocking.
[Console]::Out.WriteLine("{}")
exit 0
