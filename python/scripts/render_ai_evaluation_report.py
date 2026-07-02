"""Render a static Chinese HTML report for Godot rule-AI evaluation results."""
from __future__ import annotations

import argparse
import json
from collections import Counter
from html import escape
from pathlib import Path
from typing import Any


DECK_LABELS = {
    "colorless": "一家鼠ex",
    "darkness": "獒教父ex",
    "dragon": "七夕青鸟ex",
    "fighting": "路卡利欧",
    "fire": "烈焰猴",
    "grass": "土台龟",
    "lightning": "皮卡丘ex",
    "psychic": "天然鸟",
    "steel": "苍响·藏玛然特",
    "water": "甲贺忍蛙ex",
}

TERMINAL_REASON_LABELS = {
    "game_over": "正常结束",
    "max_actions": "达到动作上限",
    "setup_failed": "开局失败",
    "choice_failed": "选择失败",
    "no_legal_action": "无合法动作",
    "decision_failed": "决策失败",
    "illegal_action": "非法动作",
}

WINNER_LABELS = {
    "A": "策略 A",
    "B": "策略 B",
    "draw": "平局",
}

MODE_LABELS = {
    "mirror": "镜像换座",
    "balanced": "均衡矩阵",
    "matrix": "跨牌组矩阵",
}


def _pct(value: Any) -> str:
    try:
        return f"{float(value) * 100:.1f}%"
    except (TypeError, ValueError):
        return "0.0%"


def _num(value: Any, digits: int = 1) -> str:
    try:
        return f"{float(value):.{digits}f}"
    except (TypeError, ValueError):
        return "0.0"


def _int(value: Any) -> str:
    try:
        return str(int(value))
    except (TypeError, ValueError):
        return "0"


def _float(value: Any, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _pp(value: Any) -> str:
    try:
        return f"{float(value) * 100:+.1f}pp"
    except (TypeError, ValueError):
        return "+0.0pp"


def _ci(value: Any) -> str:
    if not isinstance(value, dict):
        return "n/a"
    return f"{_pp(value.get('lower'))} 至 {_pp(value.get('upper'))}"


def _strategy_label(payload: dict[str, Any], side: str) -> str:
    strategy = (payload.get("strategies") or {}).get(side) or {}
    label = str(strategy.get("label") or f"策略 {side}")
    ident = str(strategy.get("id") or side)
    return f"{label} ({ident})"


def _diagnostic_count(summary: dict[str, Any]) -> int:
    return sum(
        int(summary.get(key) or 0)
        for key in ("invalid_actions", "choice_failures", "rule_exceptions")
    )


def _decision_diagnostic_count(payload: dict[str, Any]) -> int:
    diagnostics = payload.get("decision_diagnostics") or {}
    return int((diagnostics or {}).get("total") or 0) if isinstance(diagnostics, dict) else 0


def _golden_failure_count(payload: dict[str, Any]) -> int:
    golden = payload.get("golden_scenarios") or {}
    return int((golden or {}).get("failed") or 0) if isinstance(golden, dict) else 0


def _strategies_equal(payload: dict[str, Any]) -> bool:
    fingerprint = payload.get("strategy_fingerprint") or {}
    if isinstance(fingerprint, dict) and fingerprint.get("equal") is not None:
        return bool(fingerprint.get("equal"))
    strategies = payload.get("strategies") or {}
    return strategies.get("A") == strategies.get("B")


def evaluation_verdict(payload: dict[str, Any]) -> str:
    summary = payload.get("summary") or {}
    diagnostics = _diagnostic_count(summary)
    if diagnostics > 0:
        return "诊断未通过：存在非法动作、选择失败或规则异常，暂不判断强度。"
    if _decision_diagnostic_count(payload) > 0:
        return "诊断未通过：存在决策错因计数，暂不判断强度。"
    if _golden_failure_count(payload) > 0:
        return "诊断未通过：关键局面金样例失败。"
    max_action_rate = _float(
        summary.get("max_action_exhaustion_rate"),
        _float(summary.get("max_actions_exhaustions")) / max(1, int(summary.get("games") or 0)),
    )
    if max_action_rate > 0.01:
        return "评测不可靠：动作截断超过 1%，点数率只能作为原始参考。"
    if str(payload.get("eval_preset") or (payload.get("config") or {}).get("eval_preset") or "") == "Smoke":
        return "Smoke 模式：仅验证评测管线，不输出强度结论。"
    if payload.get("self_check") or _strategies_equal(payload):
        return "无强度结论：策略 A 与策略 B 的有效配置相同。"
    paired_pairs = int(summary.get("paired_pairs") or 0)
    games = int(summary.get("games") or 0)
    if games < 30 or paired_pairs < 15:
        return "样本不足：需要更多配对对局才能判断策略强度。"
    interval = summary.get("paired_delta_ci95") or {}
    lower = _float(interval.get("lower") if isinstance(interval, dict) else None)
    upper = _float(interval.get("upper") if isinstance(interval, dict) else None)
    probability = _float(summary.get("probability_a_better"), 0.5)
    if lower > 0.0 and probability >= 0.95:
        return "策略 A 显著领先：配对差值置信区间高于 0。"
    if upper < 0.0 and probability <= 0.05:
        return "策略 B 显著领先：配对差值置信区间低于 0。"
    return "本次样本未显示明确强度差距。"


def _conclusion(payload: dict[str, Any]) -> str:
    return evaluation_verdict(payload)


def _bar(value: float, *, invert: bool = False) -> str:
    value = max(0.0, min(1.0, value))
    klass = "bar-fill alt" if invert else "bar-fill"
    return (
        '<div class="bar">'
        f'<div class="{klass}" style="width:{value * 100:.2f}%"></div>'
        "</div>"
    )


def _kpi_cards(payload: dict[str, Any]) -> str:
    summary = payload.get("summary") or {}
    seat = payload.get("seat") or {}
    seat_counts = seat.get("seat_counts") or {}
    seat_gap = abs(int(seat_counts.get("a_player_0") or 0) - int(seat_counts.get("a_player_1") or 0))
    diagnostics = _diagnostic_count(summary)
    decision_diagnostics = _decision_diagnostic_count(payload)
    golden_failed = _golden_failure_count(payload)
    cards = [
        ("总对局数", _int(summary.get("games")), "已完成的评测对局"),
        ("A 点数率", _pct(summary.get("point_rate")), "raw 胜场 + 0.5 * 平局"),
        ("配对差值", _pp(summary.get("paired_point_delta")), "按 deck/seed 换座聚合"),
        ("配对 CI", _ci(summary.get("paired_delta_ci95")), "bootstrap 95% 区间"),
        ("A 更优概率", _pct(summary.get("probability_a_better")), "bootstrap 配对均值 > 0"),
        ("Clean 点数率", _pct(summary.get("clean_point_rate")), "只统计完整干净对局"),
        ("A 胜率", _pct(summary.get("win_rate")), "原始胜场占比"),
        ("Elo 差值", _num(summary.get("elo_delta")), "由点数率估算"),
        ("完成率", _pct(summary.get("completion_rate")), "正常结束对局占比"),
        ("平均决策", f"{_num(summary.get('average_decision_ms'))} ms", "动作与选择平均耗时"),
        ("P95 决策", f"{_num(summary.get('decision_ms_p95'))} ms", "按对局平均耗时分位"),
        ("座位偏差", _int(seat_gap), "策略 A 的玩家编号不平衡"),
        ("动作截断", _int(summary.get("max_actions_exhaustions")), "达到动作上限的对局"),
        ("诊断问题", _int(diagnostics), "干净评测应为 0"),
        ("决策错因", _int(decision_diagnostics), "错因计数应为 0"),
        ("金样例失败", _int(golden_failed), "关键局面回归失败数"),
    ]
    return "\n".join(
        f"""
        <section class="kpi">
          <span>{escape(title)}</span>
          <strong>{escape(value)}</strong>
          <em>{escape(note)}</em>
        </section>
        """
        for title, value, note in cards
    )


def _deck_rows(payload: dict[str, Any]) -> str:
    per_deck = payload.get("per_deck") or {}
    deck_keys = payload.get("deck_keys") or sorted(per_deck)
    rows = []
    for deck_key in deck_keys:
        stats = per_deck.get(deck_key) or {}
        point_rate = float(stats.get("point_rate") or 0.0)
        rows.append(
            f"""
            <tr>
              <td><b>{escape(DECK_LABELS.get(str(deck_key), str(deck_key)))}</b><span>{escape(str(deck_key))}</span></td>
              <td>{_bar(point_rate)}</td>
              <td>{_pct(point_rate)}</td>
              <td>{_pp(stats.get("paired_point_delta"))}</td>
              <td>{_int(stats.get("wins"))}/{_int(stats.get("draws"))}/{_int(stats.get("losses"))}</td>
              <td>{_num(stats.get("average_score"), 0)}</td>
              <td>{_num(stats.get("average_decision_ms"))} ms</td>
            </tr>
            """
        )
    return "\n".join(rows)


def _matrix_rows(payload: dict[str, Any]) -> str:
    matrix = payload.get("matrix") or {}
    if not matrix:
        return '<tr><td colspan="5">无跨牌组矩阵数据</td></tr>'
    rows = []
    for deck_a in sorted(matrix, key=lambda key: list(DECK_LABELS).index(key) if key in DECK_LABELS else 999):
        opponents = matrix.get(deck_a) or {}
        for deck_b in sorted(opponents, key=lambda key: list(DECK_LABELS).index(key) if key in DECK_LABELS else 999):
            stats = opponents.get(deck_b) or {}
            rows.append(
                f"""
                <tr>
                  <td><b>{escape(DECK_LABELS.get(str(deck_a), str(deck_a)))}</b><span>{escape(str(deck_a))}</span></td>
                  <td><b>{escape(DECK_LABELS.get(str(deck_b), str(deck_b)))}</b><span>{escape(str(deck_b))}</span></td>
                  <td>{_pct(stats.get("point_rate"))}</td>
                  <td>{_int(stats.get("wins"))}/{_int(stats.get("draws"))}/{_int(stats.get("losses"))}</td>
                  <td>{_num(stats.get("average_score"), 0)}</td>
                </tr>
                """
            )
    return "\n".join(rows)


def _diagnostic_rows(payload: dict[str, Any]) -> str:
    labels = (payload.get("decision_diagnostics") or {}).get("labels") or {}
    if not labels:
        return '<tr><td colspan="2">无决策诊断数据</td></tr>'
    rows = []
    for label, count in sorted(labels.items(), key=lambda item: (-int(item[1] or 0), str(item[0]))):
        rows.append(f"<tr><td>{escape(str(label))}</td><td>{_int(count)}</td></tr>")
    return "\n".join(rows)


def _golden_rows(payload: dict[str, Any]) -> str:
    cases = (payload.get("golden_scenarios") or {}).get("cases") or []
    if not cases:
        return '<tr><td colspan="4">无金样例数据</td></tr>'
    rows = []
    for row in cases:
        status = "通过" if row.get("passed") else "失败"
        rows.append(
            f"""
            <tr>
              <td>{escape(str(row.get("name", "")))}</td>
              <td>{escape(status)}</td>
              <td>{escape(str(row.get("expected", "")))}</td>
              <td>{escape(str(row.get("actual", "")))}</td>
            </tr>
            """
        )
    return "\n".join(rows)


def _profile_segment_rows(payload: dict[str, Any]) -> str:
    profile = payload.get("performance_profile") or {}
    segments = profile.get("segments_ms") or {}
    if not profile.get("enabled") or not segments:
        return '<tr><td colspan="2">未启用性能 profile</td></tr>'
    rows = []
    for key, value in sorted(segments.items(), key=lambda item: (-_float(item[1]), str(item[0])))[:20]:
        rows.append(f"<tr><td>{escape(str(key))}</td><td>{_num(value, 3)} ms</td></tr>")
    return "\n".join(rows)


def _profile_count_rows(payload: dict[str, Any]) -> str:
    profile = payload.get("performance_profile") or {}
    counts = profile.get("counts") or {}
    if not profile.get("enabled") or not counts:
        return '<tr><td colspan="2">未启用性能 profile</td></tr>'
    rows = []
    for key, value in sorted(counts.items(), key=lambda item: str(item[0])):
        rows.append(f"<tr><td>{escape(str(key))}</td><td>{_int(value)}</td></tr>")
    return "\n".join(rows)


def _terminal_rows(payload: dict[str, Any]) -> str:
    reasons = payload.get("terminal_reasons") or {}
    if not reasons:
        reasons = Counter(str(row.get("terminal_reason") or "") for row in payload.get("matches") or [])
    total = max(1, sum(int(value) for value in reasons.values()))
    rows = []
    for reason, count in sorted(reasons.items(), key=lambda item: (-int(item[1]), str(item[0]))):
        value = int(count)
        rows.append(
            f"""
            <tr>
              <td>{escape(TERMINAL_REASON_LABELS.get(str(reason), str(reason)))}</td>
              <td>{_bar(value / total, invert=True)}</td>
              <td>{value}</td>
            </tr>
            """
        )
    return "\n".join(rows)


def _seat_rows(payload: dict[str, Any]) -> str:
    seat = payload.get("seat") or {}
    first = seat.get("strategy_a_first") or {}
    second = seat.get("strategy_a_second") or {}
    return f"""
      <tr><td>策略 A 先手</td><td>{_pct(first.get("point_rate"))}</td><td>{_int(first.get("wins"))}/{_int(first.get("draws"))}/{_int(first.get("losses"))}</td><td>{_num(first.get("average_score"), 0)}</td></tr>
      <tr><td>策略 A 后手</td><td>{_pct(second.get("point_rate"))}</td><td>{_int(second.get("wins"))}/{_int(second.get("draws"))}/{_int(second.get("losses"))}</td><td>{_num(second.get("average_score"), 0)}</td></tr>
    """


def _match_rows(payload: dict[str, Any], limit: int = 250) -> str:
    rows = []
    for row in (payload.get("matches") or [])[:limit]:
        rows.append(
            f"""
            <tr>
              <td><b>{escape(DECK_LABELS.get(str(row.get("deck", "")), str(row.get("deck", ""))))}</b><span>{escape(str(row.get("deck", "")))}</span></td>
              <td>{_int(row.get("seed_block"))}</td>
              <td>{_int(row.get("seed"))}</td>
              <td>{escape(WINNER_LABELS.get(str(row.get("winner", "")), str(row.get("winner", ""))))}</td>
              <td>{escape("先手" if row.get("strategy_a_first") else "后手")}</td>
              <td>{_num(row.get("score"), 0)}</td>
              <td>{escape(TERMINAL_REASON_LABELS.get(str(row.get("terminal_reason", "")), str(row.get("terminal_reason", ""))))}</td>
              <td>{_int(row.get("actions"))}</td>
              <td>{_num(row.get("average_decision_ms"))} ms</td>
            </tr>
            """
        )
    return "\n".join(rows)


def render_report(payload: dict[str, Any]) -> str:
    title = "Godot 规则 AI 强度评测"
    strategy_a = _strategy_label(payload, "A")
    strategy_b = _strategy_label(payload, "B")
    summary = payload.get("summary") or {}
    styles = """
    :root { color-scheme: dark; --bg:#10131a; --panel:#191f2b; --panel2:#202838; --text:#eef3ff; --muted:#9aa7bd; --line:#344055; --accent:#46d7a7; --accent2:#7aa7ff; --warn:#ffcc66; --bad:#ff6b6b; }
    * { box-sizing: border-box; }
    body { margin:0; font-family: Inter, "Segoe UI", Arial, sans-serif; background: radial-gradient(circle at top left, #263246 0, #10131a 38rem); color:var(--text); }
    header { padding:34px 42px 22px; border-bottom:1px solid rgba(255,255,255,.08); }
    h1 { margin:0 0 8px; font-size:32px; letter-spacing:0; }
    h2 { margin:0 0 18px; font-size:20px; }
    p { color:var(--muted); margin:6px 0; }
    main { padding:28px 42px 44px; display:grid; gap:24px; }
    .panel { background:linear-gradient(180deg, rgba(32,40,56,.96), rgba(25,31,43,.98)); border:1px solid rgba(255,255,255,.08); border-radius:8px; padding:22px; box-shadow:0 16px 42px rgba(0,0,0,.22); }
    .verdict { display:grid; grid-template-columns: 1.4fr .9fr; gap:20px; align-items:stretch; }
    .verdict strong { font-size:26px; display:block; margin-top:8px; }
    .kpis { display:grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap:14px; }
    .kpi { background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:16px; min-height:116px; }
    .kpi span, .kpi em { display:block; color:var(--muted); font-style:normal; }
    .kpi strong { display:block; font-size:25px; margin:10px 0; }
    .grid2 { display:grid; grid-template-columns: 1.25fr .75fr; gap:24px; }
    .grid3 { display:grid; grid-template-columns: 1fr 1fr; gap:24px; }
    table { width:100%; border-collapse:collapse; }
    th, td { text-align:left; padding:10px 10px; border-bottom:1px solid rgba(255,255,255,.08); vertical-align:middle; }
    th { color:var(--muted); font-weight:600; font-size:13px; }
    td span { display:block; color:var(--muted); font-size:12px; margin-top:3px; }
    .bar { height:16px; min-width:120px; background:#0f141f; border:1px solid var(--line); border-radius:5px; overflow:hidden; }
    .bar-fill { height:100%; background:linear-gradient(90deg, var(--accent), #a6f3d4); }
    .bar-fill.alt { background:linear-gradient(90deg, var(--accent2), #c5d6ff); }
    .meta { display:flex; flex-wrap:wrap; gap:10px; margin-top:14px; }
    .pill { border:1px solid var(--line); background:rgba(255,255,255,.04); border-radius:999px; padding:7px 10px; color:var(--muted); }
    .scroll { max-height:680px; overflow:auto; }
    @media (max-width: 980px) { .verdict, .grid2, .grid3 { grid-template-columns:1fr; } .kpis { grid-template-columns: repeat(2, minmax(0,1fr)); } main, header { padding-left:18px; padding-right:18px; } }
    """
    return f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{escape(title)}</title>
  <style>{styles}</style>
</head>
<body>
  <header>
    <h1>{escape(title)}</h1>
    <p>{escape(strategy_a)} 对比 {escape(strategy_b)}</p>
    <div class="meta">
      <span class="pill">模式：{escape(MODE_LABELS.get(str(payload.get("mode", "mirror")), str(payload.get("mode", "mirror"))))}</span>
      <span class="pill">牌组：{len(payload.get("deck_keys") or [])}</span>
      <span class="pill">对局：{_int(summary.get("games"))}</span>
      <span class="pill">结构版本：{_int(payload.get("schema_version"))}</span>
    </div>
  </header>
  <main>
    <section class="panel verdict">
      <div>
        <h2>结论</h2>
        <strong>{escape(_conclusion(payload))}</strong>
        <p>主指标为策略 A 点数率：胜场加半个平局后除以总对局数。</p>
      </div>
      <div>
        <h2>强度分</h2>
        {_bar(float(summary.get("point_rate") or 0.0))}
        <p>策略 A 点数率 {_pct(summary.get("point_rate"))}；Elo 差值 {_num(summary.get("elo_delta"))}。</p>
      </div>
    </section>
    <section class="kpis">{_kpi_cards(payload)}</section>
    <section class="panel">
      <h2>牌组结果矩阵</h2>
      <table>
        <thead><tr><th>牌组</th><th>策略 A 点数率</th><th>比例</th><th>配对差值</th><th>胜/平/负</th><th>平均分差</th><th>平均决策</th></tr></thead>
        <tbody>{_deck_rows(payload)}</tbody>
      </table>
    </section>
    <section class="panel">
      <h2>跨牌组矩阵</h2>
      <table>
        <thead><tr><th>策略 A 牌组</th><th>策略 B 牌组</th><th>A 点数率</th><th>胜/平/负</th><th>平均分差</th></tr></thead>
        <tbody>{_matrix_rows(payload)}</tbody>
      </table>
    </section>
    <section class="grid2">
      <div class="panel">
        <h2>先后手偏差</h2>
        <table>
          <thead><tr><th>座位</th><th>点数率</th><th>胜/平/负</th><th>平均分差</th></tr></thead>
          <tbody>{_seat_rows(payload)}</tbody>
        </table>
      </div>
      <div class="panel">
        <h2>终局原因</h2>
        <table>
          <thead><tr><th>原因</th><th>占比</th><th>对局</th></tr></thead>
          <tbody>{_terminal_rows(payload)}</tbody>
        </table>
      </div>
    </section>
    <section class="grid3">
      <div class="panel">
        <h2>决策诊断</h2>
        <table>
          <thead><tr><th>错因</th><th>次数</th></tr></thead>
          <tbody>{_diagnostic_rows(payload)}</tbody>
        </table>
      </div>
      <div class="panel">
        <h2>金样例</h2>
        <table>
          <thead><tr><th>场景</th><th>状态</th><th>期望</th><th>实际</th></tr></thead>
          <tbody>{_golden_rows(payload)}</tbody>
        </table>
      </div>
    </section>
    <section class="grid3">
      <div class="panel">
        <h2>性能 Profile</h2>
        <table>
          <thead><tr><th>阶段</th><th>累计耗时</th></tr></thead>
          <tbody>{_profile_segment_rows(payload)}</tbody>
        </table>
      </div>
      <div class="panel">
        <h2>Profile 计数</h2>
        <table>
          <thead><tr><th>指标</th><th>次数</th></tr></thead>
          <tbody>{_profile_count_rows(payload)}</tbody>
        </table>
      </div>
    </section>
    <section class="panel scroll">
      <h2>对局明细</h2>
      <table>
        <thead><tr><th>牌组</th><th>区块</th><th>种子</th><th>胜者</th><th>A 座位</th><th>分差</th><th>原因</th><th>动作数</th><th>决策耗时</th></tr></thead>
        <tbody>{_match_rows(payload)}</tbody>
      </table>
    </section>
  </main>
</body>
</html>
"""


def render_file(input_path: Path, output_path: Path) -> None:
    payload = json.loads(input_path.read_text(encoding="utf-8"))
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(render_report(payload), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    render_file(args.input, args.output)
    print(json.dumps({"report": str(args.output)}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
