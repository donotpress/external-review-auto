# PR-D tests: portable Layer-1 resolver (runtimes/resolve.ps1) + the Layer-2
# extraction acceptance test (Resolve-ModelFromHint) + the resolve.ps1<->era.ps1
# param contract test (so the two cannot silently drift).

BeforeAll {
    $script:SkillRoot   = Split-Path $PSScriptRoot -Parent
    $script:ResolvePath = Join-Path $script:SkillRoot 'runtimes/resolve.ps1'
    $script:EraPath     = Join-Path $script:SkillRoot 'runtimes/era.ps1'
    $script:RegPath     = Join-Path $script:SkillRoot 'backends/_registry.json'
    $script:Registry    = Get-Content -Raw $script:RegPath | ConvertFrom-Json

    # Invoke resolve.ps1 via a positional arg and parse its stdout as JSON.
    # The contract is: stdout is ONLY the JSON object (nothing else).
    # Hermetic against a machine-set $env:ERA_DEFAULT_REVIEWER: the env var is
    # cleared for the child fork by default (so default-reviewer assertions hold
    # regardless of the dev's machine), and set explicitly only when a test passes
    # -EnvDefault. The prior value is always restored.
    function script:Invoke-Resolve {
        param([string]$InputText, [string]$EnvDefault)
        $prior = $env:ERA_DEFAULT_REVIEWER
        try {
            if ($PSBoundParameters.ContainsKey('EnvDefault')) { $env:ERA_DEFAULT_REVIEWER = $EnvDefault }
            else { Remove-Item Env:\ERA_DEFAULT_REVIEWER -ErrorAction SilentlyContinue }
            $out = pwsh -NoProfile -File $script:ResolvePath $InputText 2>$null
            $raw = ($out -join "`n").Trim()
            return ($raw | ConvertFrom-Json)
        } finally {
            if ($null -ne $prior) { $env:ERA_DEFAULT_REVIEWER = $prior }
            else { Remove-Item Env:\ERA_DEFAULT_REVIEWER -ErrorAction SilentlyContinue }
        }
    }
}

# --- D.0 acceptance test: Layer-2 extraction is behavior-preserving ----------
Describe 'Resolve-ModelFromHint (Layer-2 extraction, D.0)' {
    BeforeAll {
        . (Join-Path $script:SkillRoot 'runtimes/resolve-model.ps1')
    }

    It 'resolves exact mimo-v2.5 to itself (NOT shadowed by mimo-v2.5-pro)' {
        # The classic shorter-canonical-of-longer two-pass trap: with a naive
        # single-pass substring match, 'mimo-v2.5' would match 'mimo-v2.5-pro'
        # (the longer canonical contains the shorter). The exact-first pass must
        # win and pin it to mimo-v2.5.
        $r = Resolve-ModelFromHint -Hint 'mimo-v2.5' -Registry $script:Registry
        $r.ModelId  | Should -BeExactly 'opencode-go/mimo-v2.5'
        $r.Provider | Should -BeExactly 'opencode-go'
    }

    It 'resolves mimo-v2.5-pro to itself' {
        $r = Resolve-ModelFromHint -Hint 'mimo-v2.5-pro' -Registry $script:Registry
        $r.ModelId | Should -BeExactly 'opencode-go/mimo-v2.5-pro'
    }

    It 'pins gemini 3.1 pro low to the low tier (explicit tier wins)' {
        $r = Resolve-ModelFromHint -Hint 'gemini 3.1 pro low' -Registry $script:Registry
        $r.ModelId  | Should -BeExactly 'Gemini 3.1 Pro (Low)'
        $r.Provider | Should -BeExactly 'agy'
    }

    It 'resolves opus to the claude opus model' {
        $r = Resolve-ModelFromHint -Hint 'opus' -Registry $script:Registry
        $r.ModelId  | Should -BeExactly 'claude-opus-4-7'
        $r.Provider | Should -BeExactly 'claude'
    }

    It 'returns $null for unmatched hints' {
        Resolve-ModelFromHint -Hint 'totally-bogus-zzz' -Registry $script:Registry | Should -BeNullOrEmpty
    }

    It 'returns $null for empty hint' {
        Resolve-ModelFromHint -Hint '' -Registry $script:Registry | Should -BeNullOrEmpty
    }
}

# --- D.1: documented /era patterns -> typed flags ----------------------------
Describe 'resolve.ps1 Layer-1 pattern resolution' {
    It 'bare/empty input (explicit empty positional arg) -> default gemini-pro-low without reading stdin' {
        # Invoke-Resolve '' runs `pwsh -File resolve.ps1 ''` — an EXPLICIT empty
        # positional arg. resolve.ps1 must treat this as empty input and return
        # the DEFAULT without ever calling [Console]::In.ReadToEnd(). Were it to
        # read stdin here, any non-interactive/CI context (open, non-EOF inherited
        # stdin) would BLOCK FOREVER and hang the whole suite. The fix keys the
        # stdin read on $PSBoundParameters.ContainsKey('InputText') (False only
        # when the arg is omitted), so an explicit '' never touches stdin.
        $r = script:Invoke-Resolve ''
        $r.Reviewer  | Should -BeExactly 'gemini-pro-low'
        $r.TopicSlug | Should -BeNullOrEmpty
    }

    It 'gemini -> -Reviewer gemini' {
        $r = script:Invoke-Resolve 'gemini'
        $r.Reviewer | Should -BeExactly 'gemini'
    }

    It 'flash -> -Reviewer gemini' {
        $r = script:Invoke-Resolve 'flash'
        $r.Reviewer | Should -BeExactly 'gemini'
    }

    It 'gemini 3.1 pro -> -Reviewer gemini-pro-high' {
        $r = script:Invoke-Resolve 'gemini 3.1 pro'
        $r.Reviewer | Should -BeExactly 'gemini-pro-high'
    }

    It 'gemini 3.1 pro low -> -Reviewer gemini-pro-low' {
        $r = script:Invoke-Resolve 'gemini 3.1 pro low'
        $r.Reviewer | Should -BeExactly 'gemini-pro-low'
    }

    It 'gemini 3.1 pro budget -> -Reviewer gemini-pro-low' {
        $r = script:Invoke-Resolve 'gemini 3.1 pro budget'
        $r.Reviewer | Should -BeExactly 'gemini-pro-low'
    }

    It 'opus -> -Reviewer opus' {
        $r = script:Invoke-Resolve 'opus'
        $r.Reviewer | Should -BeExactly 'opus'
    }

    It 'claude opus -> -Reviewer opus' {
        $r = script:Invoke-Resolve 'claude opus'
        $r.Reviewer | Should -BeExactly 'opus'
    }

    It 'sonnet -> -Reviewer sonnet' {
        $r = script:Invoke-Resolve 'sonnet'
        $r.Reviewer | Should -BeExactly 'sonnet'
    }

    It 'claude (family alone) -> -Reviewer opus (family -> top model)' {
        $r = script:Invoke-Resolve 'claude'
        $r.Reviewer | Should -BeExactly 'opus'
    }

    It 'deepseek -> -Reviewer deepseek' {
        $r = script:Invoke-Resolve 'deepseek'
        $r.Reviewer | Should -BeExactly 'deepseek'
    }

    It 'deepseek v4 flash -> -Reviewer deepseek -Model opencode-go/deepseek-v4-flash' {
        $r = script:Invoke-Resolve 'deepseek v4 flash'
        $r.Reviewer | Should -BeExactly 'deepseek'
        $r.Model    | Should -BeExactly 'opencode-go/deepseek-v4-flash'
    }

    It 'deepseek v4 pro -> -Reviewer deepseek -Model opencode-go/deepseek-v4-pro' {
        $r = script:Invoke-Resolve 'deepseek v4 pro'
        $r.Reviewer | Should -BeExactly 'deepseek'
        $r.Model    | Should -BeExactly 'opencode-go/deepseek-v4-pro'
    }

    It 'minimax -> -Reviewer minimax -Model minimax/MiniMax-M2.7 (latest minor wins)' {
        $r = script:Invoke-Resolve 'minimax'
        $r.Reviewer | Should -BeExactly 'minimax'
        $r.Model    | Should -BeExactly 'minimax/MiniMax-M2.7'
    }

    It 'gemini api -> -Reviewer gemini-api' {
        $r = script:Invoke-Resolve 'gemini api'
        $r.Reviewer | Should -BeExactly 'gemini-api'
    }

    It 'opus api -> -Reviewer opus-api' {
        $r = script:Invoke-Resolve 'opus api'
        $r.Reviewer | Should -BeExactly 'opus-api'
    }

    It 'strips filler words (use / the / please)' {
        $r = script:Invoke-Resolve 'please use the opus model'
        $r.Reviewer | Should -BeExactly 'opus'
    }
}

# --- D.1: topic-slug vs reviewer disambiguation ------------------------------
Describe 'resolve.ps1 topic-slug vs reviewer disambiguation' {
    It 'a topic-slug-only input -> -TopicSlug <slug>, default reviewer' {
        $r = script:Invoke-Resolve 'my-cool-feature'
        $r.TopicSlug | Should -BeExactly 'my-cool-feature'
        $r.Reviewer  | Should -BeExactly 'gemini-pro-low'
    }

    It '<slug> use opus -> -TopicSlug <slug> -Reviewer opus' {
        $r = script:Invoke-Resolve 'console-bugs use opus'
        $r.TopicSlug | Should -BeExactly 'console-bugs'
        $r.Reviewer  | Should -BeExactly 'opus'
    }

    It '<slug> use deepseek v4 flash -> slug + reviewer + model' {
        $r = script:Invoke-Resolve 'rebalance-spec use deepseek v4 flash'
        $r.TopicSlug | Should -BeExactly 'rebalance-spec'
        $r.Reviewer  | Should -BeExactly 'deepseek'
        $r.Model     | Should -BeExactly 'opencode-go/deepseek-v4-flash'
    }

    It 'splits on the LAST "use" so an interior "use" in the topic survives (round-4 nit)' {
        # "<topic> use <reviewer>" — the reviewer spec is the tail, so the splitter
        # must break on the LAST "use". Splitting on the first "use" mis-routed
        # "of deprecated api" into reviewer resolution and dropped most of the topic.
        $r = script:Invoke-Resolve 'fix use of deprecated api use gemini'
        $r.TopicSlug | Should -BeExactly 'fix-use-of-deprecated-api'
        $r.Reviewer  | Should -BeExactly 'gemini'
    }

    It 'a bare "reasoner" hint resolves to the DeepSeek reasoner (round-5 nit)' {
        # 'reasoner' is in $reviewerKeywords, so it is treated as a reviewer-first
        # token; it must therefore resolve, not fall through to {error:unresolved}.
        $r = script:Invoke-Resolve 'reasoner'
        $r.error    | Should -BeNullOrEmpty
        $r.Reviewer | Should -BeLike 'deepseek*'
    }

    It 'a "reasoner pro" hint stays in the DeepSeek family, not gemini (attach-review nit)' {
        # 'reasoner' must be in the gemini branch's noOtherFamily guard, else a
        # tier word ('pro'/'flash') alongside 'reasoner' wrongly captures the
        # gemini branch before the deepseek/reasoner block is reached.
        $r = script:Invoke-Resolve 'reasoner pro'
        $r.Reviewer | Should -BeLike 'deepseek*'
    }

    It 'a reviewer keyword first -> NO TopicSlug (whole tail is reviewer spec)' {
        $r = script:Invoke-Resolve 'gemini 3.1 pro'
        $r.TopicSlug | Should -BeNullOrEmpty
    }

    It 'bare input uses the shipped default (gemini-pro-low) when the env var is unset' {
        (script:Invoke-Resolve '').Reviewer | Should -BeExactly 'gemini-pro-low'
    }
    It 'bare input honors $env:ERA_DEFAULT_REVIEWER' {
        (script:Invoke-Resolve '' -EnvDefault 'gemini-pro-high').Reviewer | Should -BeExactly 'gemini-pro-high'
    }
    It 'a topic-slug-only input honors $env:ERA_DEFAULT_REVIEWER too' {
        $r = script:Invoke-Resolve 'my-feature' -EnvDefault 'gemini-pro-high'
        $r.TopicSlug | Should -BeExactly 'my-feature'
        $r.Reviewer  | Should -BeExactly 'gemini-pro-high'
    }

    # --- Regression (Fix #1): a topic slug whose first word merely CONTAINS a
    # reviewer keyword must NOT be misrouted to reviewer-spec resolution (which
    # fails -> unresolved). First-token reviewer detection is an EXACT word match,
    # not a substring -like. Short keywords (pro/api/flash) are common substrings.
    It "topic slug 'improvement-plan' (contains 'pro') -> TopicSlug + default reviewer, NOT unresolved" {
        $r = script:Invoke-Resolve 'improvement-plan'
        $r.error     | Should -BeNullOrEmpty
        $r.TopicSlug | Should -BeExactly 'improvement-plan'
        $r.Reviewer  | Should -BeExactly 'gemini-pro-low'
    }

    It "topic slug 'proxy-config' (contains 'pro') -> TopicSlug + default reviewer, NOT unresolved" {
        $r = script:Invoke-Resolve 'proxy-config'
        $r.error     | Should -BeNullOrEmpty
        $r.TopicSlug | Should -BeExactly 'proxy-config'
        $r.Reviewer  | Should -BeExactly 'gemini-pro-low'
    }

    It "topic slug 'approve-button-spec' (contains 'pro') -> TopicSlug + default reviewer, NOT unresolved" {
        $r = script:Invoke-Resolve 'approve-button-spec'
        $r.error     | Should -BeNullOrEmpty
        $r.TopicSlug | Should -BeExactly 'approve-button-spec'
        $r.Reviewer  | Should -BeExactly 'gemini-pro-low'
    }

    It "topic slug 'api-gateway-spec' (contains 'api') -> TopicSlug + default reviewer, NOT unresolved" {
        $r = script:Invoke-Resolve 'api-gateway-spec'
        $r.error     | Should -BeNullOrEmpty
        $r.TopicSlug | Should -BeExactly 'api-gateway-spec'
        $r.Reviewer  | Should -BeExactly 'gemini-pro-low'
    }

    It "topic slug 'geminify-the-thing' (contains 'gemini') -> TopicSlug + default reviewer, NOT unresolved" {
        $r = script:Invoke-Resolve 'geminify-the-thing'
        $r.error     | Should -BeNullOrEmpty
        $r.TopicSlug | Should -BeExactly 'geminify-the-thing'
        $r.Reviewer  | Should -BeExactly 'gemini-pro-low'
    }

    # Guard: exact reviewer keywords still resolve as reviewer specs (no regression).
    It "exact keyword 'gemini' still resolves as a reviewer (no TopicSlug)" {
        $r = script:Invoke-Resolve 'gemini'
        $r.TopicSlug | Should -BeNullOrEmpty
        $r.Reviewer  | Should -BeExactly 'gemini'
    }

    # --- Regression (Fix #5): interior filler words are preserved in topic slugs.
    # Only LEADING filler is stripped; 'the' in the middle must survive.
    It "topic slug 'fix the login bug' preserves interior filler -> 'fix-the-login-bug'" {
        $r = script:Invoke-Resolve 'fix the login bug'
        $r.error     | Should -BeNullOrEmpty
        $r.TopicSlug | Should -BeExactly 'fix-the-login-bug'
        $r.Reviewer  | Should -BeExactly 'gemini-pro-low'
    }
}

# --- D.1: unmatched / ambiguous input ----------------------------------------
Describe 'resolve.ps1 unmatched input' {
    It 'a slug followed by an unknown model after use -> topic slug (tail has no reviewer keyword)' {
        $r = script:Invoke-Resolve 'some-slug use wat-is-this-model'
        $r.TopicSlug | Should -BeExactly 'some-slug-use-wat-is-this-model'
        $r.Reviewer | Should -BeExactly 'gemini-pro-low'
    }
}

# --- D.1: stdin input parity -------------------------------------------------
Describe 'resolve.ps1 stdin input' {
    It 'accepts input piped via stdin' {
        $raw = ('opus' | pwsh -NoProfile -File $script:ResolvePath 2>$null) -join "`n"
        $r = $raw.Trim() | ConvertFrom-Json
        $r.Reviewer | Should -BeExactly 'opus'
    }

    It 'no-arg + empty redirected stdin does not hang -> default reviewer' {
        # The no-arg path is the intended "agent pipes input" route and DOES read
        # stdin when redirected. To prove it cannot hang the suite, feed it a
        # redirected EMPTY file (immediate EOF) via Start-Process
        # -RedirectStandardInput rather than relying on an interactive/open
        # stdin. ReadToEnd() returns '' instantly -> default.
        $tmp = [System.IO.Path]::GetTempPath()
        $emptyFile = Join-Path $tmp "era-empty-stdin-$([guid]::NewGuid()).txt"
        $outFile   = Join-Path $tmp "era-resolve-out-$([guid]::NewGuid()).txt"
        Set-Content -Path $emptyFile -Value '' -NoNewline
        # Hermetic: this Start-Process fork inherits env, so clear a machine-set
        # ERA_DEFAULT_REVIEWER to assert the SHIPPED default; restore after.
        $priorDefault = $env:ERA_DEFAULT_REVIEWER
        Remove-Item Env:\ERA_DEFAULT_REVIEWER -ErrorAction SilentlyContinue
        try {
            Start-Process -FilePath 'pwsh' `
                -ArgumentList @('-NoProfile', '-File', $script:ResolvePath) `
                -RedirectStandardInput $emptyFile `
                -RedirectStandardOutput $outFile `
                -NoNewWindow -Wait
            $raw = (Get-Content -Raw $outFile)
        } finally {
            Remove-Item $emptyFile, $outFile -Force -ErrorAction SilentlyContinue
            if ($null -ne $priorDefault) { $env:ERA_DEFAULT_REVIEWER = $priorDefault }
            else { Remove-Item Env:\ERA_DEFAULT_REVIEWER -ErrorAction SilentlyContinue }
        }
        $r = $raw.Trim() | ConvertFrom-Json
        $r.Reviewer | Should -BeExactly 'gemini-pro-low'
    }
}

# --- D.1: stdout purity ------------------------------------------------------
Describe 'resolve.ps1 stdout is ONLY JSON' {
    It 'stdout parses cleanly as a single JSON object' {
        $raw = (pwsh -NoProfile -File $script:ResolvePath 'gemini 3.1 pro' 2>$null) -join "`n"
        { $raw.Trim() | ConvertFrom-Json } | Should -Not -Throw
        ($raw.Trim() | ConvertFrom-Json).Reviewer | Should -BeExactly 'gemini-pro-high'
    }
}

# --- D.1: CONTRACT test (R1-OQ1 + R2-I5) -------------------------------------
Describe 'resolve.ps1 to era.ps1 parameter contract' {
    BeforeAll {
        # Resolve era.ps1's parameters via Get-Command on the resolved path
        # (R4-Gemini-I1: path via $PSScriptRoot/skill root, NOT hardcoded).
        $script:EraParams = (Get-Command $script:EraPath).Parameters.Keys
        . (Join-Path $script:SkillRoot 'runtimes/resolve-model.ps1')

        # Exercise resolve.ps1 across the full documented pattern set and collect
        # every flag KEY and every -Model/-Reviewer VALUE it can emit.
        # NB: do NOT include '' here — an empty positional arg collapses under
        # `pwsh -File` and (when stdin is redirected, as under Pester) the child
        # would read the parent's stdin. The bare/empty case is covered by the
        # 'bare/empty input' pattern test which pipes empty stdin explicitly.
        #
        # R-coverage (Fix #2): the original set never exercised 5 presets
        # resolve.ps1 CAN emit (sonnet-api, haiku-api, deepseek-api,
        # deepseek-reasoner-api, minimax-api), so a rename/removal of any of
        # those in _registry.json would slip past the contract assertions while
        # breaking /era. We add inputs that drive each. 'deepseek reasoner' is
        # env-gated: with $env:DEEPSEEK_API_KEY set it emits the
        # 'deepseek-reasoner-api' preset (no -Model); unset it emits
        # {Reviewer=deepseek, Model=opencode-go/deepseek-reasoner}. We set the key
        # within this test scope so the *-api preset is exercised deterministically
        # (child pwsh inherits the env var).
        $script:SampleInputs = @(
            'gemini', 'flash', 'gemini 3.1 pro', 'gemini 3.1 pro low',
            'opus', 'claude opus', 'sonnet', 'haiku', 'claude', 'deepseek',
            'deepseek v4 flash', 'deepseek v4 pro', 'minimax', 'gemini api',
            'opus api', 'my-topic-slug', 'console-bugs use opus',
            'rebalance use deepseek v4 flash',
            # Fix #2: exercise the previously-uncovered emittable presets.
            'sonnet api', 'haiku api', 'deepseek api', 'deepseek reasoner',
            'minimax api'
        )
        $script:EmittedKeys     = [System.Collections.Generic.HashSet[string]]::new()
        $script:EmittedReviewers = [System.Collections.Generic.HashSet[string]]::new()
        $script:EmittedModels    = [System.Collections.Generic.HashSet[string]]::new()
        $priorDeepseekKey = $env:DEEPSEEK_API_KEY
        $env:DEEPSEEK_API_KEY = 'contract-test-key'
        try {
            foreach ($inp in $script:SampleInputs) {
                $out = (pwsh -NoProfile -File $script:ResolvePath $inp 2>$null) -join "`n"
                $obj = $out.Trim() | ConvertFrom-Json
                if ($obj.PSObject.Properties.Name -contains 'error') { continue }
                foreach ($p in $obj.PSObject.Properties.Name) { [void]$script:EmittedKeys.Add($p) }
                if ($obj.Reviewer) { [void]$script:EmittedReviewers.Add($obj.Reviewer) }
                if ($obj.Model)    { [void]$script:EmittedModels.Add($obj.Model) }
            }
        } finally {
            if ($null -eq $priorDeepseekKey) {
                Remove-Item Env:DEEPSEEK_API_KEY -ErrorAction SilentlyContinue
            } else {
                $env:DEEPSEEK_API_KEY = $priorDeepseekKey
            }
        }

        $script:RegHash = @{}
        $script:Registry.PSObject.Properties | Where-Object { $_.Name -notlike '_*' } | ForEach-Object {
            $script:RegHash[$_.Name] = $_.Value
        }
    }

    It 'every flag key resolve.ps1 emits is a real era.ps1 parameter' {
        foreach ($k in $script:EmittedKeys) {
            $script:EraParams | Should -Contain $k -Because "resolve.ps1 emitted flag '$k' which must be an era.ps1 parameter"
        }
    }

    It 'every -Reviewer value resolve.ps1 emits is a real registry preset' {
        foreach ($r in $script:EmittedReviewers) {
            $script:RegHash.ContainsKey($r) | Should -BeTrue -Because "resolve.ps1 emitted -Reviewer '$r' which must exist in _registry.json"
        }
    }

    It 'the contract sample set actually exercises the *-api presets (drift guard, Fix #2)' {
        # Without these inputs the contract assertions never cover these presets,
        # so a rename/removal in _registry.json would pass while breaking /era.
        foreach ($preset in @('sonnet-api', 'haiku-api', 'deepseek-api',
                'deepseek-reasoner-api', 'minimax-api')) {
            $script:EmittedReviewers.Contains($preset) | Should -BeTrue -Because "the sample set must drive resolve.ps1 to emit -Reviewer '$preset' so the registry-preset contract covers it"
        }
    }

    It 'every -Model value resolve.ps1 emits resolves to a non-null model via era.ps1 Layer-2' {
        foreach ($m in $script:EmittedModels) {
            $res = Resolve-ModelFromHint -Hint $m -Registry $script:Registry
            $res | Should -Not -BeNullOrEmpty -Because "resolve.ps1 emitted -Model '$m' which era.ps1's Layer-2 must resolve"
        }
    }
}
