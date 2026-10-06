[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
$cache = Join-Path $repo '.cache/audio-sources/music'
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$hg = 'https://downloads.khinsider.com/game-soundtracks/album/pokemon-heartgold-and-soulsilver-music-super-complete'
$fr = 'https://downloads.khinsider.com/game-soundtracks/album/pokemon-firered-leafgreen-music-super-complete'
$rs = 'https://downloads.khinsider.com/game-soundtracks/album/pokemon-ruby-sapphire-music-super-complete'
$specs = @(
    @('title', $rs, '1-05.', '未白镇 · 红宝石／蓝宝石'),
    @('preparation', $hg, '1-41.', '满金市 · 心金／魂银'),
    @('battle_kanto', $fr, '1-11.', '训练家战斗 · 火红／叶绿'),
    @('battle_johto', $hg, '1-18.', '城都训练家战斗 · 心金／魂银'),
    @('climax', $hg, '2-78.', '冠军战斗 · 心金／魂银'),
    @('victory', $hg, '1-19.', '训练家战胜 · 心金／魂银'),
    @('reflection', $hg, '1-04.', '若叶镇 · 心金／魂银')
)
$albums = @{}
$records = @()
foreach ($spec in $specs) {
    if (-not $albums.ContainsKey($spec[1])) {
        $albums[$spec[1]] = Invoke-WebRequest $spec[1] -TimeoutSec 60
    }
    $prefix = [regex]::Escape($spec[2])
    $link = @($albums[$spec[1]].Links | Where-Object href -match "/$prefix" | Select-Object -ExpandProperty href -Unique)[0]
    if (-not $link) { throw "Missing track $($spec[0])" }
    $page = 'https://downloads.khinsider.com' + $link
    $detail = Invoke-WebRequest $page -TimeoutSec 60
    $url = @($detail.Links | Where-Object href -match '^https://.*\.flac$' | Select-Object -ExpandProperty href -Unique)[0]
    if (-not $url) { throw "No lossless source for $($spec[0])" }
    $sourceName = if ($spec[0] -eq 'title') { 'littleroot.flac' } else { "$($spec[0]).flac" }
    $file = Join-Path $cache $sourceName
    if (-not (Test-Path $file)) { Invoke-WebRequest $url -OutFile $file -TimeoutSec 180 }
    $records += [ordered]@{ id = $spec[0]; title = $spec[3]; source_file = $sourceName; album = $spec[1]; page = $page; url = $url; sha256 = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower(); rights = 'Original Pokémon soundtrack. Nintendo / Creatures / GAME FREAK; not CC0.' }
    Write-Host "Fetched $($spec[0])"
}
$records | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $cache 'sources.json') -Encoding utf8
