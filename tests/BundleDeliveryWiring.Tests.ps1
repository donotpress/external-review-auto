<#
  END-TO-END wiring for the delivery gate.

  WHY THIS FILE EXISTS. `BundleDeliveryPreflight.Tests.ps1` proved
  `Get-EraBackendDelivery` honours a registry override by passing `-ModelInfo`
  straight to the pure function. It passed. The feature was DEAD: `era.ps1`
  projects the registry into `$registryHash` field by field and simply did not
  copy `max_bundle_bytes` / `max_bundle_tokens`, so on every real dispatch the
  plan read `$null` and the override branch never fired. The documented promise
  -- "a re-measurement is data, not a code change" -- was false end-to-end, and
  shipped that way in SKILL.md, README.md, the assessment and the v2.3 notes.

  A unit test that bypasses the layer under suspicion proves the function works
  and says nothing about the product. So these run the REAL `era.ps1` against a
  REAL copied skill tree with a REAL edited registry, and assert on what era
  prints.

  They cost nothing and touch no network: an over-ceiling bundle is refused at
  preflight (exit 1) BEFORE any reviewer is dispatched, which is precisely the
  behaviour being asserted.
#>

BeforeAll {
    $script:SkillRoot = Split-Path -Parent $PSScriptRoot

    function New-EraSandbox {
        <# A throwaway skill tree + a throwaway git repo to review. #>
        param([hashtable]$RegistryOverrides = @{})

        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("era-wire-" + [guid]::NewGuid().ToString('N').Substring(0,8))
        $skill = Join-Path $root 'skill'
        $repo  = Join-Path $root 'repo'
        $null = New-Item -ItemType Directory -Path $skill, $repo -Force

        foreach ($item in @('workflow.ps1','runtimes','backends','config')) {
            Copy-Item -LiteralPath (Join-Path $script:SkillRoot $item) -Destination $skill -Recurse -Force
        }

        # Edit the copied registry, never the real one.
        $regPath = Join-Path $skill 'backends/_registry.json'
        $reg = Get-Content -Raw -LiteralPath $regPath | ConvertFrom-Json
        foreach ($preset in $RegistryOverrides.Keys) {
            foreach ($k in $RegistryOverrides[$preset].Keys) {
                $reg.$preset | Add-Member -NotePropertyName $k -NotePropertyValue $RegistryOverrides[$preset][$k] -Force
            }
        }
        $reg | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $regPath -Encoding utf8

        # ~90 KB of content, deliberately OVER opencode's 51,200-byte attach cap so
        # the seat is on the read-tool path. That matters: the attach cap is a
        # property of the transport (it is where opencode truncates) and is NOT
        # overridable by a registry key, so exercising the override through an
        # attach round would test a path that correctly ignores it.
        1..900 | ForEach-Object { "# line $_ : " + ('x' * 90) } | Set-Content -LiteralPath (Join-Path $repo 'subject.md') -Encoding utf8
        'review this' | Set-Content -LiteralPath (Join-Path $repo 'prompt.md') -Encoding utf8

        Push-Location $repo
        try {
            git init -q 2>&1 | Out-Null
            git add -A 2>&1 | Out-Null
            git -c user.email=t@t -c user.name=t commit -qm init 2>&1 | Out-Null
        } finally { Pop-Location }

        return @{ Root = $root; Skill = $skill; Repo = $repo }
    }

    function Invoke-EraInSandbox {
        param([hashtable]$Box, [string[]]$ExtraArgs = @())
        $era = Join-Path $Box.Skill 'runtimes/era.ps1'
        Push-Location $Box.Repo
        try {
            $out = & pwsh -NoProfile -File $era -TopicSlug wiring -Reviewer opus,deepseek-flash `
                        -IncludeFiles 'subject.md' -PromptOverrideFile 'prompt.md' -Force @ExtraArgs 2>&1
            return @{ Text = ($out | Out-String); Exit = $LASTEXITCODE }
        } finally { Pop-Location }
    }
}

Describe 'registry ceilings reach the real dispatch path' -Tag Unit {

    It 'honours max_bundle_bytes from the registry, end to end' {
        # THE REGRESSION TEST. Before the fix this printed the built-in ceiling and
        # the round proceeded; the override was silently dropped in era.ps1's
        # projection. 4,096 is far below the ~90 KB bundle, so the gate must bite.
        $box = New-EraSandbox -RegistryOverrides @{ 'deepseek-flash' = @{ max_bundle_bytes = 4096 } }
        try {
            $r = Invoke-EraInSandbox -Box $box
            $r.Text | Should -Match 'limit 4,096 bytes'
            $r.Text | Should -Match 'CANNOT FIT'
            $r.Text | Should -Match 'Refusing this round'
            $r.Exit | Should -Be 1   # preflight refusal: nothing dispatched, nothing spent
        } finally { Remove-Item -LiteralPath $box.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'honours max_bundle_tokens from the registry, end to end' {
        $box = New-EraSandbox -RegistryOverrides @{ 'opus' = @{ max_bundle_tokens = 10 } }
        try {
            $r = Invoke-EraInSandbox -Box $box
            $r.Text | Should -Match 'limit 10 tokens'
            $r.Text | Should -Match 'Refusing this round'
            $r.Exit | Should -Be 1
        } finally { Remove-Item -LiteralPath $box.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'treats a registry ceiling of 0 as a real ceiling, not as absent' {
        # `if ($ModelInfo.max_bundle_bytes)` made 0 falsy, so "this channel can
        # carry nothing" was silently ignored.
        $box = New-EraSandbox -RegistryOverrides @{ 'deepseek-flash' = @{ max_bundle_bytes = 0 } }
        try {
            $r = Invoke-EraInSandbox -Box $box
            $r.Text | Should -Match 'limit 0 bytes'
            $r.Exit | Should -Be 1
        } finally { Remove-Item -LiteralPath $box.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'warns and keeps the built-in ceiling when the registry value is not a number' {
        # A raw PowerShell cast error is not era's clean preflight shape -- the
        # same lesson ERA_BROAD_MAX_FILES already learned.
        $box = New-EraSandbox -RegistryOverrides @{ 'deepseek-flash' = @{ max_bundle_bytes = 'lots' } }
        try {
            $r = Invoke-EraInSandbox -Box $box
            $r.Text | Should -Match "max_bundle_bytes='lots' is not a non-negative number"
            $r.Text | Should -Match 'limit 1,048,576 bytes'
        } finally { Remove-Item -LiteralPath $box.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It '-PremiseCheck lands in the BUNDLE the reviewer receives' {
        # THE GAP THIS CLOSES. -PremiseCheck shipped in v2.5 with source-assertion
        # tests only: they checked that the Add-Content call exists and sits before
        # repomix, which would pass against an implementation that wrote to the
        # wrong file, wrote nothing, or ran after the bundle was sealed. Exactly
        # the class of test this project spent two days finding elsewhere.
        #
        # Free and hermetic: the registry override forces a preflight refusal, so
        # era builds the bundle and then exits 1 without dispatching a reviewer.
        # The bundle is the artifact under test, and no money changes hands.
        $box = New-EraSandbox -RegistryOverrides @{ 'deepseek-flash' = @{ max_bundle_bytes = 4096 } }
        try {
            $r = Invoke-EraInSandbox -Box $box -ExtraArgs @('-PremiseCheck')
            $r.Exit | Should -Be 1
            $r.Text | Should -Match 'Premise check appended'

            $bundle = Get-ChildItem -LiteralPath (Join-Path $box.Repo '.external-reviews/wiring') -Filter 'round-*-bundle.xml' |
                        Select-Object -First 1
            $bundle | Should -Not -BeNullOrEmpty -Because 'repomix must have run before the gate refused'
            $text = Get-Content -Raw -LiteralPath $bundle.FullName
            $text | Should -Match 'Premise check \(required'
            $text | Should -Match 'Which numbers here were never measured'
            $text | Should -Match 'would still pass if the thing they cover were broken'
        } finally { Remove-Item -LiteralPath $box.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'leaves the bundle untouched when -PremiseCheck is not passed' {
        $box = New-EraSandbox -RegistryOverrides @{ 'deepseek-flash' = @{ max_bundle_bytes = 4096 } }
        try {
            $null = Invoke-EraInSandbox -Box $box
            $bundle = Get-ChildItem -LiteralPath (Join-Path $box.Repo '.external-reviews/wiring') -Filter 'round-*-bundle.xml' |
                        Select-Object -First 1
            (Get-Content -Raw -LiteralPath $bundle.FullName) | Should -Not -Match 'Premise check \(required'
        } finally { Remove-Item -LiteralPath $box.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'era.ps1 carries the delivery keys into the registry hash it dispatches with' {
        # Belt and braces for the exact omission: the projection is explicit, so a
        # future field added to _registry.json is dropped unless named here too.
        $src = Get-Content -Raw (Join-Path $script:SkillRoot 'runtimes/era.ps1')
        $src | Should -Match 'max_bundle_bytes\s*=\s*\$_\.Value\.max_bundle_bytes'
        $src | Should -Match 'max_bundle_tokens\s*=\s*\$_\.Value\.max_bundle_tokens'
    }
}
