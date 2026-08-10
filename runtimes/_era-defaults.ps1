<#
.SYNOPSIS
    Single source of truth for the default reviewer(s).

.DESCRIPTION
    Dot-sourced by BOTH resolve.ps1 (Layer 1) and era.ps1 (Layer 2). They used to
    each carry their own default with different parsing, which is how a bare /era
    could dispatch a different reviewer than either layer claimed:

      - resolve.ps1 took only `[0]` of a comma list, so a panel silently collapsed
        to its first member.
      - era.ps1 treated the same value as a fallback *preference order*.
      - Layer 1 always emits an explicit -Reviewer, so Layer 2's default was dead
        code through the real skill path.

    WHY A FILE AND NOT AN ENV VAR
    An environment variable is per-process and inherited, so it is neither stable
    nor shell-agnostic:
      - a value set at Windows User scope is NOT visible to already-running
        processes, which keep handing the OLD value to every child they spawn
        (observed 2026-08-02: a cleared var kept resolving to its previous value
        for the life of a WSL interop session);
      - PowerShell User scope, a WSL `export`, and whatever opencode/agy inherit
        are three different stores that drift apart.
    A JSON file next to the skill is read identically from Claude Code, PowerShell,
    WSL, opencode and agy, because every caller locates it from $PSScriptRoot
    rather than from the environment or the current directory.

.NOTES
    Precedence, highest first:
      1. an explicit -Reviewer on the command line  (handled by the callers)
      2. $env:ERA_DEFAULT_REVIEWER                  (deliberate per-session override)
      3. config/defaults.json                       (persistent, cross-shell)
      4. $script:EraShippedPanel                    (last-resort, never empty)
#>

# Last-resort default. Only used if the config file is missing or unreadable, so
# /era can never end up with no reviewer at all.
$script:EraShippedPanel = @('gemini', 'opus', 'deepseek-flash')

function Get-EraDefaultsPath {
    param([Parameter(Mandatory)][string]$SkillRoot)
    Join-Path $SkillRoot 'config/defaults.json'
}

function Get-EraDefaultReviewer {
    <#
        Returns a string[] of preset names. Never returns empty.
        `-AsString` returns the comma-joined form the CLI layers pass around.
    #>
    param(
        [Parameter(Mandatory)][string]$SkillRoot,
        [switch]$AsString
    )

    $result = $null
    $fromEnv = $null
    $fromFile = $null

    # (2) explicit per-session override
    if ($env:ERA_DEFAULT_REVIEWER) {
        $fromEnv = @($env:ERA_DEFAULT_REVIEWER -split ',' |
            ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    }

    # (3) persistent config file — read even when the env var won, so a silent
    # disagreement between the two can be reported instead of guessed at.
    $path = Get-EraDefaultsPath -SkillRoot $SkillRoot
    if (Test-Path -LiteralPath $path) {
        try {
            $cfg = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
            if ($cfg.reviewer) {
                $fromFile = @($cfg.reviewer | ForEach-Object { "$_".Trim().ToLower() } |
                    Where-Object { $_ })
            }
        }
        catch {
            # A corrupt config must not take /era down — fall through to the
            # shipped panel and say so, rather than failing the whole run.
            # stderr — see the note below; resolve.ps1's stdout must stay pure JSON.
            [Console]::Error.WriteLine("[era] WARNING: could not parse $path ($($_.Exception.Message)); using the shipped default.")
        }
    }

    # The CONFIG FILE WINS over the environment variable. That is deliberate and
    # is the opposite of the usual convention, for a specific reason:
    #
    # The file is EXPLICIT — a user wrote it via `/era set default`. The env var is
    # AMBIENT — it is inherited, and nothing about reading it tells you whether
    # anyone meant it. It is also effectively impossible to clear from inside a
    # running session: a long-lived ancestor captures the value at ITS startup and
    # hands that copy to every descendant forever.
    #
    # Measured on this box 2026-08-02: ERA_DEFAULT_REVIEWER had been cleared from
    # User scope, Machine scope and HKCU\Environment, and the WSL VM, the editor
    # and the shell had all been restarted — yet every spawned process still
    # received the 4-day-old value, because the owning WindowsTerminal.exe had
    # been running since 2026-07-29. Under env-wins that silently collapsed a
    # 3-reviewer panel to one, three restarts deep, with the persisted config
    # saying otherwise.
    #
    # So: explicit beats ambient. The env var still works as a default when no
    # config file exists (backwards compatible for anyone who set it on purpose),
    # and an override attempt that loses is reported rather than swallowed.
    if ($fromFile) { $result = $fromFile } elseif ($fromEnv) { $result = $fromEnv }

    if ($fromEnv -and $fromFile -and (($fromEnv -join ',') -ne ($fromFile -join ','))) {
        # STDERR, not Write-Host. resolve.ps1's contract is "stdout is ONLY JSON"
        # and its callers (era.ps1 and the Pester contract tests) run it as
        # `pwsh -File resolve.ps1 …` and pipe stdout straight into ConvertFrom-Json.
        # Write-Host lands in that subprocess stdout, so a diagnostic printed
        # there corrupts the JSON for every caller. One line: an inherited env var
        # can linger for days, so this would otherwise be permanent noise.
        [Console]::Error.WriteLine("[era] ignoring stale `$env:ERA_DEFAULT_REVIEWER='$($fromEnv -join ',')' (config/defaults.json wins). Use -Reviewer for a one-off.")
    }

    # (4) shipped fallback
    if (-not $result) { $result = $script:EraShippedPanel }

    if ($AsString) { return ($result -join ',') }
    return @($result)
}

function Set-EraDefaultReviewer {
    <# Persist the default to config/defaults.json. Accepts one or many presets. #>
    param(
        [Parameter(Mandatory)][string]$SkillRoot,
        [Parameter(Mandatory)][string[]]$Reviewer
    )
    $presets = @($Reviewer | ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
    if (-not $presets) { throw "No reviewer preset supplied." }

    $path = Get-EraDefaultsPath -SkillRoot $SkillRoot
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $payload = [ordered]@{
        reviewer = $presets
        note     = 'Default reviewer(s) for a bare /era. A list is dispatched simultaneously as a panel. Edit via `/era set default <names>` or by hand.'
    }
    $payload | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}
