<#
.SYNOPSIS
    Git Synchronization Engine for ATLAS Knowledge Base.
.DESCRIPTION
    Safely stages ONLY specified knowledge files, commits them, and pushes to origin main.
    Guarantees strict isolation (no git add .), branch validation, remote divergence check,
    and anti-force push.
.PARAMETER TargetFiles
    One or more relative or absolute paths to knowledge markdown files within knowledge/.
.PARAMETER CommitMessage
    Commit message for the knowledge update.
.PARAMETER Remote
    Target remote name. Default is 'origin'.
.PARAMETER Branch
    Target branch name. Default is 'main'.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$TargetFiles,

    [Parameter(Mandatory = $true)]
    [string]$CommitMessage,

    [Parameter(Mandatory = $false)]
    [string]$Remote = "origin",

    [Parameter(Mandatory = $false)]
    [string]$Branch = "main"
)

# Use Continue so Git's informational stderr streams (e.g. fetch progress)
# do not trigger PowerShell terminating exceptions. We check $LASTEXITCODE explicitly.
$ErrorActionPreference = "Continue"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

# Helper for logging
$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$LogDir = Join-Path $RepoRoot "logs"
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
$LogFile = Join-Path $LogDir "git-sync.log"

function Write-SyncLog {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $LogLine = "[$Timestamp] [$Level] $Message"
    try {
        [System.IO.File]::AppendAllText($LogFile, "$LogLine`r`n", [System.Text.Encoding]::UTF8)
    } catch {
        # Fallback if momentarily locked
    }
    switch ($Level) {
        "ERROR"   { Write-Host $LogLine -ForegroundColor Red }
        "WARN"    { Write-Host $LogLine -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $LogLine -ForegroundColor Green }
        Default   { Write-Host $LogLine -ForegroundColor Cyan }
    }
}

Write-SyncLog "Starting Git Synchronization process..."

# Step 1: Ensure we are in RepoRoot
Push-Location $RepoRoot
try {
    # Step 2: Validate branch is $Branch (main)
    $CurrentBranch = (git rev-parse --abbrev-ref HEAD 2>&1).Trim()
    if ($LASTEXITCODE -ne 0 -or $CurrentBranch -ne $Branch) {
        Write-SyncLog "Git Sync aborted: Current branch '$CurrentBranch' is not '$Branch'." "ERROR"
        exit 4
    }
    Write-SyncLog "Current branch is confirmed as '$CurrentBranch'." "INFO"

    # Step 3: Normalize and validate target files
    $ResolvedTargets = @()
    foreach ($File in $TargetFiles) {
        if (-not (Test-Path $File)) {
            Write-SyncLog "Target file not found: $File" "ERROR"
            exit 1
        }
        $FullResolved = (Resolve-Path $File).Path
        # Ensure target file is inside knowledge/
        $KnowledgeDir = (Join-Path $RepoRoot "knowledge")
        if (-not $FullResolved.StartsWith($KnowledgeDir, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-SyncLog "Security Violation: Target file '$FullResolved' is outside '$KnowledgeDir'." "ERROR"
            exit 1
        }
        # Get relative path with forward slashes for git
        $RelPath = $FullResolved.Substring($RepoRoot.Length).TrimStart('\', '/').Replace('\', '/')
        $ResolvedTargets += $RelPath
    }

    Write-SyncLog "Validated $($ResolvedTargets.Count) target knowledge file(s) for synchronization." "INFO"

    # Step 4: Check remote connectivity and fetch
    Write-SyncLog "Fetching remote '$Remote/$Branch' to check synchronization status..." "INFO"
    $FetchOutput = git fetch $Remote $Branch 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-SyncLog "Failed to reach remote '$Remote'. Output: $FetchOutput" "ERROR"
        exit 7
    }

    # Step 5: Detect divergence / potential conflicts
    $RevList = (git rev-list --left-right "$Remote/$Branch...HEAD" 2>&1)
    if ($LASTEXITCODE -ne 0) {
        Write-SyncLog "Failed to check divergence between local and remote. Output: $RevList" "ERROR"
        exit 5
    }

    $BehindCount = 0
    $AheadCount = 0
    if ($RevList) {
        $Commits = $RevList -split "`r?`n" | Where-Object { $_ -match '\S' }
        $BehindCount = ($Commits | Where-Object { $_ -like "<*" }).Count
        $AheadCount = ($Commits | Where-Object { $_ -like ">*" }).Count
    }

    if ($BehindCount -gt 0) {
        Write-SyncLog "Local repository is behind remote by $BehindCount commit(s). Attempting safe fast-forward pull..." "WARN"
        $PullOutput = git pull --ff-only $Remote $Branch 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-SyncLog "Cannot cleanly fast-forward. Remote changes detected that may conflict. Aborting sync. Details: $PullOutput" "ERROR"
            exit 5
        }
        Write-SyncLog "Fast-forward pull succeeded." "SUCCESS"
    }

    # Step 6: STRICT STAGING - ONLY target files (NEVER git add . or git add -A)
    # Ensure index is clean of other files first
    $InitialStaged = git diff --cached --name-only
    if ($InitialStaged) {
        Write-SyncLog "Warning: Existing staged files detected. Unstaging all before isolated sync." "WARN"
        git reset 2>&1 | Out-Null
    }

    foreach ($TargetRel in $ResolvedTargets) {
        Write-SyncLog "Staging single target: $TargetRel" "INFO"
        git add -- "$TargetRel" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-SyncLog "Failed to stage file: $TargetRel" "ERROR"
            exit 6
        }
    }

    # Step 7: Verify staging isolation - MUST ONLY CONTAIN TARGET FILES
    $StagedFiles = @((git diff --cached --name-only) -split "`r?`n" | Where-Object { $_ -match '\S' })
    foreach ($Staged in $StagedFiles) {
        if ($ResolvedTargets -notcontains $Staged) {
            Write-SyncLog "Isolation Violation! Foreign file '$Staged' detected in staging area. Reverting staging." "ERROR"
            git reset 2>&1 | Out-Null
            exit 6
        }
    }

    if (-not $StagedFiles) {
        Write-SyncLog "No changes detected in target knowledge file(s). Nothing to commit." "INFO"
        exit 0
    }

    Write-SyncLog "Staging verified: only target knowledge file(s) are staged." "SUCCESS"

    # Step 8: Commit
    Write-SyncLog "Creating commit: $CommitMessage" "INFO"
    $CommitOutput = git commit -m "$CommitMessage" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-SyncLog "Commit failed: $CommitOutput" "ERROR"
        exit 6
    }
    $CommitHash = (git rev-parse --short HEAD).Trim()
    Write-SyncLog "Commit created successfully: $CommitHash" "SUCCESS"

    # Step 9: Push to origin main (Strictly NO force push)
    Write-SyncLog "Pushing to $Remote $Branch..." "INFO"
    $PushOutput = git push $Remote $Branch 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-SyncLog "Git push failed! Output: $PushOutput" "ERROR"
        exit 7
    }

    # Step 10: Verify remote synchronization
    $FinalRevList = (git rev-list --left-right "$Remote/$Branch...HEAD" 2>&1)
    if ($FinalRevList) {
        $RemainingAhead = ($FinalRevList -split "`r?`n" | Where-Object { $_ -like ">*" }).Count
        if ($RemainingAhead -gt 0) {
            Write-SyncLog "Push verification failed: local is still ahead by $RemainingAhead commit(s)." "ERROR"
            exit 7
        }
    }

    Write-SyncLog "Synchronization verified! Knowledge successfully published to $Remote/$Branch at commit $CommitHash." "SUCCESS"
    exit 0

} finally {
    Pop-Location
}
