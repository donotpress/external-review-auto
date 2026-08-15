<#
.SYNOPSIS
    Verbatim-quote grounding: how much of what a reviewer QUOTED actually
    appears in the bundle it was given?

.DESCRIPTION
    The probe behind docs/assessments/2026-08-14-quote-grounding-declined.md.
    Round-7 (opus) proposed this as a gate for the fluent-but-wrong review, with
    a falsifiable prediction: healthy rounds land above 80% grounded. Measured
    5% mean over 38 reviewer-rounds. Refuted; no gate was built.

    COMMITTED, not thrown away. The assessment says "re-measure before
    revisiting", and 2026-08-10-prompt-echo-threshold.md records what happens
    when it is not committed: "nobody could re-run the calibration because the
    script was thrown away and the corpus was not in the repo." Round-8 (opus)
    finding 5 caught this repo about to repeat that on the same day.

    -Split reports the fenced/inline breakdown that DIAGNOSED the refutation:
    the denominator is dominated by code the reviewer AUTHORED (proposed fixes
    and the executable checks this repo asks for), not code it quoted.

.PARAMETER ReviewsRoot
    Defaults to the skill's own .external-reviews/ (gitignored, local-only).

.EXAMPLE
    pwsh tools/probes/quote-grounding.ps1
    pwsh tools/probes/quote-grounding.ps1 -Split
#>
[CmdletBinding()]
param(
    [string]$ReviewsRoot,
    [switch]$Split
)

$ErrorActionPreference = 'Stop'
if (-not $ReviewsRoot) {
    $skillRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $ReviewsRoot = Join-Path $skillRoot '.external-reviews'
}
if (-not (Test-Path -LiteralPath $ReviewsRoot)) {
    Write-Host "[probe] No reviews at $ReviewsRoot -- nothing to measure."
    return
}

function Normalize([string]$Text) {
    # showLineNumbers = $true injects 'NNN: ' prefixes. Strip them BEFORE
    # collapsing whitespace, or the metric silently reads near-zero.
    $t = $Text -replace '(?m)^\s*\d+:\s?', ''
    return (($t -replace '\s+', ' ')).ToLowerInvariant()
}
function Clean([string[]]$Raw, [int]$MinLen) {
    return @($Raw |
        ForEach-Object { (($_ -replace '\s+', ' ')).Trim().ToLowerInvariant() } |
        Where-Object { $_.Length -ge $MinLen })
}
function Get-Fenced([string]$Resp) {
    @([regex]::Matches($Resp, '(?s)```[a-z0-9]*\r?\n(.*?)```') | ForEach-Object { $_.Groups[1].Value })
}
function Get-Inline([string]$Resp, [int]$MinLen) {
    @([regex]::Matches($Resp, ('`([^`\r\n]{' + $MinLen + ',})`')) | ForEach-Object { $_.Groups[1].Value })
}

$rows = @()
$agg  = @{}
foreach ($k in @('fenced','line1','inline40','inline20')) { $agg[$k] = @{ T = 0; G = 0 } }

foreach ($topicDir in @(Get-ChildItem -LiteralPath $ReviewsRoot -Directory -ErrorAction SilentlyContinue)) {
    foreach ($resp in @(Get-ChildItem -LiteralPath $topicDir.FullName -Filter 'round-*response.md' -File -ErrorAction SilentlyContinue)) {
        if ($resp.Name -notmatch '^round-(\d+)-(.*)response\.md$') { continue }
        $n   = $matches[1]
        $who = $matches[2].TrimEnd('-'); if (-not $who) { $who = '(canonical)' }
        $bundle = Join-Path $topicDir.FullName "round-$n-bundle.xml"
        if (-not (Test-Path -LiteralPath $bundle)) { continue }

        $bx   = Normalize (Get-Content -Raw -LiteralPath $bundle)
        $text = Get-Content -Raw -LiteralPath $resp.FullName

        $q = Clean (@(Get-Fenced $text) + @(Get-Inline $text 40)) 40
        if ($q.Count -gt 0) {
            $hit = @($q | Where-Object { $bx.Contains($_) }).Count
            $rows += [pscustomobject]@{
                Topic = $topicDir.Name; Round = [int]$n; Who = $who
                Total = $q.Count; Grounded = $hit; Pct = [math]::Round(100 * $hit / $q.Count, 1)
            }
        }

        if ($Split -and $who -ne '(canonical)') {
            $lines = @()
            foreach ($m in [regex]::Matches($text, '(?s)```[a-z0-9]*\r?\n(.*?)```')) {
                foreach ($l in ($m.Groups[1].Value -split '\r?\n')) {
                    $c = (($l -replace '\s+', ' ')).Trim().ToLowerInvariant()
                    if ($c.Length -ge 40) { $lines += $c }
                }
            }
            $sets = @{
                fenced   = Clean (Get-Fenced $text) 40
                inline40 = Clean (Get-Inline $text 40) 40
                inline20 = Clean (Get-Inline $text 20) 20
                line1    = @($lines)
            }
            foreach ($k in $sets.Keys) {
                $set = @($sets[$k]); if ($set.Count -eq 0) { continue }
                $agg[$k].T += $set.Count
                $agg[$k].G += @($set | Where-Object { $bx.Contains($_) }).Count
            }
        }
    }
}

'{0,-30} {1,-5} {2,-16} {3,-7} {4,-9} {5}' -f 'TOPIC','RND','REVIEWER','QUOTES','GROUNDED','PCT'
'-' * 80
foreach ($r in ($rows | Sort-Object Topic, Round, Who)) {
    '{0,-30} {1,-5} {2,-16} {3,-7} {4,-9} {5}' -f $r.Topic, $r.Round, $r.Who, $r.Total, $r.Grounded, "$($r.Pct)%"
}

$scored = @($rows | Where-Object { $_.Total -gt 0 -and $_.Who -ne '(canonical)' })
if ($scored.Count -gt 0) {
    $pcts = @($scored | ForEach-Object { $_.Pct })
    ''
    '=== distribution ==='
    'n     : {0}' -f $scored.Count
    'min   : {0}%' -f ($pcts | Measure-Object -Minimum).Minimum
    'max   : {0}%' -f ($pcts | Measure-Object -Maximum).Maximum
    'mean  : {0}%' -f [math]::Round(($pcts | Measure-Object -Average).Average, 1)
    ''
    'Opus predicted healthy rounds above 80%. Measured 5% mean (2026-08-14).'
}

if ($Split) {
    ''
    '=== fenced vs inline: WHY it fails ==='
    '{0,-10} {1,-8} {2,-10} {3}' -f 'KIND','TOTAL','GROUNDED','PCT'
    foreach ($k in @('fenced','line1','inline40','inline20')) {
        $t = $agg[$k].T; $g = $agg[$k].G
        '{0,-10} {1,-8} {2,-10} {3}' -f $k, $t, $g, $(if ($t -eq 0) { 'n/a' } else { "$([math]::Round(100*$g/$t,1))%" })
    }
    ''
    'Most fenced code in these reviews is code the reviewer AUTHORED -- proposed'
    'fixes and executable checks -- not code it quoted. opus scores lowest'
    'precisely because it writes the most probe code.'
}
