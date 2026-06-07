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
