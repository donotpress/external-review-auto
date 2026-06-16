BeforeAll { . "$PSScriptRoot/../workflow.ps1" }
Describe 'Get-EraReviewerList' {
    BeforeAll {
        $script:reg = [pscustomobject]@{
            'gemini-pro-low' = [pscustomobject]@{ backend='agy'; model_id='gemini-3.1-pro-low' }
            'deepseek-http'  = [pscustomobject]@{ backend='openaicompat'; model_id='deepseek-v4-pro'; api_key_env='OPENCODE_API_KEY' }
            'gemini-api'     = [pscustomobject]@{ backend='geminiapi'; model_id='gemini-2.5-flash' }
            '_agy_model_map' = [pscustomobject]@{ foo='bar' }
        }
        $script:cmd = { param($n) $n -eq 'agy' }                 # only agy on PATH
        $script:env = { param($n) if ($n -eq 'OPENCODE_API_KEY') { 'k' } else { $null } }
    }
    It 'excludes _* registry keys' {
        $rows = Get-EraReviewerList -Registry $script:reg -CommandExists $script:cmd -EnvValue $script:env
        ($rows | Where-Object { $_.preset -like '_*' }) | Should -BeNullOrEmpty
    }
    It 'marks agy ready (PATH) and deepseek-http ready (key) but gemini-api not' {
        $rows = Get-EraReviewerList -Registry $script:reg -CommandExists $script:cmd -EnvValue $script:env
        ($rows | Where-Object preset -eq 'gemini-pro-low').ready | Should -BeTrue
        ($rows | Where-Object preset -eq 'deepseek-http').ready  | Should -BeTrue
        ($rows | Where-Object preset -eq 'gemini-api').ready     | Should -BeFalse
    }
    It 'flags the default preset' {
        $rows = Get-EraReviewerList -Registry $script:reg -Default 'gemini-pro-low' -CommandExists $script:cmd -EnvValue $script:env
        ($rows | Where-Object preset -eq 'gemini-pro-low').is_default | Should -BeTrue
    }
}
Describe 'Format-EraReviewerList' {
    It 'renders groups + default footer' {
        $rows = @([pscustomobject]@{ preset='gemini-pro-low'; backend='agy'; ready=$true; model='x'; requirement='agy CLI'; is_default=$true })
        $out = Format-EraReviewerList -Rows $rows -Default 'gemini-pro-low'
        $out | Should -Match 'gemini-pro-low'
        $out | Should -Match 'change: /era set default'
    }
    It 'shows (none ready) when default is empty' {
        $rows = @([pscustomobject]@{ preset='x'; backend='agy'; ready=$false; model='m'; requirement='agy CLI'; is_default=$false })
        $out = Format-EraReviewerList -Rows $rows -Default ''
        $out | Should -Match 'Default: \(none ready\)'
    }
}
