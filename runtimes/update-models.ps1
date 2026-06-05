<#
.SYNOPSIS
    Update opencode model registry by querying opencode providers.
    Extracted from era.ps1 to keep the entry point focused on dispatch.
.DESCRIPTION
    Fetches the list of opencode providers, queries each for available models,
    and merges them into backends/_registry.json under _opencode_model_map.
#>

function Invoke-UpdateModels {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SkillRoot,
        [string[]]$ProviderBlacklist = @('nvidia')
    )
    Test-ThreadJobAvailable
    Write-Host "Fetching opencode providers..."
    $providersOutput = & opencode providers list 2>&1
    $providerNames = @()
    $inProviders = $false
    $providersExited = $false
    foreach ($line in $providersOutput) {
        $clean = $line -replace '\x1b\[[0-9;]+m', ''
        # Group header `┌  Credentials ...` must be checked BEFORE the
        # boundary regex (the line both starts with `┌` and contains content).
        if ($clean -match 'Credentials' -and -not $providersExited) {
            $inProviders = $true
            continue
        }
        if ($clean -match '^[\└┌├]' -or $clean -match '^\s*[\└┌├]') {
            if ($inProviders) {
                $inProviders = $false
                $providersExited = $true
            }
            continue
        }

        if ($inProviders) {
            # Strip leading bullet markers (`●`, `○`, `•`) + their trailing whitespace
            $stripped = $clean -replace '^\s*[●○•]\s*', ''
            $parts = $stripped -split '\s{2,}'
            if ($parts.Count -ge 1) {
                $candidate = $parts[0] -replace '\s+(api|oauth)$', ''
                $candidate = $candidate.Trim()
                if ($candidate -and $candidate.Length -gt 0 -and $candidate -match '[a-zA-Z]' -and $candidate -notmatch '^\d+\s' -and $candidate -notmatch '_KEY$' -and $candidate -ne 'Environment') {
                    $providerNames += $candidate
                }
            }
        }
    }
    $providerNames = $providerNames | Select-Object -Unique
    Write-Host "Found providers: $($providerNames -join ', ')"

    $providerNames = $providerNames | Where-Object { $_.ToLower() -notin $ProviderBlacklist }
    if ($providerNames.Count -eq 0) { throw "No usable providers found after blacklist filtering." }

    $registryPath = Join-Path $SkillRoot 'backends/_registry.json'
    $registry = Get-Content -Raw $registryPath | ConvertFrom-Json

    $newOpencodeMap = @{}
    $modelCount = 0
    $providerJobs = @()

    foreach ($provider in $providerNames) {
        $normalizedProvider = $provider.ToLower()
        $normalizedProvider = $normalizedProvider -replace '\s*\(minimax\.io\)', ''
        $normalizedProvider = $normalizedProvider -replace '\s+', '-'
        $normalizedProvider = $normalizedProvider.Replace('(', '').Replace(')', '')
        Write-Host "Fetching models for provider: $provider (normalized: $normalizedProvider)..."
        $providerJobs += @{
            Name = $provider
            Normalized = $normalizedProvider
            Job = Start-ThreadJob -Name "models-$normalizedProvider" -ThrottleLimit 15 -ScriptBlock { param($np) & opencode models $np --verbose 2>&1 } -ArgumentList $normalizedProvider
        }
    }

    $null = Wait-Job -Job ($providerJobs | ForEach-Object { $_.Job }) -Timeout 120
    foreach ($entry in $providerJobs) {
        $modelsOutput = Receive-Job $entry.Job -ErrorAction SilentlyContinue
        Remove-Job $entry.Job -Force -ErrorAction SilentlyContinue

        # --verbose output: alternating "<provider>/<modelId>" header lines and
        # multi-line JSON bodies. Walk lines, accumulate JSON between headers,
        # parse each, extract variants.
        $providerModels = @{}
        $blob = ($modelsOutput | Out-String)
        $lines = $blob -split "`r?`n"
        $i = 0
        while ($i -lt $lines.Count) {
            $line = $lines[$i].Trim()
            if ($line -match '^(\S+)/(\S+)$' -and $i + 1 -lt $lines.Count -and $lines[$i + 1].Trim().StartsWith('{')) {
                $fullModel = $line
                $i++
                # Collect JSON body using brace-depth tracking with string-literal
                # awareness. Previously the depth counter ran blindly over every
                # character -- a model description containing a literal '}' inside
                # a string would prematurely zero the depth and truncate the JSON
                # body, causing ConvertFrom-Json to throw on garbage.
                $jsonLines = New-Object System.Collections.Generic.List[string]
                $depth = 0
                $started = $false
                $inString = $false
                $prevWasEscape = $false
                while ($i -lt $lines.Count) {
                    $bodyLine = $lines[$i]
                    $jsonLines.Add($bodyLine) | Out-Null
                    foreach ($ch in $bodyLine.ToCharArray()) {
                        if ($prevWasEscape) {
                            # Previous char was a backslash inside a string -- this
                            # char is part of the escape sequence (e.g. \", \\, \n).
                            $prevWasEscape = $false
                            continue
                        }
                        if ($inString) {
                            if ($ch -eq '\') { $prevWasEscape = $true; continue }
                            if ($ch -eq '"') { $inString = $false }
                            # Inside a string: brace chars are literal, don't count.
                            continue
                        }
                        if ($ch -eq '"') { $inString = $true; continue }
                        if ($ch -eq '{') { $depth++; $started = $true }
                        elseif ($ch -eq '}') { $depth-- }
                    }
                    # Newlines reset escape state but not string state (PowerShell
                    # already joins lines via $bodyLine = $lines[$i]).
                    $prevWasEscape = $false
                    $i++
                    if ($started -and $depth -eq 0) { break }
                }
                $jsonText = ($jsonLines -join "`n")
                $modelObj = $null
                try { $modelObj = $jsonText | ConvertFrom-Json } catch { Write-Host "  WARN: failed to parse JSON for $fullModel" }
                $displayName = if ($modelObj -and $modelObj.name) { $modelObj.name } else { $line -replace '^.+/(.+)$', '$1' -replace '[-_]', ' ' }
                $modelKey = ($fullModel -replace '^.+/', '').ToLower() -replace '[\s]+', '-'
                $variants = @()
                if ($modelObj -and $modelObj.variants) {
                    $names = $modelObj.variants.PSObject.Properties.Name
                    if ($names) { $variants = @($names) }
                }
                $providerModels[$modelKey] = @{
                    display = $displayName
                    model_id = $fullModel
                    variants = $variants
                }
                $modelCount++
                continue
            }
            # Fallback: plain (non-verbose) format -- single model-id line
            if ($line -match '^(\S+)/(\S+)$') {
                $fullModel = $line
                $displayName = $line -replace '^.+/(.+)$', '$1' -replace '[-_]', ' '
                $modelKey = $displayName.ToLower() -replace '[\s]+', '-'
                $providerModels[$modelKey] = @{
                    display = $displayName
                    model_id = $fullModel
                    variants = @()
                }
                $modelCount++
            }
            $i++
        }
        if ($providerModels.Count -gt 0) {
            $newOpencodeMap[$entry.Normalized] = $providerModels
            Write-Host "  $($entry.Name) -> $($providerModels.Count) models"
        }
    }

    $existingMap = @{}
    if ($registry._opencode_model_map) {
        $registry._opencode_model_map.PSObject.Properties | ForEach-Object {
            $existingMap[$_.Name] = $_.Value
        }
    }
    $normalizedExistingMap = @{}
    foreach ($key in $existingMap.Keys) {
        $normalized = $key.ToLower() -replace '\s*[\(-]+\s*minimax\.io\s*[\)-]+', '' -replace '\s+', '-' -replace '^[-,]+|[-,]+$', ''
        if ($normalized -and $normalized.Length -gt 0) {
            $normalizedExistingMap[$normalized] = $existingMap[$key]
        }
    }
    foreach ($provider in $newOpencodeMap.Keys) {
        $normalizedProvider = $provider.ToLower() -replace '\s+', '-'
        if (-not $normalizedExistingMap[$normalizedProvider]) {
            $normalizedExistingMap[$normalizedProvider] = $newOpencodeMap[$provider]
        } else {
            $existingModels = $normalizedExistingMap[$normalizedProvider]
            $newModels = $newOpencodeMap[$provider]
            $mergedCount = 0
            $variantPatchCount = 0
            foreach ($modelKey in $newModels.Keys) {
                $entry = $newModels.$modelKey
                # Dedup by model_id, not just by key. If an existing entry has
                # the same model_id under a different key (e.g. a hand-curated
                # short-name alias), refresh ITS variants rather than adding a
                # second entry with the verbose key. Prevents duplicates from
                # re-accumulating across re-runs of update-models.
                $existingByModelId = $null
                if ($entry.model_id) {
                    foreach ($existingKey in @($existingModels.PSObject.Properties.Name)) {
                        $candidate = $existingModels.$existingKey
                        if ($candidate.model_id -eq $entry.model_id) {
                            $existingByModelId = $candidate
                            break
                        }
                    }
                }
                if ($null -eq $existingModels.$modelKey -and $null -eq $existingByModelId) {
                    $existingModels | Add-Member -MemberType NoteProperty -Name $modelKey -Value $entry
                    $mergedCount++
                } else {
                    # Existing entry (by key OR by model_id): refresh variants
                    # from the verbose fetch (idempotent; preserves display +
                    # model_id customizations + any hand-curated short alias).
                    $existing = if ($null -ne $existingModels.$modelKey) { $existingModels.$modelKey } else { $existingByModelId }
                    if ($null -ne $entry.variants) {
                        if ($null -eq $existing.PSObject.Properties['variants']) {
                            $existing | Add-Member -MemberType NoteProperty -Name 'variants' -Value $entry.variants
                            $variantPatchCount++
                        } else {
                            $existing.variants = $entry.variants
                        }
                    }
                }
            }
            if ($mergedCount -gt 0) { Write-Host "  $provider -> $mergedCount new models merged" }
            if ($variantPatchCount -gt 0) { Write-Host "  $provider -> $variantPatchCount existing models stamped with variants" }
        }
    }
    $existingMap = $normalizedExistingMap

    $registry._opencode_model_map = $existingMap
    $updatedJson = $registry | ConvertTo-Json -Depth 20
    $updatedJson | Set-Content -Path $registryPath -Encoding utf8

    Write-Host "`nUpdated opencode model registry:"
    foreach ($p in $existingMap.Keys) {
        $entry = $existingMap[$p]
        $providerModelCount = if ($entry -is [System.Collections.IDictionary]) { $entry.Count } else { $entry.PSObject.Properties.Count }
        Write-Host "  $p : $providerModelCount models"
    }
    Write-Host "Total new models: $modelCount"
    Write-Host "Registry updated at: $registryPath"
}
