"""Package Godot's actual rendered action frames into GIFs and a local viewer.

Run after test_battle3d_graphics.ps1. Requires Pillow; no video encoder is used.
Recorded timestamps determine playback speed. A short hold separates loops.
"""

from pathlib import Path
import html
import json

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
REVIEW = ROOT / "build" / "animation-review"
FONT = ImageFont.truetype(str(ROOT / "godot/assets/ui/fonts/NotoSansCJKsc-VF.ttf"), 19)


def frames_for(record):
    return [
        Image.open(REVIEW / record["key"] / f"{index:04d}.png").convert("RGB")
        for index in range(record["captures"])
    ]


def durations_for(record):
    timestamps = record["timestamps_ms"]
    durations = [max(10, round((b - a) / 10) * 10) for a, b in zip(timestamps, timestamps[1:])]
    durations.append(500)
    durations[0] += 250
    return durations


def gif_frames(frames, size=(960, 576)):
    # One palette per action keeps the stationary table stable between frames
    # and lets the GIF encoder store only the pixels that actually changed.
    samples = min(8, len(frames))
    mosaic = Image.new("RGB", (320, 192 * samples))
    for index in range(samples):
        frame = frames[round(index * (len(frames) - 1) / max(1, samples - 1))]
        mosaic.paste(frame.resize((320, 192), Image.Resampling.LANCZOS), (0, index * 192))
    palette = mosaic.quantize(colors=256)
    return [frame.resize(size, Image.Resampling.LANCZOS).quantize(palette=palette, dither=Image.Dither.NONE) for frame in frames]


def save_gif(path, frames, durations):
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=durations, loop=0, disposal=1, optimize=True)


def main():
    manifest = json.loads((REVIEW / "motion-review.json").read_text(encoding="utf-8"))
    records = manifest["records"]
    selected = ["deck_shuffled", "pokemon_evolved", "energy_attached", "coin_flip"]
    highlights = {}
    rows = []
    for record in records:
        key = record["key"]
        frames = frames_for(record)
        timings = durations_for(record)
        encoded = gif_frames(frames)
        save_gif(REVIEW / f"{key}.gif", encoded, timings)
        if key in selected:
            highlights[key] = (encoded, timings)
        sheet = Image.new("RGB", (960, 440), "#f2eadb")
        draw = ImageDraw.Draw(sheet)
        for cell in range(6):
            index = round((len(frames) - 1) * cell / 5)
            x, y = (cell % 3) * 320, (cell // 3) * 220
            draw.text((x + 8, y + 2), f'{record["timestamps_ms"][index]} ms', font=FONT, fill="#584832")
            sheet.paste(frames[index].resize((320, 192), Image.Resampling.LANCZOS), (x, y + 27))
        sheet.save(REVIEW / f"{key}-storyboard.jpg", quality=94)
        label = record.get("label", record["kind"]) + (" · 对手视角" if record["viewer"] else "")
        rows.append({"key": key, "label": label, "frames": record["captures"]})
        print(f"ANIMATION_REVIEW {key} frames={len(frames)}")
    reel, timings = [], []
    for key in selected:
        frames, durations = highlights[key]
        reel.extend(frames)
        timings.extend(durations)
    save_gif(REVIEW / "highlights.gif", reel, timings)
    options = "\n".join(f'<option value="{html.escape(row["key"])}">{html.escape(row["label"])}</option>' for row in rows)
    first = html.escape(rows[0]["key"])
    page = """<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>PTCG 完整动作预览</title>
<style>body{margin:28px auto;padding:0 20px;max-width:1080px;background:#eee4d1;color:#493d2c;font:16px/1.6 system-ui,sans-serif}h1{font-size:26px}p{color:#6c5c45}select,button{font:inherit;padding:10px 14px;border:1px solid #bda67e;border-radius:8px;background:#fff9ee;color:#493d2c;margin:0 8px 16px 0}img{width:100%;height:auto;border-radius:10px;border:1px solid #c8b58f;box-shadow:0 10px 32px #48371f15}a{color:#855b28}</style>
<h1>PTCG 完整动作预览</h1>
<p>Godot Compatibility 实际渲染 · 标准模式 / 高画质 · 原始录制 1280×768。GIF 按采样时间播放，循环前后保留短暂停顿。可切换连续播放或关键帧。</p>
<select id="action">OPTIONS</select><button id="mode">查看关键帧</button><button id="replay">重播</button>
<img id="frame" src="FIRST.gif" alt="所选动作的完整过程">
<p><a href="../animation-preview/verification.md">验证结果</a> · <a href="motion-review.json">逐帧采样记录</a> · <a href="highlights.gif">洗牌、进化、附能、硬币合辑</a></p>
<script>let still=false;const picker=document.querySelector('#action'),frame=document.querySelector('#frame');function update(){frame.src=picker.value+(still?'-storyboard.jpg':'.gif')+'?replay='+Date.now();}picker.onchange=update;document.querySelector('#mode').onclick=()=>{still=!still;document.querySelector('#mode').textContent=still?'连续播放':'查看关键帧';update();};document.querySelector('#replay').onclick=update;</script></html>"""
    (REVIEW / "index.html").write_text(page.replace("OPTIONS", options).replace("FIRST", first), encoding="utf-8")
    (REVIEW / "README.md").write_text(
        "# PTCG 完整动作录像\n\n标准模式 / 高画质；实际帧时间播放，循环前后保留短暂停顿。\n\n"
        "[交互预览](index.html) · [重点动作合辑](highlights.gif) · [验证报告](../animation-preview/verification.md)\n\n"
        + "\n".join(f'- [{row["label"]}]({row["key"]}.gif) · [关键帧]({row["key"]}-storyboard.jpg)' for row in rows)
        + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
