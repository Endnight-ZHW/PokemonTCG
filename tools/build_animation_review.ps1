[CmdletBinding()]
param(
    [string]$BeforeDirectory = '',
    [string]$AfterDirectory = '',
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
$reviewRepo = Split-Path -Parent $PSScriptRoot
if (-not $BeforeDirectory) { $BeforeDirectory = Join-Path $reviewRepo 'build/battle-animation-upgrade/before/animation-review' }
if (-not $AfterDirectory) { $AfterDirectory = Join-Path $reviewRepo 'build/animation-review' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $reviewRepo 'build/battle-animation-upgrade' }
$reviewOutput = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $reviewOutput | Out-Null

function Read-AnimationReview([string]$Directory) {
    $manifest = Join-Path $Directory 'motion-review.json'
    if (-not (Test-Path -LiteralPath $manifest)) { return @{ records = @(); base = '' } }
    $data = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
    return @{
        records = @($data.records)
        base = ([IO.Path]::GetRelativePath($reviewOutput, [IO.Path]::GetFullPath($Directory))).Replace('\', '/')
    }
}
$reviewPayload = @{
    before = Read-AnimationReview $BeforeDirectory
    after = Read-AnimationReview $AfterDirectory
} | ConvertTo-Json -Depth 12 -Compress
if (($reviewPayload | ConvertFrom-Json).after.records.Count -eq 0) { throw 'Record the animation motion review before building the player.' }
$reviewPayload = $reviewPayload.Replace('<', '\u003c')
$html = @'
<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>PTCG · 对局动画对照</title>
<style>
:root{color-scheme:light;font:16px system-ui,sans-serif;color:#4a372a;background:#f4eee4}*{box-sizing:border-box}body{margin:0;padding:28px;max-width:1900px;margin-inline:auto}h1{font-size:26px;margin:0 0 8px}p{color:#776554}header{margin-bottom:24px}.controls{display:flex;align-items:center;gap:12px;flex-wrap:wrap;padding:16px;background:#fffaf2;border:1px solid #d9c8af;border-radius:14px}button,select{font:inherit;min-height:44px;padding:8px 14px;border:1px solid #bd9b76;background:#fffaf2;color:inherit;border-radius:9px}button{cursor:pointer;background:#a86334;color:white}input{flex:1;min-width:180px;accent-color:#a86334}.compare{display:grid;grid-template-columns:1fr 1fr;gap:18px;margin-top:20px}article{min-width:0}h2{font-size:16px;display:flex;justify-content:space-between}h2 span{font-size:13px;font-weight:400;color:#7c6a58}figure{margin:0;aspect-ratio:5/3;background:#e6dac6;border-radius:12px;overflow:hidden;display:grid;place-items:center}img{display:block;width:100%;height:100%;object-fit:contain}footer{font-size:13px;color:#7c6a58;margin-top:18px}#status{min-height:24px}@media(max-width:900px){.compare{grid-template-columns:1fr}body{padding:14px}}
img[hidden]{display:none}
</style>
<header><h1>PTCG · 对局动画对照</h1><p>相同动作，按实际录制时间播放。可暂停、拖动时间轴或慢放，检查蓄力、接触和落地全过程。</p></header>
<div class="controls"><select id="action" aria-label="选择动作"></select><button id="play">暂停</button><select id="speed" aria-label="播放速度"><option value="0.5">0.5× 慢放</option><option value="1" selected>1× 原速</option><option value="2">2×</option></select><input id="seek" aria-label="时间轴" type="range" min="0" max="1000" value="0"><output id="time">0 ms</output></div>
<div class="compare"><article><h2>修改前 <span id="beforeInfo"></span></h2><figure id="beforeFrame"><img id="beforeImage" alt="修改前动画帧"></figure></article><article><h2>修改后 <span id="afterInfo"></span></h2><figure><img id="afterImage" alt="修改后动画帧"></figure></article></div>
<p id="status" role="status"></p><footer>画面来自真实 Godot Compatibility 渲染。录像无音轨；音画同步请在 Workbench 中试听。较短的动作结束后保留最后一帧，便于比较真实节奏。</footer>
<script>
const data=__REVIEW_DATA__;
const $=id=>document.getElementById(id), action=$('action'), seek=$('seek');
let pair={},duration=1,elapsed=0,playing=true,last=0,generation=0,ready=false;
for(const row of data.after.records){const option=document.createElement('option');option.value=row.key;option.textContent=row.label+(row.element?' · '+row.element:'')+(row.viewer?' · 对手视角':'');action.append(option)}
function frameUrl(group,row,index){return group.base+'/'+encodeURIComponent(row.key)+'/'+String(index).padStart(4,'0')+'.png'}
function paint(){for(const name of ['before','after']){const row=pair[name],img=$(name+'Image');img.hidden=!row;if(!row)continue;let index=0;for(let i=0;i<row.timestamps_ms.length;i++){if(row.timestamps_ms[i]>elapsed)break;index=i}const url=frameUrl(data[name],row,index);if(img.dataset.frame!==url){img.src=url;img.dataset.frame=url}}seek.value=Math.round(elapsed/duration*1000);$('time').textContent=Math.round(Math.min(elapsed,duration))+' / '+Math.round(duration)+' ms'}
async function select(){const run=++generation;ready=false;elapsed=0;pair.after=data.after.records.find(r=>r.key===action.value);pair.before=data.before.records.find(r=>r.key===action.value);duration=Math.max(...['before','after'].map(n=>pair[n]?.timestamps_ms.at(-1)||1));$('status').textContent='正在预载动画帧…';const jobs=[];for(const name of ['before','after']){const row=pair[name];$(name+'Info').textContent=row?row.timestamps_ms.at(-1)+' ms · '+row.captures+' 帧':'此新增演出没有旧基线';if(!row)continue;for(let i=0;i<row.captures;i++)jobs.push(new Promise(resolve=>{const image=new Image();image.onload=()=>resolve(true);image.onerror=()=>resolve(false);image.src=frameUrl(data[name],row,i)}))}const loaded=await Promise.all(jobs);if(run!==generation)return;ready=true;$('status').textContent=loaded.every(Boolean)?'已预载，可逐帧拖动检查。':'部分帧缺失，请重新运行录制脚本。';paint()}
$('play').onclick=()=>{playing=!playing;$('play').textContent=playing?'暂停':'播放'};action.onchange=select;seek.oninput=()=>{elapsed=Number(seek.value)/1000*duration;playing=false;$('play').textContent='播放';paint()};function tick(now){const delta=last?now-last:0;last=now;if(ready&&playing){elapsed+=Math.min(delta,100)*Number($('speed').value);if(elapsed>duration+450)elapsed=0;paint()}requestAnimationFrame(tick)}select();requestAnimationFrame(tick);
</script></html>
'@
$html.Replace('__REVIEW_DATA__', $reviewPayload) | Set-Content -LiteralPath (Join-Path $reviewOutput 'review.html') -Encoding utf8
Write-Host "ANIMATION_REVIEW_READY $(Join-Path $reviewOutput 'review.html')"
