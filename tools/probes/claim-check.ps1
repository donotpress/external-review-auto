<#
.SYNOPSIS
    claim-check: per-seat citation grounding for a delivered review.
.DESCRIPTION
    For one response file: extract `path:line` / `path:start-end` citations
    (backticked or bare, the two dominant forms measured across archived
    rounds), check each against the bundle frame (file spans parsed from the
    sibling round-N-bundle.xml) and the disk frame (paths joined on
    -RepoRoot when given), and write `<response>.check.json` beside it:
    totals plus the ungrounded list. Advisory instrument: exit 0 with a
    receipt whenever the response is readable; nonzero only when inputs are
    missing. Never throws on content -- an unparseable line is ungrounded,
    not fatal.

    Falsifiable prediction (measured 2026-09-12): on CODE-review rounds
    (bundle carries repo source), a healthy review grounds a majority of
    citations in AT LEAST ONE frame -- cmdc-backend opus 8/8 and muse-spark
    12/12 bundle-grounded; skill-review opus 18/31 per frame. Doc-review
    rounds are EXCLUDED by construction: plan-review seats cite code paths
    second-hand from the reviewed doc, so 0-bundle-grounded there is correct
    output, not probe failure. Below majority on a code round, treat the
    seat as suspect first; if healthy rounds persistently fail, correct this
    header, never silently lower a threshold elsewhere.

    The three confounds from citation-grounding.ps1 apply unchanged
    (agentic reviewers cite disk not bundle; -Diff subsets; no shared
    convention) -- which is why both frames are reported separately instead
    of collapsed to one verdict.

.EXAMPLE
    pwsh tools/probes/claim-check.ps1 -ResponsePath <round-1-opus-response.md> [-BundlePath <round-1-bundle.xml>] [-RepoRoot <repo>]
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResponsePath,
    [string]$BundlePath,
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ResponsePath)) {
    throw "[claim-check] no response at '$ResponsePath' -- nothing to check."
}
if (-not $BundlePath) {
    $dir = Split-Path -Parent $ResponsePath
    $base = [System.IO.Path]::GetFileName($ResponsePath)
    if ($base -match '^round-(\d+)-.*response\.md$') {
        $cand = Join-Path $dir ("round-$($matches[1])-bundle.xml")
        if (Test-Path -LiteralPath $cand) { $BundlePath = $cand }
    }
}

# Bundle frame: path -> line count, same shape as citation-grounding.
$bundleSpans = @{}
if ($BundlePath -and (Test-Path -LiteralPath $BundlePath)) {
    try {
        $raw = Get-Content -Raw -LiteralPath $BundlePath -ErrorAction Stop
        foreach ($m in [regex]::Matches($raw, '(?s)<file\s+path="([^"]+)"[^>]*>(.*?)</file>')) {
            $p = ($m.Groups[1].Value -replace '\\', '/').TrimStart('./')
            $bundleSpans[$p] = ([regex]::Matches($m.Groups[2].Value, "`n")).Count + 1
        }
    } catch { $bundleSpans = @{} }
}

$text = Get-Content -Raw -LiteralPath $ResponsePath -ErrorAction Stop
$exts = 'ps1|psm1|psd1|md|py|js|ts|tsx|json|xml|yml|yaml|toml|rs|go|java|css|html|sh'
$pat = "(?:``)?([A-Za-z0-9_][A-Za-z0-9_./-]*(?:/[^:`\s]+)?\.($exts))(?::|#L?)(\d+)(?:\s*[-–]\s*(\d+))?(?:``)?"
$cites = @()
foreach ($m in [regex]::Matches($text, $pat)) {
    $cites += [ordered]@{
        cite = $m.Groups[0].Value.Trim('`')
        path = ($m.Groups[1].Value -replace '\\', '/').TrimStart('./')
        line = [int]$m.Groups[3].Value
        last = if ($m.Groups[4].Success) { [int]$m.Groups[4].Value } else { [int]$m.Groups[3].Value }
    }
}

$rows = @()
foreach ($c in $cites) {
    $inBundle = $bundleSpans.ContainsKey($c.path)
    $spanOk = $false
    if ($inBundle) { $spanOk = ($c.line -ge 1 -and $c.last -le $bundleSpans[$c.path]) }
    $onDisk = $false
    if ($RepoRoot) {
        $full = Join-Path $RepoRoot ($c.path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        try {
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                $lc = 0
                try { $lc = @(Get-Content -LiteralPath $full -ErrorAction Stop).Count } catch { $lc = 0 }
                $onDisk = ($c.line -ge 1 -and ($lc -eq 0 -or $c.last -le $lc))
            }
        } catch { $onDisk = $false }
    }
    $rows += [ordered]@{
        cite = $c.cite; path = $c.path; line = $c.line
        grounded_bundle = $spanOk; grounded_disk = $onDisk
    }
}

$preset = 'unknown'; $round = 0
$bn = [System.IO.Path]::GetFileName($ResponsePath)
if ($bn -match '^round-(\d+)-(.+)response\.md$') { $round = [int]$matches[1]; $preset = $matches[2].TrimEnd('-') }

$receipt = [ordered]@{
    tool = 'era-claim-check'
    preset = $preset
    round = $round
    citations_total = @($cites).Count
    grounded_bundle = @($rows | Where-Object { $_.grounded_bundle }).Count
    grounded_disk = @($rows | Where-Object { $_.grounded_disk }).Count
    ungrounded = @($rows | Where-Object { -not $_.grounded_bundle -and -not $_.grounded_disk } |
        ForEach-Object { $_.cite })
    generated_utc = ([datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
}
$outPath = "$ResponsePath.check.json"
$receipt | ConvertTo-Json -Compress -Depth 4 | Set-Content -LiteralPath $outPath -Encoding utf8
$gb = $receipt.grounded_bundle; $gd = $receipt.grounded_disk; $n = $receipt.citations_total
Write-Host "[claim-check] $preset round ${round}: $n citations ($gb bundle-grounded, $gd disk-grounded) -> $outPath"
exit 0
