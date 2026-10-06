[CmdletBinding()]
param([switch]$SfxOnly, [switch]$MusicOnly, [switch]$Check)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$cache = Join-Path $repo '.cache/audio-sources'
$output = Join-Path $repo 'godot/assets/audio'
$ffmpeg = Join-Path $repo '.tools/audio/ffmpeg-7.1.1-essentials_build/bin/ffmpeg.exe'
$manifestFile = Join-Path $PSScriptRoot 'audio/manifest.json'
if ($Check) {
    $manifest = Get-Content $manifestFile -Raw | ConvertFrom-Json
    foreach ($asset in $manifest.outputs) {
        $file = Join-Path $output $asset.file
        if (-not (Test-Path $file) -or (Get-FileHash $file -Algorithm SHA256).Hash.ToLower() -ne $asset.sha256) { throw "Audio asset drift: $($asset.file)" }
    }
    Write-Host 'AUDIO_ASSETS_OK'
    return
}
if (-not (Test-Path $ffmpeg)) { throw 'Expected FFmpeg 7.1.1 in .tools/audio/ffmpeg-7.1.1-essentials_build/bin.' }
New-Item -ItemType Directory -Force -Path $cache, (Join-Path $cache 'music') | Out-Null
foreach ($dir in @('sfx','cues','music','licenses')) { New-Item -ItemType Directory -Force (Join-Path $output $dir) | Out-Null }
function Write-AudioResource {
    param([string]$Relative, [switch]$CleanWhitespace, [Parameter(ValueFromPipeline = $true)][string]$Content)
    process {
        # Match .gitattributes on Windows, Linux and a fresh Git checkout.
        $normalized = $Content.Replace("`r`n", "`n").Replace("`r", "").TrimEnd("`n") + "`n"
        if ($CleanWhitespace) { $normalized = (($normalized.Split("`n") | ForEach-Object { $_.TrimEnd() }) -join "`n").TrimEnd("`n") + "`n" }
        [IO.File]::WriteAllText((Join-Path $output $Relative), $normalized, [Text.UTF8Encoding]::new($false))
    }
}
# Source packages are cached locally, or restored from pinned download URLs.
$packages = @(
    @('casino-audio', 'https://kenney.nl/assets/casino-audio'),
    @('impact-sounds', 'https://kenney.nl/assets/impact-sounds'),
    @('interface-sounds', 'https://kenney.nl/assets/interface-sounds')
)
$sources = @()
foreach ($package in $packages) {
    $folder = Join-Path $cache $package[0]
    if (-not (Test-Path (Join-Path $folder 'Audio'))) {
        $page = Invoke-WebRequest $package[1] -TimeoutSec 60
        $download = @($page.Links | Where-Object href -match '\.zip' | Select-Object -ExpandProperty href)[0]
        if (-not $download) { throw "Missing source archive: $($package[1])" }
        $download = [Uri]::new([Uri]$package[1], $download).AbsoluteUri
        $archive = Join-Path $cache "$($package[0]).zip"
        Invoke-WebRequest $download -OutFile $archive
        Expand-Archive -LiteralPath $archive -DestinationPath $folder -Force
    }
    $pinnedPackages = @(Get-Content (Join-Path $PSScriptRoot 'audio/source_packages.json') -Raw | ConvertFrom-Json)
    $expected = @($pinnedPackages | Where-Object name -eq $package[0])[0].sha256
    if ((Get-FileHash (Join-Path $cache "$($package[0]).zip")).Hash.ToLower() -ne $expected) { throw "Source archive changed: $($package[0])" }
    Get-Content -LiteralPath (Join-Path $folder 'License.txt') -Raw | Write-AudioResource -CleanWhitespace -Relative "licenses/$($package[0]).txt"
    $sources += @{ name = $package[0]; url = $package[1]; license = 'CC0'; sha256 = (Get-FileHash (Join-Path $cache "$($package[0]).zip")).Hash.ToLower() }
}
$recipes = [Collections.Generic.List[object]]::new()
$cueIds = [Collections.Generic.List[string]]::new()
$outputs = [Collections.Generic.List[object]]::new()
# Offline PCM mastering only. The shipped game has no synthesis/processing tool dependency.
if (-not ('AudioPcmMastering' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
public static class AudioPcmMastering {
    public static double Normalize(string path, double targetPeak) {
        byte[] bytes = File.ReadAllBytes(path);
        int data = -1, length = 0;
        for (int offset = 12; offset + 8 <= bytes.Length;) {
            int size = BitConverter.ToInt32(bytes, offset + 4);
            if (Encoding.ASCII.GetString(bytes, offset, 4) == "data") { data = offset + 8; length = size; break; }
            offset += 8 + size + (size & 1);
        }
        if (data < 0 || length < 2 || data + length > bytes.Length) throw new Exception("Invalid PCM: " + path);
        double peak = 0;
        int count = length / 2;
        for (int i = 0; i < count; i++) peak = Math.Max(peak, Math.Abs((double)BitConverter.ToInt16(bytes, data + i * 2)));
        if (peak < 4) throw new Exception("Silent source: " + path);
        double gain = targetPeak * 32767.0 / peak;
        for (int i = 0; i < count; i++) {
            double edge = Math.Min(1.0, Math.Min(i, count - i - 1) / 96.0);
            short value = (short)Math.Round(BitConverter.ToInt16(bytes, data + i * 2) * gain * edge);
            bytes[data + i * 2] = (byte)(value & 255);
            bytes[data + i * 2 + 1] = (byte)((value >> 8) & 255);
        }
        File.WriteAllBytes(path, bytes);
        return gain;
    }
}
'@
}
function Invoke-AudioFFmpeg([string[]]$Arguments) {
    & $ffmpeg -hide_banner -loglevel error -y @Arguments
    if ($LASTEXITCODE -ne 0) { throw "FFmpeg audio render failed ($LASTEXITCODE)." }
}
function Add-Output([string]$Relative) {
    $outputs.Add(@{ file = $Relative; sha256 = (Get-FileHash (Join-Path $output $Relative)).Hash.ToLower() })
}
function New-Cue {
    param([string]$Id, [string]$Category, [string]$Source, [string]$Filter = 'anull', [string]$Layer = '', [double]$Seconds = 0.35, [int]$Priority = 1, [string]$Bus = 'SFX', [double]$Gain = 0, [string]$LayerFilter = 'anull', [double]$LayerGain = 0.38, [int]$LayerDelay = 18, [string]$Body = '')
    $paths = @(Get-ChildItem (Join-Path $cache $Source) -File | Sort-Object Name)
    if ($paths.Count -eq 0) { throw "No samples for $Id : $Source" }
    $layers = if ($Layer) { @(Get-ChildItem (Join-Path $cache $Layer) -File | Sort-Object Name) } else { @() }
    $bodies = if ($Body) { @(Get-ChildItem (Join-Path $cache $Body) -File | Sort-Object Name) } else { @() }
    $refs = [Collections.Generic.List[string]]::new()
    $streams = [Collections.Generic.List[string]]::new()
    for ($variant = 0; $variant -lt 3; $variant++) {
        $primary = $paths[$variant % $paths.Count].FullName
        $speed = (0.95 + $variant * 0.05).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
        $duration = $Seconds.ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
        $fade = [Math]::Max(0.02, $Seconds - 0.065).ToString('0.000', [Globalization.CultureInfo]::InvariantCulture)
        $relative = "sfx/${Id}_0${variant}.wav"
        $file = Join-Path $output $relative
        $trimSilence = 'silenceremove=start_periods=1:start_duration=0.001:start_threshold=-35dB:detection=peak:window=0.002'
        $filters = "[0:a]aresample=48000,$trimSilence,asetrate=48000*$speed,aresample=48000,$Filter,apad,atrim=duration=$duration[a]"
        $arguments = @('-i', $primary)
        $mix = '[a]'
        $layerFile = ''
        $bodyFile = ''
        if ($layers.Count -gt 0) {
            $layerFile = $layers[($variant + 1) % $layers.Count].FullName
            $arguments += @('-i', $layerFile)
            $filters += ";[1:a]aresample=48000,$trimSilence,$LayerFilter,volume=$LayerGain,adelay=$LayerDelay,apad,atrim=duration=$duration[b];[a][b]amix=inputs=2:normalize=0[m]"
            $mix = '[m]'
        }
        if ($bodies.Count -gt 0) {
            $bodyFile = $bodies[($variant + 2) % $bodies.Count].FullName
            $bodyInput = $arguments.Count / 2
            $arguments += @('-i', $bodyFile)
            $filters += ";[${bodyInput}:a]aresample=48000,$trimSilence,lowpass=f=550,highpass=f=55,volume=0.24,adelay=32,apad,atrim=duration=$duration[body];${mix}[body]amix=inputs=2:normalize=0[weighted]"
            $mix = '[weighted]'
        }
        $filters += ";${mix}highpass=f=35,acompressor=threshold=0.32:ratio=2:attack=3:release=60:makeup=1.5,alimiter=limit=0.70:level=false,afade=t=in:d=0.003,afade=t=out:st=${fade}:d=0.065[out]"
        Invoke-AudioFFmpeg ($arguments + @('-filter_complex', $filters, '-map', '[out]', '-ac','1','-ar','48000','-c:a','pcm_s16le','-fflags','+bitexact', $file))
        $targetPeak = if ($Category -eq 'impact') { 0.70 } elseif ($Bus -eq 'UI' -or $Category -eq 'charge') { 0.45 } else { 0.55 }
        $masteringGain = [AudioPcmMastering]::Normalize($file, $targetPeak)
        $refs.Add("[ext_resource type=`"AudioStream`" path=`"res://assets/audio/$relative`" id=`"v$variant`"]")
        $streams.Add("ExtResource(`"v$variant`")")
        $recipes.Add(@{ output = $relative; inputs = @($primary, $layerFile, $bodyFile) | Where-Object { $_ } | ForEach-Object { [IO.Path]::GetRelativePath($cache, $_).Replace('\','/') }; input_sha256 = @($primary, $layerFile, $bodyFile) | Where-Object { $_ } | ForEach-Object { (Get-FileHash $_).Hash.ToLower() }; filter = $filters; pcm_peak = $targetPeak; mastering_gain = $masteringGain; edge_fade_samples = 96 })
        Add-Output $relative
    }
    $duck = if ($Category -eq 'impact') { if ($Id.StartsWith('attack_heavy')) { -4.5 } else { -2.5 } } elseif ($Category -eq 'charge') { -1.0 } elseif ($Id -in @('evolution','pokemon_ko','direct_ko','victory','defeat','draw')) { -3.5 } elseif ($Id -in @('energy_attach','prize')) { -1.5 } else { 0.0 }
    $cooldown = if ($Category -eq 'impact') { 0 } elseif ($Category -eq 'cards') { 22 } elseif ($Bus -eq 'UI') { 45 } else { 35 }
    $instances = if ($Category -eq 'cards') { 6 } elseif ($Priority -ge 3) { 4 } else { 3 }
    $stackGroup = if ($Category -eq 'impact') { 'impact' } elseif ($Category -eq 'cards' -and $Id.StartsWith('card_')) { 'paper' } else { '' }
    $stackStep = if ($stackGroup -eq 'impact') { -2.0 } elseif ($stackGroup -eq 'paper') { -1.0 } else { 0.0 }
    $definition = @"
[gd_resource type="Resource" script_class="AudioCueDefinition" load_steps=5 format=3]

[ext_resource type="Script" path="res://audio/audio_cue_definition.gd" id="script"]
$($refs -join "`n")

[resource]
script = ExtResource("script")
id = &"$Id"
category = "$Category"
variants = Array[AudioStream]([$($streams -join ', ')])
bus = "$Bus"
gain_db = $Gain
priority = $Priority
max_instances = $instances
cooldown_ms = $cooldown
duck_db = $duck
stack_group = &"$stackGroup"
stack_step_db = $stackStep
"@
    $definition | Write-AudioResource -Relative "cues/$Id.tres"
    Add-Output "cues/$Id.tres"
    $cueIds.Add($Id)
}
if (-not $MusicOnly) {
$casino = 'casino-audio/Audio'
$impact = 'impact-sounds/Audio'
$ui = 'interface-sounds/Audio'
foreach ($entry in @(
    @('click','click'), @('select','select'), @('confirm','confirmation'), @('success','confirmation'),
    @('back','back'), @('modal_open','open'), @('modal_close','close'), @('error','error'),
    @('connect','maximize'), @('disconnect','minimize'), @('toggle','toggle')
)) { New-Cue -Id $entry[0] -Category 'interface' -Source "$ui/$($entry[1])_*.ogg" -Seconds 0.24 -Bus UI -Gain -7 }
foreach ($entry in @(
    @('card_draw','card-slide',0.19), @('card_move','card-slide',0.26), @('card_reveal','card-shove',0.28),
    @('card_place','card-place',0.23), @('card_discard','card-shove',0.27), @('card_recover','card-slide',0.25),
    @('shuffle','card-shuffle',0.75), @('box_open','cards-pack-open',0.45), @('box_close','cards-pack-take-out',0.35),
    @('card_inspect','card-shove',0.22)
)) {
    $paperLayer = if ($entry[0] -in @('shuffle','box_open','box_close')) { "$casino/card-slide-*.ogg" } else { '' }
    New-Cue -Id $entry[0] -Category 'cards' -Source "$casino/$($entry[1])*.ogg" -Layer $paperLayer -Seconds $entry[2] -Gain -3
}
foreach ($entry in @(
    @('pokemon_play','card-place','confirmation',0.36), @('trainer','card-shove','select',0.34),
    @('tool','chip-lay','switch',0.30), @('stadium','cards-pack-open','open',0.55),
    @('retreat','card-slide','back',0.35), @('switch','card-slide','switch',0.32),
    @('promote','card-shove','maximize',0.36), @('prize','card-slide','confirmation',0.55)
)) { New-Cue -Id $entry[0] -Category 'battle' -Source "$casino/$($entry[1])*.ogg" -Layer "$ui/$($entry[2])_*.ogg" -Seconds $entry[3] -Priority 2 -Gain -2 }
New-Cue -Id coin_toss -Category cards -Source "$impact/impactMetal_light_*.ogg" -Filter 'highpass=f=1400,aecho=0.8:0.7:38|70:0.30|0.16' -Seconds 0.32 -Gain -6
New-Cue -Id coin_land -Category cards -Source "$casino/chips-collide-*.ogg" -Layer "$impact/impactMetal_light_*.ogg" -Seconds 0.30 -Priority 3 -Gain -4
New-Cue -Id coin -Category cards -Source "$casino/chips-handle-*.ogg" -Seconds 0.2 -Gain -5
foreach ($entry in @(
    @('energy_attach','glass','maximize',0.52), @('evolution','maximize','glass',0.95),
    @('heal','confirmation','glass',0.55), @('cleanse','glass','confirmation',0.46),
    @('shield','glass','glitch',0.40), @('counters','tick','drop',0.24),
    @('recoil','drop','error',0.27), @('status_damage','glitch','tick',0.30),
    @('status','question','glitch',0.34), @('status_poisoned','glitch','glass',0.43),
    @('status_burned','scratch','glitch',0.42), @('status_asleep','question','glass',0.58),
    @('status_paralyzed','glitch','switch',0.30), @('status_confused','question','switch',0.45),
    @('attack_failed','error','scratch',0.35), @('direct_ko','minimize','glitch',0.65),
    @('turn_change','confirmation','select',0.36), @('turn_start','confirmation','select',0.36),
    @('turn_end','back','tick',0.23), @('checkup','tick','glass',0.20),
    @('deck_exhausted','error','minimize',0.48), @('victory','confirmation','maximize',0.85),
    @('defeat','minimize','back',0.65), @('draw','question','glass',0.65)
)) {
    $priority = if ($entry[0] -in @('evolution','victory','defeat','draw','direct_ko')) { 3 } else { 2 }
    $effectGain = if ($entry[0] -in @('checkup','turn_end','counters','status_damage')) { -9 } elseif ($entry[0].StartsWith('status_')) { -6 } else { -4 }
    New-Cue -Id $entry[0] -Category 'effects' -Source "$ui/$($entry[1])_*.ogg" -Layer "$ui/$($entry[2])_*.ogg" -Seconds $entry[3] -Priority $priority -Filter 'lowpass=f=5800,aecho=0.8:0.7:55:0.12' -Gain $effectGain
}
New-Cue -Id pokemon_ko -Category battle -Source "$impact/impactSoft_heavy_*.ogg" -Layer "$ui/minimize_*.ogg" -Seconds 0.8 -Priority 3 -Filter 'asetrate=35000,aresample=48000,lowpass=f=2300' -Gain -1
# Attack layers retain the attribute in both normal and heavy hits. A delayed,
# low-passed body adds weight without replacing the element with a generic punch.
$elements = @(
    @('grass','footstep_grass',"$casino/card-slide-*.ogg",'highpass=f=380,lowpass=f=6200,aecho=0.8:0.7:28|62:0.22|0.12','highpass=f=950,lowpass=f=6200',0.34,0.52),
    @('fire','impactMining',"$ui/scratch_*.ogg",'asetrate=35000,aresample=48000,asoftclip=type=tanh:threshold=0.5:output=0.8,lowpass=f=3500','asetrate=37000,aresample=48000,lowpass=f=3200,aecho=0.8:0.7:22|46:0.22|0.12',0.38,0.58),
    @('water','impactSoft_medium',"$ui/glass_*.ogg",'asetrate=35000,aresample=48000,lowpass=f=2400,aphaser=in_gain=0.65:out_gain=0.85:delay=3:decay=0.45:speed=2','asetrate=30000,aresample=48000,lowpass=f=1800,aecho=0.8:0.7:36|73:0.30|0.18',0.42,0.64),
    @('lightning','impactTin_medium',"$ui/glitch_*.ogg",'highpass=f=650,lowpass=f=5300,tremolo=f=28:d=0.65,aecho=0.8:0.7:14|32:0.28|0.15','highpass=f=750,lowpass=f=4300',0.28,0.48),
    @('psychic','impactGlass_light',"$ui/glass_*.ogg",'asetrate=38000,aresample=48000,lowpass=f=4200,aecho=0.8:0.7:70|140:0.30|0.18','asetrate=36000,aresample=48000,lowpass=f=3800,aecho=0.8:0.7:100|190:0.25|0.15',0.50,0.74),
    @('fighting','impactPunch_heavy',"$impact/impactWood_medium_*.ogg",'asetrate=40000,aresample=48000,bass=g=3:f=140,lowpass=f=2800','lowpass=f=1700',0.30,0.48),
    @('darkness','impactSoft_heavy',"$ui/minimize_*.ogg",'asetrate=30000,aresample=48000,lowpass=f=1100,aecho=0.8:0.7:80:0.25','asetrate=32000,aresample=48000,lowpass=f=1350,aecho=0.8:0.7:100:0.25',0.44,0.66),
    @('metal','impactMetal_heavy',"$impact/impactPlate_light_*.ogg",'highpass=f=180,lowpass=f=6000,aecho=0.8:0.7:35|75:0.18|0.1','highpass=f=600,lowpass=f=4400',0.42,0.62),
    @('dragon','impactBell_heavy',"$ui/maximize_*.ogg",'asetrate=31000,aresample=48000,lowpass=f=3300,bass=g=3:f=110,aecho=0.8:0.7:90:0.23','asetrate=35000,aresample=48000,lowpass=f=2600,aecho=0.8:0.7:85|160:0.25|0.14',0.50,0.78),
    @('colorless','impactGeneric_light',"$casino/card-shove-*.ogg",'highpass=f=180,lowpass=f=5200','highpass=f=600,lowpass=f=5200',0.30,0.48)
)
foreach ($element in $elements) {
    $layer = [string]$element[2]
    # Crop the audible attack BEFORE reversal, otherwise long source tails become
    # silence at the start and get amplified by peak normalization.
    New-Cue -Id "attack_charge_$($element[0])" -Category charge -Source "$impact/$($element[1])_*.ogg" -Layer $layer -LayerGain 0.15 -LayerDelay 0 -LayerFilter "atrim=duration=0.17,areverse,$($element[4]),afade=t=in:d=0.10" -Filter "atrim=duration=0.20,areverse,$($element[3]),afade=t=in:d=0.12" -Seconds 0.22 -Priority 2 -Gain -7
    New-Cue -Id "attack_hit_$($element[0])" -Category impact -Source "$impact/$($element[1])_*.ogg" -Layer $layer -LayerGain 0.26 -LayerDelay 9 -LayerFilter $element[4] -Filter $element[3] -Seconds $element[5] -Priority 3 -Gain -2
    New-Cue -Id "attack_heavy_$($element[0])" -Category impact -Source "$impact/$($element[1])_*.ogg" -Layer $layer -LayerGain 0.40 -LayerDelay 14 -LayerFilter $element[4] -Body "$impact/impactPunch_heavy_*.ogg" -Filter "$($element[3]),bass=g=3:f=120" -Seconds $element[6] -Priority 3 -Gain -0.5
}
} else {
    $previous = Get-Content $manifestFile -Raw | ConvertFrom-Json
    foreach ($item in $previous.recipes) { $recipes.Add($item) }
    foreach ($item in $previous.outputs | Where-Object { $_.file -match '^(sfx|cues)/' }) { $outputs.Add($item) }
    foreach ($file in Get-ChildItem (Join-Path $output 'cues') -Filter '*.tres') { $cueIds.Add($file.BaseName) }
}
$trackIds = [Collections.Generic.List[string]]::new()
$musicSources = @()
$musicManifest = Join-Path $PSScriptRoot 'audio/music.json'
if (Test-Path $musicManifest) {
    $musicSources = @(Get-Content $musicManifest -Raw | ConvertFrom-Json)
    foreach ($track in $musicSources) {
        $trackIds.Add($track.id)
        $sourceName = if ($track.PSObject.Properties["source_file"]) { [string]$track.source_file } else { "$($track.id).flac" }
        $sourceFile = Join-Path $cache "music/$sourceName"
        if (-not $SfxOnly) {
            if (-not (Test-Path $sourceFile)) { Invoke-WebRequest $track.url -OutFile $sourceFile -TimeoutSec 180 }
            if ((Get-FileHash $sourceFile).Hash.ToLower() -ne $track.sha256) { throw "Music source hash mismatch: $($track.id)" }
            $analysis = & $ffmpeg -hide_banner -i $sourceFile -t $track.loop_end -af 'loudnorm=I=-20:TP=-2:LRA=11:print_format=json' -f null - 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Music loudness analysis failed: $($track.id)" }
            $measurement = [regex]::Match(($analysis -join "`n"), '(?s)\{\s*"input_i".*?\}').Value | ConvertFrom-Json
            $gain = [Math]::Min(-20.0 - [double]$measurement.input_i, -2.0 - [double]$measurement.input_tp).ToString('0.000000', [Globalization.CultureInfo]::InvariantCulture)
            $endSample = [int64][Math]::Round([double]$track.loop_end * 48000)
            $loopSample = [int64][Math]::Round([double]$track.loop_start * 48000)
            # Mix a sample-aligned pre-roll at the tail; preserve the whole body even
            # when the second input reaches EOF before FFmpeg has decoded the first.
            $tailStart = $endSample - 1920
            $seamStart = $loopSample - 1920
            $filter = "[0:a]aresample=48000,atrim=end_sample=${endSample},asetpts=PTS-STARTPTS,afade=t=out:ss=${tailStart}:ns=1920[body];[1:a]aresample=48000,atrim=start_sample=${seamStart}:end_sample=${loopSample},asetpts=PTS-STARTPTS,afade=t=in:ss=0:ns=1920,adelay=${tailStart}S:all=1[seam];[body][seam]amix=inputs=2:duration=longest:normalize=0,afade=t=in:d=0.004,volume=${gain}dB,atrim=end_sample=${endSample}[out]"
            Invoke-AudioFFmpeg @('-i',$sourceFile,'-i',$sourceFile,'-filter_complex',$filter,'-map','[out]','-ac','2','-c:a','libvorbis','-q:a','5','-fflags','+bitexact',(Join-Path $output "music/$($track.id).ogg"))
        }
        @"
[gd_resource type="Resource" script_class="MusicTrackDefinition" load_steps=3 format=3]

[ext_resource type="Script" path="res://audio/music_track_definition.gd" id="script"]
[ext_resource type="AudioStreamOggVorbis" path="res://assets/audio/music/$($track.id).ogg" id="stream"]

[resource]
script = ExtResource("script")
id = &"$($track.id)"
title = "$($track.title)"
stream = ExtResource("stream")
loop_offset = $($track.loop_start)
"@ | Write-AudioResource -Relative "music/$($track.id).tres"
        Add-Output "music/$($track.id).tres"
        if (Test-Path (Join-Path $output "music/$($track.id).ogg")) { Add-Output "music/$($track.id).ogg" }
    }
}
$cueIds.Sort()
$resourceLines = @('[ext_resource type="Script" path="res://audio/audio_catalog.gd" id="script"]')
$cueRefs = @()
foreach ($id in $cueIds) { $resourceLines += "[ext_resource type=`"Resource`" path=`"res://assets/audio/cues/$id.tres`" id=`"c_$id`"]"; $cueRefs += "ExtResource(`"c_$id`")" }
$trackRefs = @()
foreach ($id in $trackIds) { $resourceLines += "[ext_resource type=`"Resource`" path=`"res://assets/audio/music/$id.tres`" id=`"m_$id`"]"; $trackRefs += "ExtResource(`"m_$id`")" }
@"
[gd_resource type="Resource" script_class="AudioCatalog" load_steps=$($resourceLines.Count + 1) format=3]

$($resourceLines -join "`n")

[resource]
script = ExtResource("script")
cues = Array[Resource]([$($cueRefs -join ', ')])
tracks = Array[Resource]([$($trackRefs -join ', ')])
"@ | Write-AudioResource -Relative 'library.tres'
Add-Output 'library.tres'
foreach ($licenseFile in Get-ChildItem (Join-Path $output 'licenses') -Filter '*.txt' -File) {
    $licenseText = Get-Content -LiteralPath $licenseFile.FullName -Raw
    $licenseText | Write-AudioResource -CleanWhitespace -Relative "licenses/$($licenseFile.Name)"
    Add-Output "licenses/$($licenseFile.Name)"
}
@{ version = 1; tool = 'FFmpeg 7.1.1'; sample_rate = 48000; sources = $sources; music = $musicSources; recipes = $recipes.ToArray(); outputs = $outputs.ToArray() } | ConvertTo-Json -Depth 8 | Set-Content $manifestFile -Encoding utf8
Write-Host "AUDIO_BUILD_OK: $($cueIds.Count) cues, $($cueIds.Count * 3) variants, $($trackIds.Count) tracks"
