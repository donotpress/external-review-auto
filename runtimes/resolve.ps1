#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Portable Layer-1 resolver for /era — natural language -> typed era.ps1 flags.

.DESCRIPTION
    Ports the natural-language resolution rules from era/SKILL.md ("Resolving
    natural-language input") into a deterministic helper ANY driving agent
    (Claude, Gemini, opencode, ...) can shell out to, so `/era <english>`
    resolves IDENTICALLY regardless of which model is driving (PR-D / Fix 6).

    Input: a positional argument OR stdin (pipe). Output: ONLY a JSON object of
    typed era.ps1 flags on stdout (e.g. {"Reviewer":"gemini-pro-low"}). All
    intermediate pipeline output is suppressed via `$null =` / `[void]` so
    nothing pollutes the JSON. Callers parse stdout with ConvertFrom-Json and
    forward the flags to era.ps1.

    LAYERS (R2-I5-Opus): this is Layer 1 (raw english -> typed -Reviewer/-Model/
    -TopicSlug). Layer 2 (era.ps1's -Model hint -> concrete model_id/provider)
    lives in Resolve-ModelFromHint and is NOT duplicated here. Drift between the
    two is prevented structurally: both read _registry.json as the single source
    of truth, and Resolve.Tests.ps1's contract test asserts every -Model value
    this script can emit resolves in era.ps1's Layer 2.

    Unmatched / ambiguous input emits {"error":"unresolved","input":"<raw>"}
    (non-throwing) so the caller can fall back to asking the user; it never
    guesses.

.OUTPUTS
    One JSON object on stdout. Nothing else.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$InputText
)

$ErrorActionPreference = 'Stop'

# Bare-invocation default reviewer. Ships as 'gemini-pro-low' but is overridable
# per-user via $env:ERA_DEFAULT_REVIEWER (first token if a comma list), so a user
# can point their default at any preset (e.g. gemini-pro-high) without editing the
# repo. era.ps1's adaptive default honors the same env var.
$script:DefaultReviewer = if ($env:ERA_DEFAULT_REVIEWER) {
    @(($env:ERA_DEFAULT_REVIEWER -split ',') | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })[0]
} else { 'gemini-pro-low' }
if (-not $script:DefaultReviewer) { $script:DefaultReviewer = 'gemini-pro-low' }

# --- Acquire input: positional arg first, else stdin (do not hang on empty) ---
# CRITICAL (CI-hang fix): distinguish an EXPLICIT empty positional arg
# (`resolve.ps1 ''`) from NO arg at all. If we keyed on `$InputText -eq ''` we
# could not tell them apart, and an explicit '' would fall through to
# [Console]::In.ReadToEnd(). When the process inherits an OPEN (non-EOF)
# redirected stdin (any child of `pwsh -Command`, a background job, or a CI
# runner) ReadToEnd() BLOCKS FOREVER and hangs the whole suite.
#
# $PSBoundParameters.ContainsKey('InputText') is TRUE when a positional arg was
# passed (even ''), FALSE only when the arg was omitted entirely. So we read
# stdin ONLY in the no-arg case. An explicit '' -> empty input -> default,
# without ever touching stdin.
if (-not $PSBoundParameters.ContainsKey('InputText')) {
    # No positional arg supplied. Read stdin only if it is redirected (piped) so
    # the intended "agent pipes input" path works. Console.IsInputRedirected is
    # false for an interactive TTY, so we never block waiting for keystrokes.
    if ([Console]::IsInputRedirected) {
        $stdin = [Console]::In.ReadToEnd()
        if ($null -ne $stdin) { $InputText = $stdin }
    }
}
$raw = if ($null -eq $InputText) { '' } else { $InputText.Trim() }

# --- Locate the registry (single source of truth for model tokens) -----------
$skillRoot = Split-Path -Parent $PSScriptRoot
$registryPath = Join-Path $skillRoot 'backends/_registry.json'
$registry = Get-Content -Raw $registryPath | ConvertFrom-Json

# Build the opencode provider/model map (deepseek, minimax variants, etc.).
$opencodeMap = @{}
if ($registry._opencode_model_map) {
    $registry._opencode_model_map.PSObject.Properties | ForEach-Object {
        $opencodeMap[$_.Name] = $_.Value
    }
}

# Helper to emit JSON and exit (single, clean stdout write).
function script:Emit-Result {
    param([hashtable]$Flags)
    # Compress so stdout is a single line; ConvertTo-Json on a hashtable is pure.
    ($Flags | ConvertTo-Json -Compress -Depth 5)
}

function script:Emit-Unresolved {
    param([string]$RawInput)
    (@{ error = 'unresolved'; input = $RawInput } | ConvertTo-Json -Compress -Depth 5)
}

# --- Filler words to ignore (from era/SKILL.md) ------------------------------
$fillerWords = @('use', 'using', 'with', 'via', 'the', 'please', 'model', 'reviewer', 'try', 'run')

# Reviewer keywords that mark the FIRST non-filler word as a reviewer spec
# (not a topic slug). From era/SKILL.md "Topic-slug vs reviewer disambiguation".
$reviewerKeywords = @('gemini', 'opus', 'sonnet', 'haiku', 'claude', 'deepseek',
    'minimax', 'flash', 'pro', 'api', 'reasoner')

function script:Remove-Filler {
    param([string[]]$Tokens)
    @($Tokens | Where-Object { $_ -and ($fillerWords -notcontains $_.ToLower()) })
}

# For TOPIC-slug candidates: strip ONLY leading filler words (e.g. a leading
# 'use'/'please'/'run'), preserving interior words. Full Remove-Filler would
# drop interior fillers too -- 'fix the login bug' -> 'fix-login-bug' loses the
# interior 'the'. Leading-only strip yields 'fix-the-login-bug'.
function script:Remove-LeadingFiller {
    param([string[]]$Tokens)
    $list = @($Tokens | Where-Object { $_ })
    $i = 0
    while ($i -lt $list.Count -and ($fillerWords -contains $list[$i].ToLower())) { $i++ }
    if ($i -ge $list.Count) { return @() }
    @($list[$i..($list.Count - 1)])
}

# --- Resolve a reviewer-spec token stream -> @{ Reviewer; Model } or $null ----
# Returns $null when the spec is non-empty but matches no known reviewer/model.
function script:Resolve-ReviewerSpec {
    param([string[]]$Tokens)

    $clean = @(script:Remove-Filler -Tokens $Tokens)
    if ($clean.Count -eq 0) {
        # Bare invocation -> the configured default (ships gemini-pro-low).
        return @{ Reviewer = $script:DefaultReviewer }
    }

    $lower = @($clean | ForEach-Object { $_.ToLower() })
    $joined = ($lower -join ' ')
    $canon  = ($joined -replace '[^a-z0-9]', '')   # alnum-only for version matching
    $wants = { param($w) $lower -contains $w }

    $wantsApi    = (& $wants 'api') -or (& $wants 'rest') -or (& $wants 'direct')
    $wantsPro    = (& $wants 'pro')
    $wantsFlash  = (& $wants 'flash')
    $explicitTier = if ($canon -match 'low')  { 'low' }
                    elseif ($canon -match 'high') { 'high' }
                    elseif ($canon -match 'budget') { 'low' }
                    else { $null }

    # ---- Gemini family ----
    # 'gemini' explicit, OR a bare tier word ('flash'/'pro') with no other
    # family anchor: per era/SKILL.md "Highest tier wins" + "family -> gemini",
    # a lone 'flash' -> gemini (3.5 Flash) and a lone 'pro' -> gemini-pro-high.
    # Guard so 'deepseek v4 flash' / 'minimax ... pro' are NOT captured here.
    # 'reasoner' is included so a tier word ('pro'/'flash') next to 'reasoner'
    # ("reasoner pro") does NOT capture the gemini branch before the deepseek/
    # reasoner block below — 'reasoner' is a DeepSeek family marker.
    $noOtherFamily = -not ((& $wants 'deepseek') -or (& $wants 'minimax') -or
        (& $wants 'opus') -or (& $wants 'sonnet') -or (& $wants 'haiku') -or
        (& $wants 'claude') -or (& $wants 'reasoner'))
    if ((& $wants 'gemini') -or (($wantsFlash -or $wantsPro) -and $noOtherFamily)) {
        if ($wantsApi) {
            return @{ Reviewer = 'gemini-api' }
        }
        # Pro tier present (e.g. "gemini 3.1 pro [low|high]") -> pro presets.
        if ($wantsPro) {
            if ($explicitTier -eq 'low') { return @{ Reviewer = 'gemini-pro-low' } }
            # Highest tier wins when unspecified or "high".
            return @{ Reviewer = 'gemini-pro-high' }
        }
        # Flash (or bare "gemini" keyword) -> the gemini preset (3.5 Flash High).
        return @{ Reviewer = 'gemini' }
    }

    # ---- Claude family ----
    if ((& $wants 'opus')) {
        if ($wantsApi) { return @{ Reviewer = 'opus-api' } }
        return @{ Reviewer = 'opus' }
    }
    if ((& $wants 'sonnet')) {
        if ($wantsApi) { return @{ Reviewer = 'sonnet-api' } }
        return @{ Reviewer = 'sonnet' }
    }
    if ((& $wants 'haiku')) {
        if ($wantsApi) { return @{ Reviewer = 'haiku-api' } }
        return @{ Reviewer = 'haiku' }
    }
    if ((& $wants 'claude')) {
        # Family alone -> top model (opus). 'claude direct/api' -> opus-api.
        if ($wantsApi) { return @{ Reviewer = 'opus-api' } }
        return @{ Reviewer = 'opus' }
    }

    # ---- DeepSeek family ----
    # 'reasoner' alone also enters here: it is a $reviewerKeywords token and
    # unambiguously means deepseek-reasoner, so a bare "reasoner" must resolve
    # rather than fall through to {error:unresolved} (round-5 nit).
    if ((& $wants 'deepseek') -or (& $wants 'reasoner')) {
        if ((& $wants 'reasoner')) {
            if ($env:DEEPSEEK_API_KEY) { return @{ Reviewer = 'deepseek-reasoner-api' } }
            return @{ Reviewer = 'deepseek'; Model = 'opencode-go/deepseek-reasoner' }
        }
        if ($wantsApi) { return @{ Reviewer = 'deepseek-api' } }
        # Variant override via the opencode-go map (single source of truth).
        $variant = script:Find-OpencodeModel -Canon $canon -ProviderKey 'opencode-go' -FamilyHint 'deepseek'
        if ($variant) { return @{ Reviewer = 'deepseek'; Model = $variant } }
        # Bare "deepseek" -> registry default for the deepseek preset.
        return @{ Reviewer = 'deepseek' }
    }

    # ---- MiniMax family ----
    if ((& $wants 'minimax')) {
        if ($wantsApi) { return @{ Reviewer = 'minimax-api' } }
        # "minimax" / "minimax m2.7" -> latest minor wins (the minimax preset
        # default model_id). An explicit older minor maps to that variant.
        $variant = script:Find-OpencodeModel -Canon $canon -ProviderKey 'minimax' -FamilyHint 'minimax'
        if ($variant) { return @{ Reviewer = 'minimax'; Model = $variant } }
        # Bare minimax -> the registry default (latest minor).
        return @{ Reviewer = 'minimax'; Model = $registry.minimax.model_id }
    }

    # No known reviewer keyword matched.
    return $null
}

# --- Find an opencode model_id by canonical-token match within a provider -----
# Used for variant overrides (e.g. "deepseek v4 flash" -> opencode-go/deepseek-v4-flash).
# Reads _opencode_model_map so the model list is never hardcoded here.
function script:Find-OpencodeModel {
    param(
        [string]$Canon,        # alnum-only canonical of the full spec
        [string]$ProviderKey,  # e.g. 'opencode-go' or 'minimax'
        [string]$FamilyHint    # e.g. 'deepseek' / 'minimax' to scope the search
    )
    if (-not $opencodeMap.ContainsKey($ProviderKey)) { return $null }
    $provider = $opencodeMap[$ProviderKey]

    $best = $null
    $bestLen = -1
    foreach ($modelKey in $provider.PSObject.Properties.Name) {
        $entry = $provider.$modelKey
        if ($null -eq $entry -or -not $entry.model_id) { continue }
        $keyCanon = ($modelKey.ToLower() -replace '[^a-z0-9]', '')
        if (-not $keyCanon) { continue }
        # Only consider models in the requested family.
        $famCanon = ($FamilyHint.ToLower() -replace '[^a-z0-9]', '')
        if ($keyCanon -notlike "*$famCanon*") { continue }
        # The spec canon must contain the model key canon (exact-superset match):
        # "deepseekv4flash" contains "deepseekv4flash". Pick the LONGEST such
        # match so "deepseek v4 flash" beats the shorter "deepseek" family token
        # and a bare "deepseek" (canon 'deepseek') matches nothing here -> default.
        if ($Canon.Contains($keyCanon) -and $keyCanon.Length -gt $bestLen) {
            $best = $entry.model_id
            $bestLen = $keyCanon.Length
        }
    }
    return $best
}

# --- Main: split topic vs reviewer, resolve, emit ----------------------------

# Empty / whitespace input -> bare default.
if (-not $raw) {
    Write-Output (script:Emit-Result -Flags @{ Reviewer = $script:DefaultReviewer })
    return
}

# --- Command keywords (doctor / setup / check / preflight / init) -------------
# These bypass reviewer resolution entirely. The LLM forwards the Command flag
# to era.ps1, which runs the matching preflight or setup action.
$commandKeywords = @{
    doctor    = 'doctor'; setup     = 'doctor'; check     = 'doctor'
    preflight = 'doctor'; init      = 'doctor'; install   = 'doctor'
}

# --- "update models" command -------------------------------------------------
# Matches: "update models", "refresh models", "sync models", "update registry"
function script:Try-UpdateModels {
    param([string[]]$Tokens)
    $clean = @(script:Remove-Filler -Tokens $Tokens)
    if ($clean.Count -lt 2) { return $null }
    $first = $clean[0].ToLower()
    $second = $clean[1].ToLower()
    if (($first -eq 'update' -or $first -eq 'refresh' -or $first -eq 'sync') -and
        ($second -eq 'models' -or $second -eq 'registry' -or $second -eq 'providers')) {
        return @{ Command = 'update-models' }
    }
    return $null
}

# --- "review this" command ---------------------------------------------------
# Matches: "review this", "review current", "review now", "review here"
# The LLM detects context (git changes, conversation focus, newest spec) and
# dispatches with the right flags. resolve.ps1 just signals the intent.
function script:Try-ReviewThis {
    param([string[]]$Tokens)
    $clean = @(script:Remove-Filler -Tokens $Tokens)
    if ($clean.Count -lt 2) { return $null }
    if ($clean[0].ToLower() -ne 'review') { return $null }
    $second = $clean[1].ToLower()
    if ($second -in @('this', 'current', 'now', 'here', 'it')) {
        return @{ Command = 'review-this' }
    }
    return $null
}

# --- "what should I review" / "suggest" command ------------------------------
# Matches: "what should i review", "what to review", "suggest", "what changed"
# The LLM scans the repo for unreviewed specs, recent commits, pending changes.
function script:Try-Suggest {
    param([string[]]$Tokens)
    $clean = @(script:Remove-Filler -Tokens $Tokens)
    if ($clean.Count -eq 0) { return $null }
    $first = $clean[0].ToLower()
    # "suggest" alone
    if ($first -eq 'suggest' -or $first -eq 'recommend') {
        return @{ Command = 'suggest' }
    }
    # "what" ... "review" pattern: "what should i review", "what to review", "what changed"
    if ($first -eq 'what' -and $clean.Count -ge 2) {
        $joined = ($clean | ForEach-Object { $_.ToLower() }) -join ' '
        if ($joined -match 'review|changed|suggest|should') {
            return @{ Command = 'suggest' }
        }
    }
    return $null
}

# --- "multi" command ---------------------------------------------------------
# Matches: "multi gemini,opus", "multi deepseek,sonnet,minimax"
# The word "multi" is a prefix; everything after is a comma-separated reviewer list.
function script:Try-Multi {
    param([string[]]$Tokens)
    $clean = @(script:Remove-Filler -Tokens $Tokens)
    if ($clean.Count -lt 2) { return $null }
    if ($clean[0].ToLower() -ne 'multi') { return $null }
    # Everything after "multi" is the reviewer spec. Join and split on comma.
    $reviewerSpec = (@($clean[1..($clean.Count - 1)]) -join ' ')
    $reviewerTokens = @($reviewerSpec -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($reviewerTokens.Count -lt 2) { return $null }
    # Resolve each reviewer individually
    $resolved = @()
    foreach ($rt in $reviewerTokens) {
        $spec = script:Resolve-ReviewerSpec -Tokens @($rt)
        if ($null -ne $spec -and $spec.ContainsKey('Reviewer')) {
            $resolved += $spec['Reviewer']
        } else {
            # Can't resolve one of them — bail
            return $null
        }
    }
    return @{ Reviewer = ($resolved -join ',') }
}

# --- "set default" command ---------------------------------------------------
# Matches: "set default to gemini pro high", "default opus", "set default sonnet"
# Resolves the reviewer spec and emits {Command:'set-default', Reviewer:'<preset>'}.
function script:Try-SetDefault {
    param([string[]]$Tokens)
    $clean = @(script:Remove-Filler -Tokens $Tokens)
    if ($clean.Count -lt 2) { return $null }

    $head = $clean[0].ToLower()
    $reviewerStart = 0

    # "set default <reviewer>" or "set default to <reviewer>"
    if ($head -eq 'set') {
        if ($clean.Count -lt 3) { return $null }
        if ($clean[1].ToLower() -ne 'default') { return $null }
        $reviewerStart = 2
        # skip optional "to"
        if ($reviewerStart -lt $clean.Count -and $clean[$reviewerStart].ToLower() -eq 'to') { $reviewerStart++ }
    }
    # "default <reviewer>" or "default to <reviewer>"
    elseif ($head -eq 'default') {
        $reviewerStart = 1
        if ($reviewerStart -lt $clean.Count -and $clean[$reviewerStart].ToLower() -eq 'to') { $reviewerStart++ }
    }
    else { return $null }

    if ($reviewerStart -ge $clean.Count) { return $null }

    $reviewerTokens = @($clean[$reviewerStart..($clean.Count - 1)])
    $spec = script:Resolve-ReviewerSpec -Tokens $reviewerTokens
    if ($null -eq $spec -or -not $spec.ContainsKey('Reviewer')) { return $null }
    return @{ Command = 'set-default'; Reviewer = $spec['Reviewer'] }
}

$tokens = @($raw -split '\s+' | Where-Object { $_ })
$cleanForCmd = @(script:Remove-Filler -Tokens $tokens)
if ($cleanForCmd.Count -gt 0) {
    $firstLower = $cleanForCmd[0].ToLower()
    # Simple command keywords (doctor, setup, etc.)
    if ($commandKeywords.ContainsKey($firstLower)) {
        Write-Output (script:Emit-Result -Flags @{ Command = $commandKeywords[$firstLower] })
        return
    }
    # "set default" / "default" command
    if ($firstLower -eq 'set' -or $firstLower -eq 'default') {
        $setDefaultResult = script:Try-SetDefault -Tokens $tokens
        if ($null -ne $setDefaultResult) {
            Write-Output (script:Emit-Result -Flags $setDefaultResult)
            return
        }
    }
    # "update models" / "refresh models" / "sync models"
    if ($firstLower -eq 'update' -or $firstLower -eq 'refresh' -or $firstLower -eq 'sync') {
        $updateResult = script:Try-UpdateModels -Tokens $tokens
        if ($null -ne $updateResult) {
            Write-Output (script:Emit-Result -Flags $updateResult)
            return
        }
    }
    # "review this" / "review current" / "review now"
    if ($firstLower -eq 'review') {
        $reviewThisResult = script:Try-ReviewThis -Tokens $tokens
        if ($null -ne $reviewThisResult) {
            Write-Output (script:Emit-Result -Flags $reviewThisResult)
            return
        }
    }
    # "what should i review" / "suggest" / "recommend"
    if ($firstLower -eq 'what' -or $firstLower -eq 'suggest' -or $firstLower -eq 'recommend') {
        $suggestResult = script:Try-Suggest -Tokens $tokens
        if ($null -ne $suggestResult) {
            Write-Output (script:Emit-Result -Flags $suggestResult)
            return
        }
    }
    # "multi gemini,opus" — multi-reviewer dispatch
    if ($firstLower -eq 'multi') {
        $multiResult = script:Try-Multi -Tokens $tokens
        if ($null -ne $multiResult) {
            Write-Output (script:Emit-Result -Flags $multiResult)
            return
        }
    }
}

# Explicit "<topic> use <reviewer-spec>" splitter. Match the LAST "use" so a topic
# containing the word (e.g. "fix use of deprecated api use gemini") keeps its full
# slug. Only split when the tail contains at least one reviewer keyword; otherwise
# the input is a topic whose description happens to include "use" and no reviewer
# was intended (e.g. "fix the use of deprecated api" with no reviewer keyword).
$useIdx = -1
for ($i = 0; $i -lt $tokens.Count; $i++) {
    if ($tokens[$i].ToLower() -eq 'use') { $useIdx = $i }
}

$topicSlug = $null
$reviewerTokens = $tokens
$hasReviewerInTail = $false
$isReviewerFirst = $false

if ($useIdx -ge 0) {
    # Only split on 'use' when the tail contains at least one reviewer keyword.
    # Otherwise the topic naturally contains the word 'use' (e.g. "fix the use of
    # deprecated api") and no reviewer was intended.
    $afterUse = if ($useIdx -lt $tokens.Count - 1) { @($tokens[($useIdx + 1)..($tokens.Count - 1)]) } else { @() }
    $afterLower = @($afterUse | ForEach-Object { $_.ToLower() })
    $hasReviewerInTail = ($reviewerKeywords | Where-Object { $afterLower -contains $_ }).Count -gt 0
    if ($hasReviewerInTail) {
        # Everything before 'use' is the topic; everything after is the reviewer spec.
        $beforeUse = @($tokens[0..([Math]::Max(0, $useIdx - 1))])
        if ($useIdx -eq 0) { $beforeUse = @() }
        # Topic candidates strip only LEADING filler (preserve interior words like
        # the 'the' in 'fix the login bug') -- see Remove-LeadingFiller.
        $topicCandidate = @(script:Remove-LeadingFiller -Tokens $beforeUse)
        if ($topicCandidate.Count -gt 0) {
            # Topic slug is the (leading-filler-stripped) text before 'use', space->dash.
            $topicSlug = ($topicCandidate -join '-')
        }
        $reviewerTokens = $afterUse
    }
    # fall through to topic-slug-only path below when tail has no reviewer keyword
} else {
    # No 'use' splitter. Disambiguate by the FIRST non-filler word: if it's a
    # reviewer keyword, the whole tail is a reviewer spec; otherwise it's a
    # topic slug with the default reviewer.
    $clean = @(script:Remove-Filler -Tokens $tokens)
    if ($clean.Count -gt 0) {
        $firstCanon = ($clean[0].ToLower() -replace '[^a-z0-9]', '')
        $isReviewerFirst = $false
        foreach ($kw in $reviewerKeywords) {
            # EXACT/word match only. A substring `-like "*$kw*"` misclassifies
            # topic slugs whose first word merely CONTAINS a (short) reviewer
            # keyword: 'improvement-plan'/'proxy-config' contain 'pro',
            # 'api-gateway-spec' contains 'api', 'geminify-the-thing' contains
            # 'gemini'. Those must become -TopicSlug + default reviewer, not be
            # routed to reviewer-spec resolution (which fails -> unresolved).
            if ($firstCanon -eq $kw) { $isReviewerFirst = $true; break }
        }
        if (-not $isReviewerFirst) {
            # Topic-slug-only invocation: default reviewer. Build the slug from a
            # LEADING-filler-only strip so interior words survive
            # ('fix the login bug' -> 'fix-the-login-bug'), unlike $clean which
            # has all fillers removed (used above only for the first-token check).
            $topicTokens = @(script:Remove-LeadingFiller -Tokens $tokens)
            $topicSlug = ($topicTokens -join '-')
            Write-Output (script:Emit-Result -Flags @{ TopicSlug = $topicSlug; Reviewer = $script:DefaultReviewer })
            return
        }
    }
}

# "use" found but tail had no reviewer keyword — treat as topic-slug-only.
if ($useIdx -ge 0 -and -not $hasReviewerInTail) {
    $topicTokens = @(script:Remove-LeadingFiller -Tokens $tokens)
    Write-Output (script:Emit-Result -Flags @{ TopicSlug = ($topicTokens -join '-'); Reviewer = $script:DefaultReviewer })
    return
}

# Resolve the reviewer spec.
$spec = script:Resolve-ReviewerSpec -Tokens $reviewerTokens

if ($null -eq $spec) {
    # First token was a reviewer keyword (e.g. "api") that didn't resolve to a
    # known preset — fall back to topic slug with default reviewer instead of
    # emitting unresolved.
    if ($isReviewerFirst) {
        $topicTokens = @(script:Remove-LeadingFiller -Tokens $tokens)
        Write-Output (script:Emit-Result -Flags @{ TopicSlug = ($topicTokens -join '-'); Reviewer = $script:DefaultReviewer })
        return
    }
    Write-Output (script:Emit-Unresolved -RawInput $raw)
    return
}

$flags = @{}
if ($topicSlug) { $flags['TopicSlug'] = $topicSlug }
foreach ($k in $spec.Keys) { $flags[$k] = $spec[$k] }

Write-Output (script:Emit-Result -Flags $flags)
