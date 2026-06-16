BeforeAll {
    . "$PSScriptRoot/../backends/openaicompat.ps1"
    $script:bundle = New-TemporaryFile; 'BUNDLE' | Set-Content $script:bundle
    $script:prompt = New-TemporaryFile; 'PROMPT' | Set-Content $script:prompt
    $script:resp   = New-TemporaryFile
    $env:FAKE_KEY  = 'x'
}
Describe 'openaicompat reasoning_content fallback' {
    It 'uses reasoning_content when content is empty' {
        Mock -CommandName Invoke-RestMethod -MockWith {
            [pscustomobject]@{
                choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = ''; reasoning_content = 'REVIEW FROM REASONING' }; finish_reason = 'stop' })
                usage   = [pscustomobject]@{ prompt_tokens = 1; completion_tokens = 2 }
            }
        }
        $info = @{ api_base = 'https://example.test/v1'; api_key_env = 'FAKE_KEY'; model_id = 'm'; max_tokens = 4242 }
        $r = Invoke-OpenaicompatReview -BundlePath $script:bundle -PromptPath $script:prompt -ResponsePath $script:resp -ModelInfo $info
        $r.Response | Should -Match 'REVIEW FROM REASONING'
    }
    It 'honors per-preset max_tokens in the request body' {
        $script:capturedBody = $null
        Mock -CommandName Invoke-RestMethod -MockWith {
            $script:capturedBody = $Body
            [pscustomobject]@{ choices = @([pscustomobject]@{ message = [pscustomobject]@{ content = 'ok' }; finish_reason = 'stop' }); usage = [pscustomobject]@{ prompt_tokens = 1; completion_tokens = 1 } }
        }
        $info = @{ api_base = 'https://example.test/v1'; api_key_env = 'FAKE_KEY'; model_id = 'm'; max_tokens = 4242 }
        Invoke-OpenaicompatReview -BundlePath $script:bundle -PromptPath $script:prompt -ResponsePath $script:resp -ModelInfo $info | Out-Null
        $script:capturedBody | Should -Match '4242'
    }
}
