<#
.SYNOPSIS
    path:line citation grounding: does a cited path exist in the bundle, and is
    the cited line within that file's length?

.DESCRIPTION
    The probe behind the second half of
    docs/assessments/2026-08-14-quote-grounding-declined.md. Proposed in round 6,
    re-proposed by deepseek-flash after quote grounding was refuted, with the
    same falsifiable prediction: healthy rounds ground >= 80% of citations.

    Measured over 32 reviewer-rounds with >= 5 citations:

        FILE-OK  mean 99.5%   min 83.3%      <- saturated, no discrimination
        LINE-OK  mean 85.1%   min 0%         <- confounded, see below

    Declined. The line half does NOT measure fabrication; it measures
    bundle/tree divergence and citation-convention drift:

      1. Agentic reviewers (opencode/agy) have filesystem access and cite the
         file on disk, not the subset in the bundle.
      2. A -Diff bundle holds a subset -- a citation past its length can be
         perfectly correct about the repo.
      3. Reviewers do not share a convention. Some cite per-file lines, some
         cite BUNDLE-relative ones ('round-1-bundle.xml#L1983-L2052').

    COMMITTED so the numbers can be re-run rather than re-argued. Test any
    future proposal in this family against those three confounds first.

.EXAMPLE
    pwsh tools/probes/citation-grounding.ps1
#>
[CmdletBinding()]
param([string]$ReviewsRoot)

$ErrorActionPreference = 'Stop'
if (-not $ReviewsRoot) {
    $skillRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $ReviewsRoot = Join-Path $skillRoot '.external-reviews'
}
if (-not (Test-Path -LiteralPath $ReviewsRoot)) {
    Write-Host "[probe] No reviews at $ReviewsRoot -- nothing to measure."
    return
}

function Get-BundleFileLines([string]$BundlePath) {
    $raw = Get-Content -Raw -LiteralPath $BundlePath
    $map = @{}
    foreach ($m in [regex]::Matches($raw, '(?s)<file\s+path="([^"]+)"[^>]*>(.*?)</file>')) {
        $p = ($m.Groups[1].Value -replace '\\', '/').TrimStart('./')
        $map[$p] = ([regex]::Matches($m.Groups[2].Value, "`n")).Count + 1
    }
    return $map
}

$rows = @()
foreach ($topicDir in @(Get-ChildItem -LiteralPath $ReviewsRoot -Directory -ErrorAction SilentlyContinue)) {
    foreach ($resp in @(Get-ChildItem -LiteralPath $topicDir.FullName -Filter 'round-*response.md' -File -ErrorAction SilentlyContinue)) {
        if ($resp.Name -notmatch '^round-(\d+)-(.+)response\.md$') { continue }   # per-preset only
        $n = $matches[1]; $who = $matches[2].TrimEnd('-')
        $bundle = Join-Path $topicDir.FullName "round-$n-bundle.xml"
        if (-not (Test-Path -LiteralPath $bundle)) { continue }

        $files = Get-BundleFileLines $bundle
        if ($files.Count -eq 0) { continue }
        $text = Get-Content -Raw -LiteralPath $resp.FullName

        # Require a known source extension, so prose like "10:30" cannot enter
        # the denominator.
        $cites = [regex]::Matches($text,
            '(?<![\w/\\.-])([A-Za-z0-9_][A-Za-z0-9_./\\-]*\.(?:ps1|psm1|ts|tsx|js|py|md|json|xml|yml|yaml)):(\d+)')
        if ($cites.Count -eq 0) { continue }

        $tot = 0; $fileOk = 0; $lineOk = 0
        foreach ($c in $cites) {
            $tot++
            $p  = ($c.Groups[1].Value -replace '\\', '/').TrimStart('./')
            $ln = [int]$c.Groups[2].Value
            # Suffix match: reviewers cite 'era.ps1' for 'runtimes/era.ps1'.
            $hit = $null
            foreach ($k in $files.Keys) {
                if ($k -ieq $p -or $k.EndsWith('/' + $p, [System.StringComparison]::OrdinalIgnoreCase)) { $hit = $k; break }
            }
            if ($hit) { $fileOk++; if ($ln -le $files[$hit]) { $lineOk++ } }
        }
        $rows += [pscustomobject]@{
            Topic = $topicDir.Name; Round = [int]$n; Who = $who
            Cites = $tot; FilePct = [math]::Round(100*$fileOk/$tot,1); LinePct = [math]::Round(100*$lineOk/$tot,1)
        }
    }
}

'{0,-30} {1,-5} {2,-16} {3,-6} {4,-9} {5}' -f 'TOPIC','RND','REVIEWER','CITES','FILE-OK','LINE-OK'
'-' * 82
foreach ($r in ($rows | Sort-Object Topic, Round, Who)) {
    '{0,-30} {1,-5} {2,-16} {3,-6} {4,-9} {5}' -f $r.Topic, $r.Round, $r.Who, $r.Cites, "$($r.FilePct)%", "$($r.LinePct)%"
}

$scored = @($rows | Where-Object { $_.Cites -ge 5 })
if ($scored.Count -eq 0) { return }
$fp = @($scored | ForEach-Object { $_.FilePct })
$lp = @($scored | ForEach-Object { $_.LinePct })
''
'=== distribution (n rounds with >= 5 citations) ==='
'n        : {0}' -f $scored.Count
'FILE-OK  : mean {0}%  min {1}%  max {2}%' -f [math]::Round(($fp|Measure-Object -Average).Average,1), ($fp|Measure-Object -Minimum).Minimum, ($fp|Measure-Object -Maximum).Maximum
'LINE-OK  : mean {0}%  min {1}%  max {2}%' -f [math]::Round(($lp|Measure-Object -Average).Average,1), ($lp|Measure-Object -Minimum).Minimum, ($lp|Measure-Object -Maximum).Maximum
''
'FILE-OK saturates: no round fell below the 80% the prediction nominated.'
'LINE-OK is confounded by agentic filesystem access, -Diff subsets, and'
'citation convention -- an exact 0% is an artefact, not a fabrication signal.'
