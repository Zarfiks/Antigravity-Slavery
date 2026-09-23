<#
.SYNOPSIS
  PowerShell entry point: runs the bash scripts through Git Bash.

.EXAMPLE
  .\scripts\agy.ps1 slave gemini-medium "Explain src\net\client.py" C:\code\repo
  .\scripts\agy.ps1 fanout -j 3 gemini-medium C:\code\repo tasks.txt
  .\scripts\agy.ps1 merge --list
  .\scripts\agy.ps1 consensus "Review src/auth for security bugs" C:\code\repo
  .\scripts\agy.ps1 models
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('slave', 'fanout', 'merge', 'consensus', 'models')]
    [string]$Command,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

# Prefer Git for Windows' bash: C:\Windows\System32\bash.exe is WSL, which
# would run the scripts inside Linux with different paths and a different agy.
$candidates = @(
    (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
)
$bash = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $bash) {
    $found = Get-Command bash -ErrorAction SilentlyContinue
    if ($found -and $found.Source -notmatch 'System32') { $bash = $found.Source }
}
if (-not $bash) {
    Write-Error 'Git Bash not found. Install Git for Windows: https://git-scm.com/download/win'
    exit 2
}

$script = Join-Path $PSScriptRoot "agy-$Command.sh"
if ($null -eq $Rest) { $Rest = @() }
& $bash $script @Rest
exit $LASTEXITCODE
