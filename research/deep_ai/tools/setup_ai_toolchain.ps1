[CmdletBinding()]
param([string]$Name = 'PokemonTCG-DeepAI')

$ErrorActionPreference = 'Stop'
$researchRoot = Split-Path -Parent $PSScriptRoot
$environment = Join-Path $researchRoot 'environment.yml'
$conda = (Get-Command conda.exe -ErrorAction Stop).Source

$known = @(& $conda env list --json | ConvertFrom-Json).envs
$exists = @($known | Where-Object { Split-Path -Leaf $_ -eq $Name }).Count -gt 0
if ($exists) {
    & $conda env update --name $Name --file $environment --prune
} else {
    & $conda env create --name $Name --file $environment
}
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to create the explicit Deep AI research environment.'
}
Write-Host "DEEP_AI_RESEARCH_ENV_OK name=$Name"
