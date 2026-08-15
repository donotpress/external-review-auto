#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Dispatch the next grading round of this skill against itself.

.DESCRIPTION
    Rounds 1-5 were assembled by hand, and the round-5 prompt lived in a temp
    directory that did not survive. This makes the next round one command, and
    keeps the rounds COMPARABLE -- same axes, same contract, same output format,
    so the grade means the same thing each time.

    Continuity is derived, not typed:

      * the round number comes from era's own atomic reservation
      * {{PREVIOUS_ROUND}} carries every reviewer's last-round response
        (Get-EraPreviousRoundText -- all of them, not just the promoted one)
      * "what changed" is read from the LAST ROUND'S MANIFEST, which stamps the
        commit that round actually reviewed (git_head). No bookkeeping to keep
        in sync and nothing to remember.

.PARAMETER DryRun
    Assemble the prompt, print it and the exact dispatch command, and stop.
    Costs nothing. Use it first.

.PARAMETER Topic
    Review topic. Default 'era-grade' -- the continuous series.

.PARAMETER Reviewer
    Passed through to era.ps1. Omit for the default three-model panel.
    Measured cost of that panel: ~$0.88/round, opus ~93% of it. For a cheap
    check, 'gemini,deepseek-flash' costs cents and still finds structural bugs.

.EXAMPLE
    pwsh tools/grade-round.ps1 -DryRun
    pwsh tools/grade-round.ps1
    pwsh tools/grade-round.ps1 -Reviewer gemini,deepseek-flash
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$Topic = 'era-grade',
    # [string[]], matching era.ps1. As [string] the .EXAMPLE above bound only
    # when launched as `pwsh tools/grade-round.ps1 ...`; dot-invoked from inside
    # a session the comma makes an ARRAY and it threw a transformation error.
    # era.ps1 takes [string[]] and splits on ',' itself, so both styles work.
    [string[]]$Reviewer,
    [string[]]$IncludeFiles
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $skillRoot

# The bundle. Code first: the questions are about correctness, not prose, and a
# bigger bundle costs money and raises the odds a reviewer truncates.
if (-not $IncludeFiles) {
    $IncludeFiles = @(
        'workflow.ps1'
        'runtimes/era.ps1'
        'backends/agy.ps1'
        'backends/claude.ps1'
        'backends/opencode.ps1'
        'backends/geminiapi.ps1'
        'backends/openaicompat.ps1'
        'backends/anthropic.ps1'
        'backends/_capture-validation.ps1'
        'tests/DispatchThreadJob.Tests.ps1'
        'tests/VoidRound.Tests.ps1'
        'tests/EchoCalibration.Tests.ps1'
        'tests/RecoveryFallback.Tests.ps1'
        'tests/IgnoreParity.Tests.ps1'
        'tests/IgnorePatternDepth.Tests.ps1'
        # The harness that produces the round. Round 7 was asked to grade a fix
        # TO this file and answered "cannot verify -- not in the bundle".
        'tools/grade-round.ps1'
        # The design record. Every measured DECLINE lives here, and a reviewer
        # that cannot see it re-argues what this repo already settled -- opus
        # spent part of two rounds re-listing items closed by measurement.
        'docs/assessments/*.md'
    )
}

# --- What was graded last time? ------------------------------------------
# The manifest stamps the commit the round actually saw, so the delta needs no
# separate bookkeeping. git_clean=false means that round covered no single
# commit; say so rather than implying a clean range.
$reviewDir = Join-Path $skillRoot ".external-reviews/$Topic"
$lastManifest = Get-ChildItem -LiteralPath $reviewDir -Filter 'round-*-manifest.json' -ErrorAction SilentlyContinue |
    Sort-Object { [int]([regex]::Match($_.Name, '\d+').Value) } | Select-Object -Last 1

$changes = ''
if ($lastManifest) {
    $m = Get-Content -Raw -LiteralPath $lastManifest.FullName | ConvertFrom-Json
    $lastRound = $m.round
    $lastHead  = $m.git_head
    if ($lastHead) {
        $log  = @(& git log --oneline "$lastHead..HEAD" 2>$null)
        $stat = (& git diff --shortstat "$lastHead..HEAD" 2>$null) -join ''
        if ($log.Count -eq 0) {
            $changes = "## Nothing has changed since round $lastRound`n`n" +
                       "HEAD is still ``$lastHead``. Grade the same tree again only if you " +
                       "believe the previous round missed something; otherwise say so and stop."
        } else {
            $fence = '```'   # not inline: ` is PowerShell's escape character
            $dirtyNote = if ($m.git_clean -eq $false) {
                "`n`n(Round $lastRound ran over a DIRTY tree, so its baseline covers no single commit; " +
                "the range above is approximate at its lower end.)"
            } else { '' }
            $changes = "## What changed since round $lastRound (``$($lastHead.Substring(0,7))..HEAD``)`n`n" +
                       "$stat`n`n$fence`n" + ($log -join "`n") + "`n$fence`n" + $dirtyNote +
                       "`n`nVerify this list against the code. Commit messages in this repo state " +
                       "measured numbers; treat them as claims to check, not as evidence."
        }
    }
}
if (-not $changes) {
    $changes = "## First graded round for this topic`n`nNo prior manifest found; grade the tree as it stands."
}

# --- git log is UNTRUSTED TEXT -------------------------------------------
# A commit subject that NAMES a template token must not BE one. era runs
# Invoke-PromptTokenSubstitution over the finished prompt, and its regex skips
# backticked mentions but has no fence awareness -- workflow.ps1 says so
# outright, and concludes "the inline-span form is the one that occurs in
# practice." Round 8 falsified that with this repo's own tooling.
#
# 9d78231's subject is "fix: two regexes answered one question about
# {{PREVIOUS_ROUND}}, and disagreed" -- the commit that fixed the token's
# double-definition, so of course it names the token. Spliced raw into the
# prompt, it expanded INSIDE the ``` fence. Measured on round-8-prompt.md:
# 4 '### Reviewer:' headers where 2 is healthy. The commit list the reviewer is
# told to "verify against the code" was split in half with ~32 KB of the round-7
# panel wedged into it, 8421bda was orphaned after a stray ", and disagreed",
# and every reviewer was billed for a duplicate copy of the whole panel.
#
# This is the symmetric half of the era-require rule (era.ps1: read the control
# plane BEFORE splicing untrusted text): NEUTRALIZE control tokens IN untrusted
# text before splicing it. Done at the injection site, which is where the
# untrusted text enters and the only place that covers every downstream reader.
# The spacing keeps the subject readable while making it un-substitutable.
$changes = $changes -replace '\{\{([A-Z_]+)\}\}', '{{ $1 }}'

# --- Anything under review must be IN the bundle --------------------------
# Round 7 closed with "What I could not verify from this bundle", and two of the
# FOUR commits it was asked to grade were on that list -- c8f4c56 (a fix to this
# very file) and 4419f97 (an assessment doc). Asking a reviewer "what changed
# since round N" and then handing it a bundle missing half of that range can
# only produce "I cannot tell", and that lands in the grade as if it were a
# quality problem.
#
# The curated list above is stable CONTEXT. This union is COVERAGE: whatever the
# range actually touched, derived from the same $lastHead the prose reports, so
# the two cannot disagree. An explicit -IncludeFiles is left exactly as passed.
$MaxDerived = 40
if ($lastHead -and -not $PSBoundParameters.ContainsKey('IncludeFiles')) {
    $touched = @(& git diff --name-only "$lastHead..HEAD" 2>$null |
        Where-Object { $_ -and (Test-Path -LiteralPath (Join-Path $skillRoot $_)) })
    $derived = @($touched | Where-Object { $_ -notin $IncludeFiles })
    if ($derived.Count -gt $MaxDerived) {
        # NO SILENT CAPS. A bundle that quietly truncates its own scope reads as
        # "covered everything" when it did not -- which is the failure this
        # block exists to fix, so it must not reintroduce it by another door.
        $dropped = @($derived | Select-Object -Skip $MaxDerived)
        Write-Host "[grade] WARNING: $($derived.Count) files changed since round $lastRound, over the $MaxDerived-file derived cap."
        Write-Host "[grade] NOT bundled (name them in -IncludeFiles if they matter): $($dropped -join ', ')"
        $derived = @($derived | Select-Object -First $MaxDerived)
    }
    if ($derived.Count -gt 0) {
        $IncludeFiles = @($IncludeFiles) + $derived
        Write-Host "[grade] +$($derived.Count) file(s) touched since round ${lastRound}: $($derived -join ', ')"
    }
}

# --- Assemble ------------------------------------------------------------
$template = Get-Content -Raw -LiteralPath (Join-Path $skillRoot 'docs/grading-prompt.md')
# .Replace, not -replace: the changes block contains $ and \ from paths and code.
$prompt = $template.Replace('{{CHANGES_SINCE}}', $changes)

$promptPath = Join-Path ([System.IO.Path]::GetTempPath()) "era-grade-prompt-$(Get-Date -Format 'yyyyMMdd-HHmmss').md"
Set-Content -LiteralPath $promptPath -Value $prompt -Encoding utf8

# HASHTABLE splat, not an array. Array splatting is POSITIONAL: the strings go
# in by position and '-TopicSlug' is passed as a VALUE, so $TopicSlug got the
# literal "-TopicSlug" and 'era-grade' landed on $Mode (positional 1), failing
# its ValidateSet. Hashtable splatting binds by NAME.
# IncludeFiles stays an ARRAY -- this is an in-process `&` call, where array
# parameters bind correctly (the comma-joined string form is only for `pwsh -File`).
$eraPath = Join-Path $skillRoot 'runtimes/era.ps1'
$eraSplat = @{
    TopicSlug          = $Topic
    PromptOverrideFile = $promptPath
    IncludeFiles       = $IncludeFiles
    AllowDirtyTree     = $true   # this repo carries untracked META-REVIEW notes by design
    Force              = $true
}
if ($Reviewer) { $eraSplat.Reviewer = $Reviewer }

# Validate the binding BEFORE dispatching, and inside -DryRun. The original bug
# survived a dry run precisely because -DryRun returned before the call; a dry
# run that does not exercise the dispatch shape is not a dry run of the dispatch.
$known   = (Get-Command $eraPath).Parameters.Keys
$unknown = @($eraSplat.Keys | Where-Object { $_ -notin $known })
if ($unknown.Count -gt 0) {
    throw "grade-round: era.ps1 declares no parameter(s): $($unknown -join ', ')"
}

Write-Host "[grade] Prompt : $promptPath"
Write-Host "[grade] Bundle : $($IncludeFiles.Count) files"
Write-Host "[grade] Params : $(($eraSplat.Keys | Sort-Object) -join ', ')  [all bind to era.ps1]"

if ($DryRun) {
    Write-Host ''
    Write-Host '--- assembled prompt -------------------------------------------------'
    Write-Host $prompt
    Write-Host '--- end (dry run: nothing dispatched, nothing spent) -----------------'
    return
}

& $eraPath @eraSplat
$code = $LASTEXITCODE
Write-Host "[grade] era exit code: $code"
switch ($code) {
    0 { Write-Host "[grade] Responses in $reviewDir. Adjudicate before believing: turn each finding into a failing test or a probe." }
    2 { Write-Host "[grade] EXIT 2 = the round produced NO usable review. Money was spent; artifacts are kept. Do not silently re-dispatch." }
    default { Write-Host "[grade] Non-zero exit; read the error above verbatim." }
}
exit $code
