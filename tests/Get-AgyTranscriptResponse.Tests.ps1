# Tests for backends/agy.ps1::Get-AgyTranscriptResponse — the highest-risk
# function in the skill. Covers the two-strategy capture: Run-ID/path
# correlation when $DispatchId/$BundlePath are provided (Pass 1 matches the
# echoed Run-ID GUID; Pass 2 falls back to the literal bundle path, anchoring
# only on USER entries), and the legacy new-session-dir + temporal-floor
# (created_at) fallback when neither is provided. Also covers content
# extraction, entry-type filtering, and edge cases.

BeforeAll {
    $script:SkillRoot = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:SkillRoot 'backends/agy.ps1')

    # Helper: build a transcript_full.jsonl with the given entries.
    function New-MockTranscript {
        param(
            [string]$SessionDir,
            [object[]]$Entries
        )
        $logDir = Join-Path $SessionDir '.system_generated/logs'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        $path = Join-Path $logDir 'transcript_full.jsonl'
        $Entries | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 } | Set-Content -Path $path -Encoding utf8
        return $path
    }

    # Helper: build a typical MODEL/PLANNER_RESPONSE entry with content.
    function New-PlannerResponse {
        param([string]$Content, [datetime]$CreatedAt = (Get-Date).ToUniversalTime())
        @{
            source     = 'MODEL'
            type       = 'PLANNER_RESPONSE'
            status     = 'COMPLETED'
            created_at = $CreatedAt.ToString('o')
            content    = $Content
        }
    }

    # Helper: a USER entry carrying the Run-ID GUID (and optionally the bundle path).
    function New-UserEntry {
        param([string]$Text, [datetime]$CreatedAt = (Get-Date).ToUniversalTime())
        @{
            source     = 'USER_EXPLICIT'
            type       = 'USER_INPUT'
            created_at = $CreatedAt.ToString('o')
            content    = $Text
        }
    }
}

Describe 'Get-AgyTranscriptResponse' {
    BeforeEach {
        # Per-test temp brain root so tests don't interfere.
        $script:BrainRoot = Join-Path $TestDrive ("brain-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:BrainRoot -Force | Out-Null
    }

    Context 'Strategy 1: new session dirs (preferred)' {
        It 'returns content from a session dir created after dispatch start' {
            # Pre-existing session
            $oldSession = Join-Path $script:BrainRoot 'old-session-uuid'
            New-MockTranscript -SessionDir $oldSession -Entries @(
                (New-PlannerResponse -Content 'OLD RESPONSE' -CreatedAt (Get-Date).AddHours(-1).ToUniversalTime())
            )
            $preExisting = @{ $oldSession = $true }

            # New session created "after" dispatch
            $newSession = Join-Path $script:BrainRoot 'new-session-uuid'
            New-MockTranscript -SessionDir $newSession -Entries @(
                (New-PlannerResponse -Content 'NEW RESPONSE')
            )

            $result = Get-AgyTranscriptResponse -BrainRoot $script:BrainRoot `
                -PreExistingSessionDirs $preExisting `
                -DispatchStartUtc ([datetime]::UtcNow.AddSeconds(-10)) `
                -MaxAttempts 1 -DelaySeconds 0

            $result.Response | Should -Be 'NEW RESPONSE'
            $result.Strategy | Should -Be 'new-session-dir'
        }

        It 'prefers new session over pre-existing even if pre-existing is more recent' {
            $oldSession = Join-Path $script:BrainRoot 'old-session-uuid'
            New-MockTranscript -SessionDir $oldSession -Entries @(
                (New-PlannerResponse -Content 'OLD BUT RECENTLY UPDATED')
            )
            $preExisting = @{ $oldSession = $true }

            $newSession = Join-Path $script:BrainRoot 'new-session-uuid'
            New-MockTranscript -SessionDir $newSession -Entries @(
                (New-PlannerResponse -Content 'NEW SESSION RESPONSE' -CreatedAt (Get-Date).AddSeconds(-30).ToUniversalTime())
            )

            $result = Get-AgyTranscriptResponse -BrainRoot $script:BrainRoot `
                -PreExistingSessionDirs $preExisting `
                -DispatchStartUtc ([datetime]::UtcNow.AddSeconds(-60)) `
                -MaxAttempts 1 -DelaySeconds 0

            $result.Response | Should -Be 'NEW SESSION RESPONSE'
            $result.Strategy | Should -Be 'new-session-dir'
        }
    }

    Context 'Strategy 2: temporal floor on existing sessions' {
        It 'returns content from a pre-existing session when entry created_at >= dispatch start' {
            $existingSession = Join-Path $script:BrainRoot 'existing-uuid'
            $dispatchStart = (Get-Date).AddSeconds(-30).ToUniversalTime()
            New-MockTranscript -SessionDir $existingSession -Entries @(
                (New-PlannerResponse -Content 'BEFORE DISPATCH' -CreatedAt (Get-Date).AddHours(-1).ToUniversalTime()),
                (New-PlannerResponse -Content 'AFTER DISPATCH'  -CreatedAt $dispatchStart.AddSeconds(10))
            )
            $preExisting = @{ $existingSession = $true }

            $result = Get-AgyTranscriptResponse -BrainRoot $script:BrainRoot `
                -PreExistingSessionDirs $preExisting `
                -DispatchStartUtc $dispatchStart `
                -MaxAttempts 1 -DelaySeconds 0

            $result.Response | Should -Be 'AFTER DISPATCH'
            $result.Strategy | Should -Be 'temporal-floor'
        }

        It 'filters out entries with created_at < dispatch start' {
            $existingSession = Join-Path $script:BrainRoot 'existing-uuid'
            $dispatchStart = (Get-Date).ToUniversalTime()
            # Only pre-dispatch entries exist
            New-MockTranscript -SessionDir $existingSession -Entries @(
                (New-PlannerResponse -Content 'STALE 1' -CreatedAt $dispatchStart.AddHours(-2)),
                (New-PlannerResponse -Content 'STALE 2' -CreatedAt $dispatchStart.AddHours(-1))
            )
            $preExisting = @{ $existingSession = $true }

            $result = Get-AgyTranscriptResponse -BrainRoot $script:BrainRoot `
                -PreExistingSessionDirs $preExisting `
                -DispatchStartUtc $dispatchStart `
                -MaxAttempts 1 -DelaySeconds 0

            $result.Response | Should -BeNullOrEmpty
        }
    }

    Context 'entry filtering' {
        It 'skips entries where content is null (tool-call PLANNER_RESPONSE)' {
            $newSession = Join-Path $script:BrainRoot 'new-uuid'
            New-MockTranscript -SessionDir $newSession -Entries @(
                # Tool-call entry: PLANNER_RESPONSE without content
                @{
                    source = 'MODEL'; type = 'PLANNER_RESPONSE'; status = 'COMPLETED'
                    created_at = (Get-Date).ToUniversalTime().ToString('o')
                    tool_calls = @(@{ tool_name = 'view_file'; args = @{ path = 'foo.py' } })
                },
                # Real content entry
                (New-PlannerResponse -Content 'THE REAL ANSWER')
            )

            $result = Get-AgyTranscriptResponse -BrainRoot $script:BrainRoot `
                -PreExistingSessionDirs @{} `
                -DispatchStartUtc ([datetime]::UtcNow.AddSeconds(-30)) `
                -MaxAttempts 1 -DelaySeconds 0

            $result.Response | Should -Be 'THE REAL ANSWER'
        }

        It 'skips entries from non-MODEL sources (e.g. SYSTEM ERROR)' {
            $newSession = Join-Path $script:BrainRoot 'new-uuid'
            New-MockTranscript -SessionDir $newSession -Entries @(
                @{ source = 'SYSTEM'; type = 'ERROR_MESSAGE'; content = 'auth failure'; created_at = (Get-Date).ToUniversalTime().ToString('o') },
                (New-PlannerResponse -Content 'MODEL OUTPUT')
            )

            $result = Get-AgyTranscriptResponse -BrainRoot $script:BrainRoot `
                -PreExistingSessionDirs @{} `
                -DispatchStartUtc ([datetime]::UtcNow.AddSeconds(-30)) `
                -MaxAttempts 1 -DelaySeconds 0

            $result.Response | Should -Be 'MODEL OUTPUT'
        }
    }

    Context 'Run-ID correlation (Fix 2)' {
        It 'disambiguates two overlapping dispatches with identical bundle path by Run ID' {
            $bundle = 'C:\repo\.external-reviews\topic\round-1-bundle.xml'
            $guidA  = [guid]::NewGuid().ToString()
            $guidB  = [guid]::NewGuid().ToString()

            # Two reused (pre-existing) sessions, each holding one dispatch.
            $sessA = Join-Path $script:BrainRoot 'sess-a'
            New-MockTranscript -SessionDir $sessA -Entries @(
                (New-UserEntry      -Text "[Run ID: $guidA] Review the bundle at $bundle"),
                (New-PlannerResponse -Content 'ANSWER FOR A')
            )
            $sessB = Join-Path $script:BrainRoot 'sess-b'
            New-MockTranscript -SessionDir $sessB -Entries @(
                (New-UserEntry      -Text "[Run ID: $guidB] Review the bundle at $bundle"),
                (New-PlannerResponse -Content 'ANSWER FOR B')
            )
            $preExisting = @{ $sessA = $true; $sessB = $true }

            $result = Get-AgyTranscriptResponse -BrainRoot $script:BrainRoot `
                -PreExistingSessionDirs $preExisting `
                -DispatchStartUtc ([datetime]::UtcNow.AddSeconds(-60)) `
                -BundlePath $bundle -DispatchId $guidB `
                -MaxAttempts 1 -DelaySeconds 0

            $result.Response | Should -Be 'ANSWER FOR B'
            $result.Strategy | Should -Be 'run-id-match'
        }

        It 'returns the FIRST PLANNER_RESPONSE after the matching USER line (two GUIDs in one transcript)' {
            $bundle = 'C:\repo\round-1-bundle.xml'
            $guidA  = [guid]::NewGuid().ToString()
            $guidB  = [guid]::NewGuid().ToString()

            $sess = Join-Path $script:BrainRoot 'reused-sess'
            New-MockTranscript -SessionDir $sess -Entries @(
                (New-UserEntry      -Text "[Run ID: $guidA] first prompt $bundle"),
                (New-PlannerResponse -Content 'ANSWER A'),
                (New-UserEntry      -Text "[Run ID: $guidB] second prompt $bundle"),
                (New-PlannerResponse -Content 'ANSWER B')
            )
            $preExisting = @{ $sess = $true }

            # Asking for guidA must NOT return the later ANSWER B.
            $result = Get-AgyTranscriptResponse -BrainRoot $script:BrainRoot `
                -PreExistingSessionDirs $preExisting `
                -DispatchStartUtc ([datetime]::UtcNow.AddSeconds(-60)) `
                -BundlePath $bundle -DispatchId $guidA `
                -MaxAttempts 1 -DelaySeconds 0

            $result.Response | Should -Be 'ANSWER A'
            $result.Strategy | Should -Be 'run-id-match'
        }

        It 'matches a new-session candidate by Run ID even when other new dirs exist (no short-circuit)' {
            $bundle = 'C:\repo\round-2-bundle.xml'
            $guid   = [guid]::NewGuid().ToString()

            # A new dir from another concurrent dispatch (no matching GUID).
            $other = Join-Path $script:BrainRoot 'other-new'
            New-MockTranscript -SessionDir $other -Entries @(
                (New-UserEntry      -Text "[Run ID: $([guid]::NewGuid())] someone else"),
                (New-PlannerResponse -Content 'NOT OURS')
            )
            # Our reused (pre-existing) session holds our GUID.
            $ours = Join-Path $script:BrainRoot 'ours-reused'
            New-MockTranscript -SessionDir $ours -Entries @(
                (New-UserEntry      -Text "[Run ID: $guid] $bundle"),
                (New-PlannerResponse -Content 'OURS')
            )
            $preExisting = @{ $ours = $true }   # $other is NEW; $ours is pre-existing

            $result = Get-AgyTranscriptResponse -BrainRoot $script:BrainRoot `
                -PreExistingSessionDirs $preExisting `
                -DispatchStartUtc ([datetime]::UtcNow.AddSeconds(-60)) `
                -BundlePath $bundle -DispatchId $guid `
                -MaxAttempts 1 -DelaySeconds 0

            $result.Response | Should -Be 'OURS'
            $result.Strategy | Should -Be 'run-id-match'
        }

        It 'falls back to bundle-path match (forward-slash form) when GUID absent' {
            $bundle      = 'C:\repo\round-3-bundle.xml'
            $bundleSlash = $bundle -replace '\\','/'

            $sess = Join-Path $script:BrainRoot 'path-sess'
            New-MockTranscript -SessionDir $sess -Entries @(
                (New-UserEntry      -Text "Review the bundle at $bundleSlash please"),
                (New-PlannerResponse -Content 'PATH MATCH ANSWER')
            )
            $preExisting = @{ $sess = $true }

            $result = Get-AgyTranscriptResponse -BrainRoot $script:BrainRoot `
                -PreExistingSessionDirs $preExisting `
                -DispatchStartUtc ([datetime]::UtcNow.AddSeconds(-60)) `
                -BundlePath $bundle -DispatchId ([guid]::NewGuid().ToString()) `
                -MaxAttempts 1 -DelaySeconds 0

            $result.Response | Should -Be 'PATH MATCH ANSWER'
            $result.Strategy | Should -Be 'run-id-match'
        }

        It 'Pass-2 anchors on the USER entry, not a stale MODEL line quoting the bundle path' {
            # Reused-session hazard: an EARLIER dispatch's PLANNER_RESPONSE quotes the
            # same bundle path. With no GUID echoed, a raw substring scan would latch
            # onto that stale MODEL line and return its (wrong) following answer. Pass 2
            # must require a USER anchor and return the answer after the USER prompt.
            $bundle = 'C:\repo\round-7-bundle.xml'

            $sess = Join-Path $script:BrainRoot 'reused-sess'
            New-MockTranscript -SessionDir $sess -Entries @(
                # Old turn: a MODEL response that itself mentions the bundle path.
                (New-UserEntry      -Text 'unrelated earlier prompt'),
                (New-PlannerResponse -Content "STALE WRONG ANSWER referencing $bundle"),
                # Current turn: USER prompt referencing the bundle, then correct answer.
                (New-UserEntry      -Text "Review the bundle at $bundle please"),
                (New-PlannerResponse -Content 'CORRECT FRESH ANSWER')
            )
            $preExisting = @{ $sess = $true }

            $result = Get-AgyTranscriptResponse -BrainRoot $script:BrainRoot `
                -PreExistingSessionDirs $preExisting `
                -DispatchStartUtc ([datetime]::UtcNow.AddSeconds(-60)) `
                -BundlePath $bundle -DispatchId ([guid]::NewGuid().ToString()) `
                -MaxAttempts 1 -DelaySeconds 0

            $result.Response | Should -Be 'CORRECT FRESH ANSWER'
            $result.Strategy | Should -Be 'run-id-match'
        }

        It 'falls back to legacy heuristic when BundlePath/DispatchId are null' {
            # No Run-ID params -> original new-session-dir behavior.
            $newSession = Join-Path $script:BrainRoot 'legacy-new'
            New-MockTranscript -SessionDir $newSession -Entries @(
                (New-PlannerResponse -Content 'LEGACY RESPONSE')
            )

            $result = Get-AgyTranscriptResponse -BrainRoot $script:BrainRoot `
                -PreExistingSessionDirs @{} `
                -DispatchStartUtc ([datetime]::UtcNow.AddSeconds(-10)) `
                -MaxAttempts 1 -DelaySeconds 0

            $result.Response | Should -Be 'LEGACY RESPONSE'
            $result.Strategy | Should -Be 'new-session-dir'
        }
    }

    Context 'transcript_full.jsonl preferred over truncated transcript.jsonl (R-C1)' {
        It 'extracts the FULL response, not the truncated transcript.jsonl copy' {
            # Live finding: agy writes BOTH transcript.jsonl (token-truncated) and
            # transcript_full.jsonl (complete). Since "transcript.jsonl" sorts before
            # "transcript_full.jsonl" by FullName ('.' < '_'), the run-id scan used to
            # latch onto the TRUNCATED file and lose review text on large responses.
            # The capture candidate set must include only transcript_full.jsonl.
            $guid    = [guid]::NewGuid().ToString()
            $bundle  = 'C:\repo\round-1-bundle.xml'
            $session = Join-Path $script:BrainRoot 'new-session-c1'
            $logDir  = Join-Path $session '.system_generated/logs'
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null

            $userEntry = (New-UserEntry -Text "[Run ID: $guid] Review the bundle at $bundle")
            # Truncated copy (what we must NOT return).
            @(
                $userEntry,
                (New-PlannerResponse -Content 'TRUNCATED HALF')
            ) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 } |
                Set-Content -Path (Join-Path $logDir 'transcript.jsonl') -Encoding utf8
            # Full copy (what we MUST return).
            @(
                $userEntry,
                (New-PlannerResponse -Content 'FULL COMPLETE RESPONSE WITH ALL THE REVIEW TEXT')
            ) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 } |
                Set-Content -Path (Join-Path $logDir 'transcript_full.jsonl') -Encoding utf8

            $result = Get-AgyTranscriptResponse -BrainRoot $script:BrainRoot `
                -PreExistingSessionDirs @{} `
                -DispatchStartUtc ([datetime]::UtcNow.AddSeconds(-60)) `
                -BundlePath $bundle -DispatchId $guid `
                -MaxAttempts 1 -DelaySeconds 0

            $result.Response | Should -Be 'FULL COMPLETE RESPONSE WITH ALL THE REVIEW TEXT'
            $result.TranscriptPath | Should -Match 'transcript_full\.jsonl$'
        }

        It 'does NOT capture from a transcript.jsonl-only dir (only transcript_full is a source)' {
            # Deterministic driver: the truncated transcript.jsonl must never be a
            # capture source. (The "both present" case above returns the full copy
            # only by Sort-Object culture-collation luck — 'transcript_full' sorts
            # before 'transcript.' under the default collation; we do not rely on
            # that.) The existing-session path already scans only transcript_full;
            # the new-session path must match so capture never depends on collation.
            $guid    = [guid]::NewGuid().ToString()
            $bundle  = 'C:\repo\round-2-bundle.xml'
            $session = Join-Path $script:BrainRoot 'truncated-only'
            $logDir  = Join-Path $session '.system_generated/logs'
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            @(
                (New-UserEntry      -Text "[Run ID: $guid] Review the bundle at $bundle"),
                (New-PlannerResponse -Content 'TRUNCATED-ONLY SHOULD BE IGNORED')
            ) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 } |
                Set-Content -Path (Join-Path $logDir 'transcript.jsonl') -Encoding utf8

            $result = Get-AgyTranscriptResponse -BrainRoot $script:BrainRoot `
                -PreExistingSessionDirs @{} `
                -DispatchStartUtc ([datetime]::UtcNow.AddSeconds(-60)) `
                -BundlePath $bundle -DispatchId $guid `
                -MaxAttempts 1 -DelaySeconds 0

            $result.Response | Should -BeNullOrEmpty `
                -Because 'transcript.jsonl is token-truncated; only transcript_full.jsonl is authoritative'
        }
    }

    Context 'edge cases' {
        It 'returns null when brain root is empty' {
            $result = Get-AgyTranscriptResponse -BrainRoot $script:BrainRoot `
                -PreExistingSessionDirs @{} `
                -DispatchStartUtc ([datetime]::UtcNow) `
                -MaxAttempts 1 -DelaySeconds 0

            $result.Response | Should -BeNullOrEmpty
        }

        It 'returns null when transcript file exists but is empty' {
            $newSession = Join-Path $script:BrainRoot 'new-uuid'
            $logDir = Join-Path $newSession '.system_generated/logs'
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $logDir 'transcript_full.jsonl') -Force | Out-Null

            $result = Get-AgyTranscriptResponse -BrainRoot $script:BrainRoot `
                -PreExistingSessionDirs @{} `
                -DispatchStartUtc ([datetime]::UtcNow) `
                -MaxAttempts 1 -DelaySeconds 0

            $result.Response | Should -BeNullOrEmpty
        }

        It 'returns null when entries have unparseable JSON' {
            $newSession = Join-Path $script:BrainRoot 'new-uuid'
            $logDir = Join-Path $newSession '.system_generated/logs'
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            Set-Content -Path (Join-Path $logDir 'transcript_full.jsonl') -Value "not valid json`r`n{also not}`r`n" -Encoding utf8

            $result = Get-AgyTranscriptResponse -BrainRoot $script:BrainRoot `
                -PreExistingSessionDirs @{} `
                -DispatchStartUtc ([datetime]::UtcNow) `
                -MaxAttempts 1 -DelaySeconds 0

            $result.Response | Should -BeNullOrEmpty
        }
    }
}
