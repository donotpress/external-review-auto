# Tests for the repomix ignore patterns that keep era's OWN review artifacts out
# of the bundle it is about to send to a third-party API.
#
# Background (2026-08-09): era.ps1's repomix config set useGitignore=$false and
# useDefaultPatterns=$false with only six customPatterns, none of which covered
# '.external-reviews/'. On the default-glob path ('**/*.md', '**/*.json', ...) a
# bundle therefore matched every PRIOR round's prompt and response, the manifests
# and metadata (which carry Stderr), and round-N-external/HOME/... staged copies
# pulled from ~/.claude. Round N re-transmitted round N-1 to the reviewer API.
#
# The measurement tests below run REAL repomix against a synthetic repo and
# assert on the file paths that actually landed in the bundle -- not on the
# config we asked for.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/ReviewArtifactIgnore.Tests.ps1"

# Evaluated at DISCOVERY time: Pester 5 resolves -Skip: before BeforeAll runs, so
# a $script: variable set inside BeforeAll would still be $null here and silently
# skip the measurement tests.
$script:HasRepomix = $null -ne (Get-Command repomix -ErrorAction SilentlyContinue)

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    $script:EraPath   = Join-Path $script:SkillRoot 'runtimes/era.ps1'

    # The six patterns era.ps1 has always carried, independent of the artifact
    # ignore set. Kept here so the measurement mirrors the real config shape.
    $script:BasePatterns = @(
        'node_modules/**', '.git/**', '__pycache__/**', '*.pyc', '*.duckdb',
        'validation_results/**/*.db'
    )

    function New-ArtifactRepo {
        <#
            Builds a repo that looks like one era has already reviewed twice:
            a real source file, a PRIOR round's prompt/response/manifest, an
            unrelated topic's artifacts, and a CURRENT round staging dir holding
            an out-of-repo file era copied in (the P6 mirror, era.ps1:1112).
        #>
        param([string]$Root, [string]$TopicSlug = 'current-topic', [int]$Round = 2)
        New-Item -ItemType Directory -Path (Join-Path $Root '.git') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Root 'src') -Force | Out-Null
        Set-Content -Path (Join-Path $Root 'src/app.md') -Value '# in-repo source'

        $topicDir = Join-Path $Root ".external-reviews/$TopicSlug"
        New-Item -ItemType Directory -Path $topicDir -Force | Out-Null
        Set-Content -Path (Join-Path $topicDir 'round-1-prompt.md')   -Value 'PRIOR-PROMPT-LEAK'
        Set-Content -Path (Join-Path $topicDir 'round-1-response.md') -Value 'PRIOR-RESPONSE-LEAK'
        Set-Content -Path (Join-Path $topicDir 'round-1-manifest.json') -Value '{"stderr":"MANIFEST-LEAK"}'
        Set-Content -Path (Join-Path $topicDir 'round-1-metadata.json') -Value '{"Stderr":"METADATA-LEAK"}'

        # A previous round's staged out-of-repo copy -- the shape that pulled
        # ~/.claude sources into a later round's bundle.
        $priorStage = Join-Path $topicDir 'round-1-external/HOME/.claude/skills'
        New-Item -ItemType Directory -Path $priorStage -Force | Out-Null
        Set-Content -Path (Join-Path $priorStage 'OLD-SKILL.md') -Value 'PRIOR-STAGED-LEAK'

        # An unrelated topic's artifacts.
        $otherDir = Join-Path $Root '.external-reviews/other-topic'
        New-Item -ItemType Directory -Path $otherDir -Force | Out-Null
        Set-Content -Path (Join-Path $otherDir 'round-7-response.md') -Value 'OTHER-TOPIC-LEAK'

        # THIS round's staging dir: files the caller explicitly asked for.
        $curStage = Join-Path $topicDir "round-$Round-external/HOME/.claude/skills"
        New-Item -ItemType Directory -Path $curStage -Force | Out-Null
        Set-Content -Path (Join-Path $curStage 'SKILL.md') -Value 'CURRENT-STAGED-FILE'
    }

    function Measure-BundledPaths {
        <#
            Writes a repomix config exactly the way era.ps1 does, runs repomix
            for real, and returns the file paths repomix actually emitted.
        #>
        param([string]$Root, [string[]]$Include, [string[]]$IgnorePatterns)
        $cfg    = Join-Path $Root 'probe-config.json'
        $bundle = Join-Path $Root 'probe-bundle.xml'
        @{
            output = @{ filePath = $bundle; style = 'xml'; showLineNumbers = $true }
            include = $Include
            ignore = @{
                useGitignore = $false
                useDefaultPatterns = $false
                customPatterns = $IgnorePatterns
            }
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $cfg -Encoding utf8

        Push-Location $Root
        try { $null = repomix -c $cfg 2>&1 } finally { Pop-Location }

        $txt = if (Test-Path $bundle) { Get-Content -Raw $bundle } else { '' }
        @([regex]::Matches($txt, '<file path="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    }
}

Describe 'Get-EraReviewArtifactIgnorePatterns' -Tag Unit {
    It 'blanket-ignores .external-reviews when no out-of-repo staging is in play' {
        $p = Get-EraReviewArtifactIgnorePatterns -RepoRoot 'C:\nope' -TopicSlug 't' -Round 1
        $p | Should -Contain '.external-reviews/**'
    }

    It 'still returns the blanket pattern when the repo has no .external-reviews yet' {
        $tmp = Join-Path $env:TEMP "era-ign-fresh-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $p = Get-EraReviewArtifactIgnorePatterns -RepoRoot $tmp -TopicSlug 't' -Round 1 -AllowStaging
            $p | Should -Contain '.external-reviews/**'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'carves out ONLY the current round staging dir when staging is in play' {
        $tmp = Join-Path $env:TEMP "era-ign-carve-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            New-ArtifactRepo -Root $tmp -TopicSlug 'current-topic' -Round 2
            $p = Get-EraReviewArtifactIgnorePatterns -RepoRoot $tmp -TopicSlug 'current-topic' -Round 2 -AllowStaging
            # The blanket must NOT be present -- it would swallow the staging dir.
            $p | Should -Not -Contain '.external-reviews/**'
            # Unrelated topics are ignored wholesale.
            $p | Should -Contain '.external-reviews/other-topic/**'
            # The current topic's own round artifacts are ignored by shape.
            $p | Should -Contain '.external-reviews/current-topic/*.*'
            # A PRIOR round's staging dir is ignored...
            $p | Should -Contain '.external-reviews/current-topic/round-1-external/**'
            # ...while THIS round's staging dir is never named as an ignore.
            $p | Should -Not -Contain '.external-reviews/current-topic/round-2-external/**'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }
}

Describe 'Bundle contents (real repomix measurement)' -Tag Integration -Skip:(-not $script:HasRepomix) {
    It 'default-glob bundle contains NO .external-reviews path' {
        $tmp = Join-Path $env:TEMP "era-ign-glob-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            New-ArtifactRepo -Root $tmp -TopicSlug 'current-topic' -Round 2
            $ignore = $script:BasePatterns +
                      (Get-EraReviewArtifactIgnorePatterns -RepoRoot $tmp -TopicSlug 'current-topic' -Round 2)
            $paths = Measure-BundledPaths -Root $tmp -Include @('**/*.md', '**/*.json') -IgnorePatterns $ignore

            # The point of the fix, asserted by measurement.
            @($paths | Where-Object { $_ -like '*.external-reviews*' }) | Should -BeNullOrEmpty
            # And the bundle is not simply empty.
            $paths | Should -Contain 'src/app.md'
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }

    It 'staging bundle keeps THIS round''s staged file but drops every other artifact' {
        $tmp = Join-Path $env:TEMP "era-ign-stage-$(New-Guid)"
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            New-ArtifactRepo -Root $tmp -TopicSlug 'current-topic' -Round 2
            $staged = '.external-reviews/current-topic/round-2-external/HOME/.claude/skills/SKILL.md'
            $ignore = $script:BasePatterns +
                      (Get-EraReviewArtifactIgnorePatterns -RepoRoot $tmp -TopicSlug 'current-topic' -Round 2 -AllowStaging)
            # Mirrors the real staging path: explicit include entries, plus a glob
            # a caller might reasonably pass alongside them.
            $paths = Measure-BundledPaths -Root $tmp -Include @('src/app.md', $staged, '**/*.md') -IgnorePatterns $ignore

            $paths | Should -Contain $staged
            $paths | Should -Contain 'src/app.md'
            # Every OTHER .external-reviews path must be gone.
            @($paths | Where-Object { $_ -like '*.external-reviews*' -and $_ -ne $staged }) |
                Should -BeNullOrEmpty
        } finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    }
}

Describe 'era.ps1 wires the artifact ignore into its repomix config' -Tag Unit {
    It 'builds customPatterns from Get-EraReviewArtifactIgnorePatterns, not a bare literal list' {
        $src = Get-Content -Raw $script:EraPath
        $src | Should -Match 'Get-EraReviewArtifactIgnorePatterns'
        # The call must feed customPatterns rather than sit unused.
        $cfgIdx = $src.IndexOf('customPatterns')
        $callIdx = $src.IndexOf('Get-EraReviewArtifactIgnorePatterns')
        $cfgIdx  | Should -BeGreaterThan 0
        $callIdx | Should -BeGreaterThan 0
        # ...and it must be computed before repomix is invoked.
        $callIdx | Should -BeLessThan $src.IndexOf('"Running repomix..."')
    }
}
