# PSScriptAnalyzer settings for the scripts in src\.
# Build.cmd runs it. To run it by hand:
#   Invoke-ScriptAnalyzer -Path .\src -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Private GUI helpers inside one script, not exported cmdlets, so
        # -WhatIf/-Confirm support and singular nouns add nothing here.
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns',
        # WPF event handlers take ($sender, $e) whether they use them or not.
        'PSReviewUnusedParameter'
    )
}
