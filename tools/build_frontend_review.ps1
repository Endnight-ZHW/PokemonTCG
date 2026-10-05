[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$frontendReviewRepo = Split-Path -Parent $PSScriptRoot
$frontendReviewDirectory = Join-Path $frontendReviewRepo 'build/frontend-redesign'
New-Item -ItemType Directory -Force -Path $frontendReviewDirectory | Out-Null
@'
<!doctype html>
<html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>对战外界面 · 设计验收</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#faf7f0;color:#213653;font:16px/1.6 system-ui,"Microsoft YaHei",sans-serif}main{max-width:1520px;margin:auto;padding:36px}h1{font-size:32px;margin:0 0 8px}p{color:#56677e;margin:4px 0 22px}nav{display:flex;gap:12px;flex-wrap:wrap;margin:22px 0}select,button,a.action{font:inherit;padding:10px 18px;border:1px solid #8190a4;border-radius:14px;background:white;color:#213653;min-height:48px}button{cursor:pointer}.compare{display:grid;grid-template-columns:1fr 1fr;gap:22px}figure{margin:0;background:white;border-radius:22px;overflow:hidden;box-shadow:0 8px 28px #21365310}figcaption{padding:14px 18px;font-weight:600}img{display:block;width:100%;height:auto}h2{margin-top:36px}#states{display:grid;grid-template-columns:repeat(3,1fr);gap:18px}#report{white-space:pre-wrap;background:#edf1f5;border-radius:18px;padding:20px}.only-after .compare{grid-template-columns:1fr}.only-after #beforeFigure{display:none}a{color:inherit;text-decoration:none}@media(max-width:800px){main{padding:18px}.compare,#states{grid-template-columns:1fr}}
</style><main>
<h1>对战外界面 · 设计验收</h1><p>选牌、联机、设置、帮助、卡牌详情、牌组详情和结算。点击截图可打开原图。</p>
<nav><select id="page" aria-label="页面"></select><select id="size" aria-label="窗口尺寸"></select><button id="toggle">只看改造后</button></nav>
<div class="compare"><figure id="beforeFigure"><figcaption>改造前 · 1600 × 900</figcaption><a id="beforeLink" target="_blank"><img id="before" alt="改造前"></a></figure><figure><figcaption id="afterCaption">改造后</figcaption><a id="afterLink" target="_blank"><img id="after" alt="改造后"></a></figure></div>
<h2>关键交互状态</h2><p>双方选用同一牌组、联机创建／加入与等待、单人换牌、设置保存失败、帮助分类、赏卡与结算。</p><div id="states"></div>
<h2>验收记录</h2><div id="report">14 套牌组、十属性、七种尺寸。性能与验收结果以本次测试日志和 validation.json 为准。
帧耗时及生命周期完整记录：build/frontend-club/validation.json
测试日志：build/frontend-redesign/full-regression.log、remaining-regression.log、remaining-regression2.log、graphics.log。</div>
</main><script>
const pages={decks:'选牌与准备',network:'联机大厅',settings:'设置',help:'玩法帮助','card-inspector':'卡牌详情','deck-detail':'牌组详情','card-art':'完整赏卡',end:'对战结算'};
const sizes=['1600x900','1024x768','1280x720','1920x1080','2000x900','900x540','640x960'];
const page=document.querySelector('#page'),size=document.querySelector('#size');
Object.entries(pages).forEach(([key,label])=>page.add(new Option(label,key)));sizes.forEach(key=>size.add(new Option(key.replace('x',' × '),key)));
function update(){const previous=`before/${page.value}-1600x900.png`,next=`../frontend-club/after/${page.value}-${size.value}.png`;document.querySelector('#before').src=previous;document.querySelector('#after').src=next;document.querySelector('#beforeLink').href=previous;document.querySelector('#afterLink').href=next;document.querySelector('#afterCaption').textContent=`改造后 · ${pages[page.value]} · ${size.selectedOptions[0].text}`}
document.querySelector("#before").onerror=()=>{document.querySelector("#beforeFigure figcaption").textContent="未保存改造前截图，可选择只看改造后"};page.onchange=size.onchange=update;update();document.querySelector('#toggle').onclick=e=>{document.body.classList.toggle('only-after');e.target.textContent=document.body.classList.contains('only-after')?'前后对照':'只看改造后'};
const states={'decks-local-same-deck':'本地：同牌组对战','decks-challenge-same-deck':'挑战 AI：双方选用','network-lan-host':'LAN 创建','network-lan-join':'LAN 加入','network-lan-state-3':'LAN 等待与复制','network-relay-host':'互联网创建','network-relay-join':'互联网加入','network-relay-state-3':'房间码等待状态','network-relay-state-5':'连接失败重试','deck-picker-relay':'单人牌组选择','settings-0':'声音草稿','settings-1':'画质与动画','settings-2':'高级设置','settings-save-failed':'保存失败保留表单','help-0':'快速开始','help-1':'回合流程','help-2':'区域示意','help-3':'联机流程','card-detail':'结构化卡牌详情','card-art':'完整卡图','result-winner':'胜者与代表卡','result-draw':'中性平局','result-missing':'代表卡缺失','result-network':'联机结算导航','result-celebration':'一次轻庆祝'};
for(const [key,label] of Object.entries(states)){const figure=document.createElement('figure');figure.innerHTML=`<a href="states/${key}.png" target="_blank"><img loading="lazy" src="states/${key}.png" alt="${label}"></a><figcaption>${label}</figcaption>`;document.querySelector('#states').append(figure)}
</script></html>

'@ | Set-Content -LiteralPath (Join-Path $frontendReviewDirectory 'review.html') -Encoding utf8
Write-Host ('Frontend review: ' + (Join-Path $frontendReviewDirectory 'review.html'))
