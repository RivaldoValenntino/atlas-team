<#
.SYNOPSIS
    ATLAS Continuous Learning Engine (ACLE) - Knowledge Publisher.
.DESCRIPTION
    Extracts, validates, classifies, deduplicates, formats, and publishes knowledge markdown.
    Automatically triggers Git synchronization without requiring secondary manual approval.
.PARAMETER Title
    Clear, descriptive title of the knowledge / engineering lesson.
.PARAMETER Category
    Classification: 'global', 'project', or 'lessons'.
.PARAMETER Content
    The body of the knowledge in Markdown format.
.PARAMETER Tags
    Array or comma-separated string of relevant tags.
.PARAMETER ProjectName
    Name of the project (required if Category is 'project').
.PARAMETER Verified
    Switch indicating that the solution/finding is verified (defaults to true).
.PARAMETER DryRun
    Simulate processing without creating files or running git sync.
.PARAMETER SkipGitSync
    Create/update the file but skip Git synchronization (useful for isolated tests).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Title,

    [Parameter(Mandatory = $true)]
    [ValidateSet("global", "project", "lessons")]
    [string]$Category,

    [Parameter(Mandatory = $true)]
    [string]$Content,

    [Parameter(Mandatory = $false)]
    [object]$Tags = @(),

    [Parameter(Mandatory = $false)]
    [string]$ProjectName = "",

    [Parameter(Mandatory = $false)]
    [object]$Verified = $true,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [switch]$SkipGitSync
)

$ErrorActionPreference = "Continue"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

# Parse Verified safely across all PowerShell caller styles
$IsVerified = $true
if ($PSBoundParameters.ContainsKey('Verified')) {
    if ($Verified -is [bool]) { 
        $IsVerified = $Verified 
    } elseif ($Verified -is [System.Management.Automation.SwitchParameter]) { 
        $IsVerified = $Verified.IsPresent 
    } elseif ($Verified -is [string]) {
        if ($Verified -match '^(false|0|no|unverified)$') { 
            $IsVerified = $false 
        } else {
            $IsVerified = $true
        }
    }
}

$RepoRoot = (Resolve-Path "$PSScriptRoot\..\..\..").Path
$KnowledgeRoot = Join-Path $RepoRoot "knowledge"
$LogDir = Join-Path $RepoRoot "logs"
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}
$LogFile = Join-Path $LogDir "acle.log"

function Write-AcleLog {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $LogLine = "[$Timestamp] [$Level] $Message"
    try {
        [System.IO.File]::AppendAllText($LogFile, "$LogLine`r`n", [System.Text.Encoding]::UTF8)
    } catch {
        # Fallback if file is momentarily locked
    }
    switch ($Level) {
        "ERROR"   { Write-Host $LogLine -ForegroundColor Red }
        "WARN"    { Write-Host $LogLine -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $LogLine -ForegroundColor Green }
        Default   { Write-Host $LogLine -ForegroundColor Cyan }
    }
}

Write-AcleLog "Executing ACLE Knowledge Processing: '$Title' (Category: $Category)"

# -------------------------------------------------------------
# GUARDRAIL 1: Verification & Assumption Check
# -------------------------------------------------------------
if (-not $IsVerified) {
    Write-AcleLog "ACLE Rejection: Only verified engineering knowledge can be published. Unverified assumptions are prohibited." "ERROR"
    exit 2
}

# -------------------------------------------------------------
# GUARDRAIL 2: Security & Secret Detection
# -------------------------------------------------------------
$SecretPatterns = @(
    "(?i)(api[_-]?key|access[_-]?token|secret[_-]?key)\s*[:=]\s*['""][a-zA-Z0-9_\-\.]{16,}['""]",
    "(?i)(password|passwd|pwd)\s*[:=]\s*['""][^'""]{6,}['""]",
    "-----BEGIN (?:RSA|OPENSSH|EC|DSA|PGP) PRIVATE KEY-----",
    "(?i)bearer\s+[a-zA-Z0-9_\-\.]{25,}",
    "(?i)(mysql|postgres|mongodb|redis):\/\/[a-zA-Z0-9_]+:[^@\s]+@"
)

$CombinedText = "$Title `n $Content"
foreach ($Pattern in $SecretPatterns) {
    if ($CombinedText -match $Pattern) {
        Write-AcleLog "ACLE Security Violation: Potential credential or sensitive secret detected in knowledge content. Aborting publication." "ERROR"
        exit 3
    }
}

# -------------------------------------------------------------
# GUARDRAIL 3: Classification Integrity
# -------------------------------------------------------------
if ($Category -eq "project" -and [string]::IsNullOrWhiteSpace($ProjectName)) {
    Write-AcleLog "ACLE Validation Error: ProjectName is required for 'project' category." "ERROR"
    exit 1
}

if ($Category -eq "global" -and -not [string]::IsNullOrWhiteSpace($ProjectName)) {
    Write-AcleLog "ACLE Warning: Project name provided for global category. Stripping project scope to maintain universal generality." "WARN"
    $ProjectName = ""
}

# Normalize Tags
$TagList = @()
if ($Tags -is [array]) {
    $TagList = $Tags | ForEach-Object { "$_".Trim() } | Where-Object { $_ -ne "" }
} elseif ($Tags -is [string] -and $Tags.Trim() -ne "") {
    $TagList = $Tags -split "[,;]" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
}

# Helper to generate URL-safe slug
function Get-Slug {
    param([string]$Text)
    $Slug = $Text.ToLower().Trim()
    $Slug = [System.Text.RegularExpressions.Regex]::Replace($Slug, "[^a-z0-9\s-]", "")
    $Slug = [System.Text.RegularExpressions.Regex]::Replace($Slug, "\s+", "-")
    $Slug = [System.Text.RegularExpressions.Regex]::Replace($Slug, "-+", "-")
    return $Slug.Trim('-')
}

$Slug = Get-Slug $Title
if ([string]::IsNullOrWhiteSpace($Slug)) {
    $Slug = "knowledge-" + (Get-Date).ToString("yyyyMMdd-HHmmss")
}

# -------------------------------------------------------------
# DEDUPLICATION ENGINE
# -------------------------------------------------------------
Write-AcleLog "Scanning existing knowledge base for potential duplicates or related articles..."

$TargetDir = if ($Category -eq "project") {
    Join-Path (Join-Path $KnowledgeRoot "project") $ProjectName
} else {
    Join-Path $KnowledgeRoot $Category
}

if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
}

$ExistingFiles = Get-ChildItem -Path $KnowledgeRoot -Filter "*.md" -Recurse -File
$MatchedFile = $null
$MaxSimilarity = 0.0

function Get-TokenSet([string]$Text) {
    $Tokens = [System.Text.RegularExpressions.Regex]::Matches($Text.ToLower(), "[a-z0-9]+") | ForEach-Object { $_.Value }
    return [System.Collections.Generic.HashSet[string]]::new([string[]]$Tokens)
}

$CurrentTitleTokens = Get-TokenSet $Title

foreach ($ExFile in $ExistingFiles) {
    $BaseSlug = [System.IO.Path]::GetFileNameWithoutExtension($ExFile.Name)
    if ($BaseSlug -eq $Slug) {
        $MatchedFile = $ExFile
        $MaxSimilarity = 1.0
        break
    }

    # Read frontmatter title or first header
    $FileContent = Get-Content -Path $ExFile.FullName -Raw -Encoding UTF8
    $ExTitle = ""
    if ($FileContent -match '(?m)^title:\s*["'']?(.*?)["'']?$') {
        $ExTitle = $Matches[1].Trim()
    } elseif ($FileContent -match '(?m)^#\s+(.+)$') {
        $ExTitle = $Matches[1].Trim()
    }

    if ($ExTitle) {
        $ExTokens = Get-TokenSet $ExTitle
        $Intersection = 0
        foreach ($t in $CurrentTitleTokens) {
            if ($ExTokens.Contains($t)) { $Intersection++ }
        }
        $Union = $CurrentTitleTokens.Count + $ExTokens.Count - $Intersection
        if ($Union -gt 0) {
            $Sim = [double]$Intersection / [double]$Union
            if ($Sim -gt $MaxSimilarity) {
                $MaxSimilarity = $Sim
                if ($Sim -ge 0.70) {
                    $MatchedFile = $ExFile
                }
            }
        }
    }
}

$TimestampNow = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
$TargetFilePath = ""
$IsEnrichment = $false

if ($MatchedFile -ne $null -and $MaxSimilarity -ge 0.70) {
    # -------------------------------------------------------------
    # UPDATE / ENRICHMENT MODE
    # -------------------------------------------------------------
    $TargetFilePath = $MatchedFile.FullName
    $IsEnrichment = $true
    Write-AcleLog "Duplicate/Related knowledge found: '$($MatchedFile.Name)' (Similarity: $([math]::Round($MaxSimilarity * 100, 1))%). Switching to Enrichment Mode." "WARN"

    if (-not $DryRun) {
        $ExistingBody = Get-Content -Path $TargetFilePath -Raw -Encoding UTF8
        # Update updated_at in frontmatter if present
        if ($ExistingBody -match '(?m)^updated_at:.*$') {
            $ExistingBody = [System.Text.RegularExpressions.Regex]::Replace($ExistingBody, '(?m)^updated_at:.*$', "updated_at: $TimestampNow")
        }

        $EnrichmentSection = @"


---

## Additional Findings & Continuous Learning [$((Get-Date).ToString("yyyy-MM-dd HH:mm"))]
**Author**: ATLAS Continuous Learning Engine
**Verified**: Yes

$Content
"@
        $FinalContent = $ExistingBody.TrimEnd() + $EnrichmentSection
        Set-Content -Path $TargetFilePath -Value $FinalContent -Encoding UTF8 -NoNewline
        Write-AcleLog "Knowledge document enriched: $TargetFilePath" "SUCCESS"
    }
} else {
    # -------------------------------------------------------------
    # CREATE NEW KNOWLEDGE FILE
    # -------------------------------------------------------------
    $TargetFilePath = Join-Path $TargetDir "$Slug.md"
    Write-AcleLog "Creating new knowledge document: $TargetFilePath" "INFO"

    $TagsYaml = if ($TagList.Count -gt 0) {
        "[" + (($TagList | ForEach-Object { "`"$_`"" }) -join ", ") + "]"
    } else {
        "[]"
    }

    $Scope = if ($Category -eq "project") { $ProjectName } else { "universal" }

    $NewDocument = @"
---
id: $Slug
title: "$Title"
category: $Category
tags: $TagsYaml
created_at: $TimestampNow
updated_at: $TimestampNow
author: ATLAS Continuous Learning Engine
verified: true
scope: $Scope
---

# $Title

$Content
"@

    if (-not $DryRun) {
        Set-Content -Path $TargetFilePath -Value $NewDocument -Encoding UTF8 -NoNewline
        Write-AcleLog "Knowledge document created: $TargetFilePath" "SUCCESS"
    }
}

if ($DryRun) {
    Write-AcleLog "[DryRun] Simulation completed. File target: $TargetFilePath. Git sync skipped." "INFO"
    exit 0
}

# -------------------------------------------------------------
# AUTOMATIC PRE-AUTHORIZED GIT SYNCHRONIZATION
# -------------------------------------------------------------
if ($SkipGitSync) {
    Write-AcleLog "SkipGitSync flag is active. Git synchronization skipped." "INFO"
    exit 0
}

Write-AcleLog "Initiating automatic pre-authorized Git synchronization..." "INFO"
$GitSyncScript = Join-Path $RepoRoot "scripts\git-sync.ps1"
if (-not (Test-Path $GitSyncScript)) {
    Write-AcleLog "Git sync script not found at $GitSyncScript" "ERROR"
    exit 1
}

$ActionVerb = if ($IsEnrichment) { "update" } else { "add" }
$CommitMsg = "docs(knowledge): $ActionVerb $Category knowledge '$Title'"

$SyncProcess = & $GitSyncScript -TargetFiles @($TargetFilePath) -CommitMessage $CommitMsg
$SyncExitCode = $LASTEXITCODE

if ($SyncExitCode -ne 0) {
    Write-AcleLog "Automatic Git synchronization failed with exit code $SyncExitCode." "ERROR"
    exit $SyncExitCode
}

Write-AcleLog "ACLE process complete! Knowledge published and synchronized to GitHub." "SUCCESS"
exit 0
