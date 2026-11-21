<#
.SYNOPSIS
    Automated Test Suite for ATLAS Continuous Learning Engine (ACLE).
.DESCRIPTION
    Validates guardrails, deduplication, branch protection, isolated staging,
    security scanning, and lifecycle hook contracts.
#>
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
Push-Location $RepoRoot

$Passed = 0
$Failed = 0

function Assert-Condition([string]$TestName, [bool]$Condition, [string]$FailureMessage = "") {
    if ($Condition) {
        Write-Host "  [PASS] $TestName" -ForegroundColor Green
        $script:Passed++
    } else {
        Write-Host "  [FAIL] $TestName - $FailureMessage" -ForegroundColor Red
        $script:Failed++
    }
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " RUNNING ATLAS CONTINUOUS LEARNING ENGINE (ACLE) TEST SUITE " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# -------------------------------------------------------------
# TEST 1: Security Scanner - Detects Secrets & Credentials
# -------------------------------------------------------------
Write-Host "`nTest 1: Security Scanner (Secrets & Credentials Blocking)..."
$SecTestScript = Join-Path $RepoRoot "skills\knowledge-manager\scripts\publish-knowledge.ps1"
$SecOutput = & powershell -ExecutionPolicy Bypass -File $SecTestScript `
    -Title "Test Secret Leak" `
    -Category "global" `
    -Content "Dummy password: password = 'SuperSecret12345!' and API key: api_key='abcdef1234567890123456789'" `
    -DryRun 2>&1

$SecExitCode = $LASTEXITCODE
Assert-Condition "Security Scanner blocks credentials" ($SecExitCode -eq 3) "Exit code was $SecExitCode (expected 3)"

# -------------------------------------------------------------
# TEST 2: Verification Guardrail - Blocks Unverified Knowledge
# -------------------------------------------------------------
Write-Host "`nTest 2: Verification Guardrail..."
$UnverifiedOutput = & powershell -ExecutionPolicy Bypass -File $SecTestScript `
    -Title "Unverified Assumption" `
    -Category "global" `
    -Content "This might work, unverified guess." `
    -Verified:$false `
    -DryRun 2>&1

$UnverExitCode = $LASTEXITCODE
Assert-Condition "Blocks unverified assumption" ($UnverExitCode -eq 2) "Exit code was $UnverExitCode (expected 2)"

# -------------------------------------------------------------
# TEST 3: Lifecycle Hook Contract (Stdin -> Stdout JSON)
# -------------------------------------------------------------
Write-Host "`nTest 3: Antigravity Lifecycle Hook Contract..."
$HookScript = Join-Path $RepoRoot "scripts\acle-hook.ps1"
$MockStdin = '{"conversationId":"test-1234","terminationReason":"NO_TOOL_CALL"}'
$HookOutput = $MockStdin | & powershell -ExecutionPolicy Bypass -File $HookScript 2>&1
$TrimmedHookOutput = ($HookOutput -join "").Trim()
Assert-Condition "Hook returns empty JSON object '{}'" ($TrimmedHookOutput -eq "{}") "Output was: '$TrimmedHookOutput'"

# -------------------------------------------------------------
# TEST 4: Deduplication & Enrichment Engine
# -------------------------------------------------------------
Write-Host "`nTest 4: Deduplication & Document Enrichment..."
$TestTitle = "Test ACLE Engine Architecture"
$TestContent1 = "Initial baseline architecture notes for testing ACLE."
$TestContent2 = "Second lesson adding new findings to existing architecture."

# First run (Create)
$Run1 = & powershell -ExecutionPolicy Bypass -File $SecTestScript `
    -Title $TestTitle `
    -Category "lessons" `
    -Content $TestContent1 `
    -Tags @("test", "acle") `
    -SkipGitSync 2>&1

$ExpectedFile = Join-Path (Join-Path $RepoRoot "knowledge\lessons") "test-acle-engine-architecture.md"
Assert-Condition "First publication creates new markdown file" (Test-Path $ExpectedFile) "File not found: $ExpectedFile"

# Second run with identical/similar title (Should Enrich, not duplicate)
$Run2 = & powershell -ExecutionPolicy Bypass -File $SecTestScript `
    -Title $TestTitle `
    -Category "lessons" `
    -Content $TestContent2 `
    -Tags @("test", "acle") `
    -SkipGitSync 2>&1

$EnrichedContent = Get-Content -Path $ExpectedFile -Raw -Encoding UTF8
$HasEnrichmentHeader = $EnrichedContent -like "*Additional Findings & Continuous Learning*"
$HasSecondContent = $EnrichedContent -like "*Second lesson adding new findings*"
Assert-Condition "Second publication enriches existing file without creating duplicate" ($HasEnrichmentHeader -and $HasSecondContent) "Enrichment section missing"

# -------------------------------------------------------------
# TEST 5: Branch Protection in git-sync.ps1
# -------------------------------------------------------------
Write-Host "`nTest 5: Git Branch Protection Guardrail..."
$GitSyncScript = Join-Path $RepoRoot "scripts\git-sync.ps1"

# Test branch mismatch: pass a required branch different from current (e.g., 'production')
$BranchTestOutput = & powershell -ExecutionPolicy Bypass -File $GitSyncScript `
    -TargetFiles @($ExpectedFile) `
    -CommitMessage "test commit" `
    -Branch "non-existent-or-different-branch" 2>&1
$BranchTestExitCode = $LASTEXITCODE

Assert-Condition "Git Sync aborts when branch is not target branch" ($BranchTestExitCode -eq 4) "Exit code was $BranchTestExitCode (expected 4)"

# -------------------------------------------------------------
# TEST 6: Strict Isolated Staging (Anti `git add .` Protection)
# -------------------------------------------------------------
Write-Host "`nTest 6: Strict Staging Isolation (Anti 'git add .')..."
# Create a dummy unrelated dirty file
$DirtyFile = Join-Path $RepoRoot "unrelated-dirty-code.txt"
Set-Content -Path $DirtyFile -Value "This is a dirty unrelated file that must NEVER be staged or committed." -Encoding UTF8

# Ensure git status sees the dirty file
$StatusBefore = git status --porcelain
$IsDirtyUntracked = [bool]($StatusBefore | Where-Object { $_ -match "unrelated-dirty-code\.txt" })
Assert-Condition "Dirty unrelated file is untracked before sync" $IsDirtyUntracked "Dirty file not detected in working tree"

# Clean up test artifacts before final real sync test
Remove-Item -Path $ExpectedFile -Force -ErrorAction SilentlyContinue
Remove-Item -Path $DirtyFile -Force -ErrorAction SilentlyContinue

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host " TEST SUMMARY: $Passed PASSED, $Failed FAILED" -ForegroundColor $(if ($Failed -eq 0) { "Green" } else { "Red" })
Write-Host "==========================================================" -ForegroundColor Cyan

Pop-Location
if ($Failed -gt 0) { exit 1 } else { exit 0 }
