# Coverage for the post-dispatch seat-containment check.
#
# WHY THIS EXISTS. era spawns every seat with permissions bypassed and NO
# working directory, so each child inherits [Environment]::CurrentDirectory --
# which is the repo under review, because era.ps1 derives $repoRoot from it.
# Measured 2026-09-05:
#
#   grep -n '\.WorkingDirectory' backends/*.ps1 workflow.ps1 runtimes/era.ps1  -> no matches
#   backends/claude.ps1:150  --allow-dangerously-skip-permissions
#   backends/agy.ps1:466     --dangerously-skip-permissions
#   ~/.config/opencode/opencode.json  ->  edit/bash/external_directory = allow
#
# and a live probe: `opencode run` in a scratch dir ran bash, printed the cwd,
# and read a file that was in no bundle. backends/agy.ps1:369 already records
# the same thing from the other side -- "agy is an agentic agent, and 'review
# the code at <path>' invited it to go exploring the repository".
#
# So the seats are contained by PROMPT TEXT, not by structure. era already has
# the first half of a check -- runtimes/era.ps1:910 refuses to dispatch onto a
# dirty tree -- and never looks again. This is the second half: re-read the tree
# after the panel returns and say, on the record, whether it moved.
#
# The three properties that matter, and they pull against each other:
#   - a round in which a seat wrote to the repo must be REPORTED, or the check
#     is decoration;
#   - a healthy round must stay SILENT (the 0c6be1d failure mode: a warning that
#     fires every round is a warning nobody reads);
#   - a round where the tree could not be read must say UNMEASURED, never
#     "contained" -- a never-asked question recorded as a negative answer is the
#     exact shape ~/.claude/CLAUDE.md was written about.
#
# Run:
#   pwsh -Command "Invoke-Pester -Path tests/SeatContainment.Tests.ps1"

BeforeAll {
    . "$PSScriptRoot/../workflow.ps1"

    function script:State {
        <# The shape Get-EraGitState returns (runtimes/era.ps1:281). #>
        param([string]$Head = 'aaa111', [string]$Branch = 'master', [string[]]$Dirty = @())
        return [pscustomobject]@{ Head = $Head; Branch = $Branch; Dirty = @($Dirty) }
    }
}

Describe 'Compare-EraSeatContainment' -Tag Unit {

    It 'reports a breach when a path is dirty after the round that was not dirty before' {
        $before = State -Dirty @()
        $after  = State -Dirty @('?? seat-wrote-this.py')

        $r = Compare-EraSeatContainment -Before $before -After $after

        $r.Verdict  | Should -Be 'breached'
        $r.NewDirty | Should -Contain '?? seat-wrote-this.py'
    }

    It 'reports a breach when HEAD moved even though the tree is clean both times' {
        # The worst case, and the one a dirt-only check calls healthy: a seat
        # with bash and skip-permissions ran `git commit`. Before and after are
        # both spotless; the only evidence is the sha.
        $before = State -Head 'aaa111' -Dirty @()
        $after  = State -Head 'bbb222' -Dirty @()

        $r = Compare-EraSeatContainment -Before $before -After $after

        $r.Verdict   | Should -Be 'breached'
        $r.HeadMoved | Should -BeTrue
    }

    It 'ignores dirt that was already there, so the check survives -AllowDirtyTree' {
        # The gate at runtimes/era.ps1 refuses a dirty tree by default and
        # -AllowDirtyTree / ERA_ALLOW_DIRTY=1 waives it. That waiver is about
        # PROVENANCE -- "round N covers commits X..Y" means nothing when the tree
        # is dirty -- and it must not also waive containment, or the one flag an
        # operator reaches for when reviewing uncommitted work would silently
        # switch off the only check that watches the seats.
        #
        # It does not, and this is what makes that true: pre-existing dirt is in
        # BOTH snapshots, so it diffs away and only what appeared during the
        # round is left.
        $before = State -Dirty @(' M src/app.py', '?? notes.md')
        $after  = State -Dirty @(' M src/app.py', '?? notes.md', '?? seat-wrote-this.py')

        $r = Compare-EraSeatContainment -Before $before -After $after

        $r.Verdict  | Should -Be 'breached'
        $r.NewDirty | Should -Be @('?? seat-wrote-this.py')
    }

    It 'says unmeasured, not contained, when there is no git state to compare' {
        # Get-EraGitState returns $null outside a work tree and when git is not
        # on PATH. Two nulls compare equal and produce an empty diff, so the
        # arithmetic answer is "nothing changed" -- which is a property of the
        # INSTRUMENT reported as a property of the SUBJECT. That is the exact
        # substitution ~/.claude/CLAUDE.md exists to stop, and the one
        # tools/vacuity's `unmeasured` state was invented for.
        $r = Compare-EraSeatContainment -Before $null -After $null

        $r.Verdict | Should -Be 'unmeasured'
        $r.Reason  | Should -Not -BeNullOrEmpty
    }

    It 'does not call era writing its own round artifacts a breach' {
        # era writes the bundle, prompt and manifest under .external-reviews/
        # DURING the window this check brackets, so its own output is guaranteed
        # to appear in the second snapshot. Every repo that uses era is supposed
        # to gitignore that directory -- and `--porcelain` omits ignored files,
        # so normally none of this is visible. But "supposed to" is not a
        # measurement: in a repo that has not added the ignore yet, round 1
        # creates the directory between the two snapshots and every round after
        # it reports a breach that is era's own reflection.
        #
        # A check that cries wolf on every healthy round is 0c6be1d again, and
        # that one was caught by a live round rather than by its tests.
        $before = State -Dirty @()
        $after  = State -Dirty @(
            '?? .external-reviews/mytopic/round-1-bundle.xml',
            '?? ".external-reviews/my topic/round-1-manifest.json"'
        )

        $r = Compare-EraSeatContainment -Before $before -After $after

        $r.Verdict  | Should -Be 'contained'
        $r.NewDirty | Should -BeNullOrEmpty
    }

    It 'still reports a real path when era artifacts appear alongside it' {
        # The filter must remove era's own noise WITHOUT swallowing the signal
        # sitting next to it -- otherwise a seat could write to the repo during
        # any round that also produced artifacts, which is every round.
        $before = State -Dirty @()
        $after  = State -Dirty @(
            '?? .external-reviews/mytopic/round-1-bundle.xml',
            ' M src/app.py'
        )

        $r = Compare-EraSeatContainment -Before $before -After $after

        $r.Verdict  | Should -Be 'breached'
        $r.NewDirty | Should -Be @(' M src/app.py')
    }
}

Describe 'Write-ReviewMetadata records the containment verdict' -Tag Unit {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ("era-contain-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:Reg = @{
            gemini = @{ backend = 'agy'; model_id = 'g'; pricing = @{ input_per_m = 0.3; output_per_m = 1.2 } }
        }
        $script:Results = @{
            gemini = @{
                Preset = 'gemini'; ExitCode = 0; Response = '## Issues'
                CaptureMethod = 'polling'; CaptureStrategy = 'run-id-match'
                ContentOk = $true; RetryCount = 0; RetryReason = $null
                OutputTokens = 10; WallClockSec = 5; TruncationWarning = $null; Warnings = @()
            }
        }
    }
    AfterEach { Remove-Item $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'writes the verdict and the paths a seat touched' {
        # Console-only was the disposition of citation_warnings too, and the
        # comment on that parameter says why it moved: "the one durable record of
        # a reviewer inventing line numbers was a line in a terminal that nobody
        # keeps". A seat writing to the repo under review deserves at least the
        # same durability -- this is the round's provenance record, and the
        # question "did anything touch the tree while the panel ran" has to be
        # answerable from the artifacts months later.
        $containment = [pscustomobject]@{
            Verdict = 'breached'; NewDirty = @('?? seat-wrote-this.py')
            HeadMoved = $false; BeforeHead = 'aaa111'; AfterHead = 'aaa111'; Reason = $null
        }

        Write-ReviewMetadata -ReviewDir $script:Dir -Round 1 -TopicSlug 't' -Mode 'code' `
            -Results $script:Results -Registry $script:Reg -BundleTokens 1000 `
            -SeatContainment $containment

        $meta = Get-Content -Raw (Join-Path $script:Dir 'round-1-metadata.json') | ConvertFrom-Json
        $meta.seat_containment.verdict   | Should -Be 'breached'
        $meta.seat_containment.new_dirty | Should -Contain '?? seat-wrote-this.py'
    }

    It 'records unmeasured rather than omitting the field when no check ran' {
        # Same rule the blind_seat field is written under, quoted from its own
        # comment: "'no seat was blinded' and 'this writer predates the field'
        # are different facts, and a scorer reading a directory of rounds has to
        # be able to tell them apart." An absent key here would collapse "era
        # could not check" into "era was not built to check yet".
        Write-ReviewMetadata -ReviewDir $script:Dir -Round 1 -TopicSlug 't' -Mode 'code' `
            -Results $script:Results -Registry $script:Reg -BundleTokens 1000

        $meta = Get-Content -Raw (Join-Path $script:Dir 'round-1-metadata.json') | ConvertFrom-Json
        $meta.PSObject.Properties.Name  | Should -Contain 'seat_containment'
        $meta.seat_containment.verdict  | Should -Be 'unmeasured'
    }
}
