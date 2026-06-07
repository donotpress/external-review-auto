BeforeAll {
    . (Join-Path (Split-Path $PSScriptRoot -Parent) 'workflow.ps1')
}

Describe 'Test-SlugPerRoundPattern' {
    BeforeEach {
        $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "era-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Recurse -Force $script:tempDir -ErrorAction SilentlyContinue
    }

    It 'detects slug-r2 sibling' {
        New-Item -ItemType Directory -Path (Join-Path $script:tempDir 'my-spec') | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:tempDir 'my-spec-r2') | Out-Null
        $result = Test-SlugPerRoundPattern -ExternalReviewsDir $script:tempDir -TopicSlug 'my-spec'
        $result | Should -Match 'related topics.*my-spec-r2'
    }

    It 'detects slug-round3 sibling' {
        New-Item -ItemType Directory -Path (Join-Path $script:tempDir 'my-spec') | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:tempDir 'my-spec-round3') | Out-Null
        $result = Test-SlugPerRoundPattern -ExternalReviewsDir $script:tempDir -TopicSlug 'my-spec'
        $result | Should -Match 'related topics.*my-spec-round3'
    }

    It 'does NOT detect unrelated slug' {
        New-Item -ItemType Directory -Path (Join-Path $script:tempDir 'my-spec') | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:tempDir 'my-spec-followup') | Out-Null
        $result = Test-SlugPerRoundPattern -ExternalReviewsDir $script:tempDir -TopicSlug 'my-spec'
        $result | Should -BeNullOrEmpty
    }

    It 'returns null when no siblings exist' {
        New-Item -ItemType Directory -Path (Join-Path $script:tempDir 'my-spec') | Out-Null
        $result = Test-SlugPerRoundPattern -ExternalReviewsDir $script:tempDir -TopicSlug 'my-spec'
        $result | Should -BeNullOrEmpty
    }
}

Describe 'Test-ConvergenceDivergence' {
    BeforeEach {
        $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "era-conv-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null
    }
    AfterEach {
        Remove-Item -Recurse -Force $script:tempDir -ErrorAction SilentlyContinue
    }

    It 'emits round-count warning at round 5' {
        $result = Test-ConvergenceDivergence -ReviewDir $script:tempDir -Round 5 -CurrentResponseChars 1000
        $matched = $result | Where-Object { $_ -match 'Round 5.*typical convergence' }
        $matched | Should -Not -BeNullOrEmpty
    }

    It 'does NOT emit round-count warning at round 4' {
        $result = Test-ConvergenceDivergence -ReviewDir $script:tempDir -Round 4 -CurrentResponseChars 1000
        $matched = $result | Where-Object { $_ -match 'typical convergence' }
        $matched | Should -BeNullOrEmpty
    }

    It 'emits response-growth warning when >20% vs round 1' {
        $r1Meta = @{ round = 1; reviewers = @(@{ response_chars = 1000; content_ok = $true }) }
        $r1Meta | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $script:tempDir 'round-1-metadata.json') -Encoding utf8
        $result = Test-ConvergenceDivergence -ReviewDir $script:tempDir -Round 3 -CurrentResponseChars 1300
        $matched = $result | Where-Object { $_ -match 'since round 1' }
        $matched | Should -Not -BeNullOrEmpty
    }

    It 'does NOT emit response-growth warning when <20% vs round 1' {
        $r1Meta = @{ round = 1; reviewers = @(@{ response_chars = 1000; content_ok = $true }) }
        $r1Meta | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $script:tempDir 'round-1-metadata.json') -Encoding utf8
        $result = Test-ConvergenceDivergence -ReviewDir $script:tempDir -Round 3 -CurrentResponseChars 1100
        $matched = $result | Where-Object { $_ -match 'since round 1' }
        $matched | Should -BeNullOrEmpty
    }

    It 'emits round-over-round growth warning when >10% vs prior' {
        $priorMeta = @{ round = 4; reviewers = @(@{ response_chars = 2000; content_ok = $true }) }
        $priorMeta | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $script:tempDir 'round-4-metadata.json') -Encoding utf8
        $result = Test-ConvergenceDivergence -ReviewDir $script:tempDir -Round 5 -CurrentResponseChars 2300
        $matched = $result | Where-Object { $_ -match 'since round 4' }
        $matched | Should -Not -BeNullOrEmpty
    }

    It 'skips signal B silently when round-1 metadata is missing' {
        $result = Test-ConvergenceDivergence -ReviewDir $script:tempDir -Round 3 -CurrentResponseChars 5000
        $matched = $result | Where-Object { $_ -match 'since round 1' }
        $matched | Should -BeNullOrEmpty
    }

    It 'skips signal B silently when round-1 metadata is malformed' {
        Set-Content (Join-Path $script:tempDir 'round-1-metadata.json') -Value 'NOT JSON' -Encoding utf8
        $result = Test-ConvergenceDivergence -ReviewDir $script:tempDir -Round 3 -CurrentResponseChars 5000
        $matched = $result | Where-Object { $_ -match 'since round 1' }
        $matched | Should -BeNullOrEmpty
    }

    It 'is suppressed by ERA_CONVERGENCE_WARNINGS=0' {
        $r1Meta = @{ round = 1; reviewers = @(@{ response_chars = 100; content_ok = $true }) }
        $r1Meta | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $script:tempDir 'round-1-metadata.json') -Encoding utf8
        $env:ERA_CONVERGENCE_WARNINGS = '0'
        try {
            $result = Test-ConvergenceDivergence -ReviewDir $script:tempDir -Round 10 -CurrentResponseChars 9999
            $result | Should -HaveCount 0
        } finally {
            Remove-Item Env:\ERA_CONVERGENCE_WARNINGS -ErrorAction SilentlyContinue
        }
    }
}
