<#
.SYNOPSIS
    Core workflow for /external-review-auto. Dot-sourced by SKILL.md
    invocations and by runtimes/era.ps1 standalone shell entry.
#>
# SPLIT LOADER (2026-09-12, see docs/specs/2026-09-12-era-module-boundaries.md).
# Function bodies live in workflow/*.ps1 by module; this file keeps the header
# and loads them. Dot-sourcing shares session state, so scoping, $script: and
# cross-function calls behave exactly as when everything lived here. Historical
# `workflow.ps1:NNNN` line references point at the pre-split monolith; function
# names are the stable handle.
. (Join-Path $PSScriptRoot 'workflow/recovery.ps1')
. (Join-Path $PSScriptRoot 'workflow/telemetry.ps1')
. (Join-Path $PSScriptRoot 'workflow/bundle.ps1')
. (Join-Path $PSScriptRoot 'workflow/dispatch.ps1')

