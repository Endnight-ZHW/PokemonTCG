"""Render the self-contained schema-v6 Godot AI evaluation dashboard."""
from __future__ import annotations

import argparse
import json
from html import escape
from pathlib import Path
from typing import Any

try:
    from scripts.ai_evaluation_v6 import DECK_ORDER, SCHEMA_VERSION
except ModuleNotFoundError:  # Direct script execution.
    from ai_evaluation_v6 import DECK_ORDER, SCHEMA_VERSION


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
    "max_actions": "动作上限耗尽",
    "setup_failed": "开局失败",
    "choice_failed": "Choice 异常",
    "no_legal_action": "无合法动作",
    "legal_query_failed": "合法动作查询失败",
    "decision_failed": "决策失败",
    "illegal_action": "非法动作",
}


def _float(value: Any) -> float | None:
    try:
        result = float(value)
    except (TypeError, ValueError, OverflowError):
        return None
    return result


def _number(value: Any, digits: int = 1, suffix: str = "") -> str:
    parsed = _float(value)
    return "—" if parsed is None else f"{parsed:.{digits}f}{suffix}"


def _integer(value: Any) -> str:
    try:
        return f"{int(value):,}"
    except (TypeError, ValueError, OverflowError):
        return "—"


def _pct(value: Any, *, signed: bool = False) -> str:
    parsed = _float(value)
    if parsed is None:
        return "—"
    sign = "+" if signed and parsed >= 0 else ""
    return f"{sign}{parsed * 100:.1f}%"


def _pp(value: Any) -> str:
    parsed = _float(value)
    return "—" if parsed is None else f"{parsed * 100:+.1f}pp"


def _ci(value: Any) -> str:
    if not isinstance(value, dict):
        return "—"
    return f"[{_pp(value.get('lower'))}, {_pp(value.get('upper'))}]"


def _deck_label(deck: str) -> str:
    return DECK_LABELS.get(deck, deck)


def _strategy_label(payload: dict[str, Any], side: str) -> str:
    strategy = (payload.get("strategies") or {}).get(side) or {}
    label = str(strategy.get("label") or f"策略 {side}")
    ident = str(strategy.get("id") or side)
    return f"{label} ({ident})"


def _strength(payload: dict[str, Any], key: str) -> dict[str, Any]:
    scope = (payload.get("strength") or {}).get(key) or {}
    return scope if isinstance(scope, dict) else {}


def _significant_a(payload: dict[str, Any]) -> bool:
    intervals = []
    for key in ("mirror", "cross_role"):
        interval = ((_strength(payload, key).get("overall") or {}).get("ci95") or {})
        intervals.append(_float(interval.get("lower")))
    return all(value is not None and value > 0 for value in intervals)


def evaluation_verdict(
    payload: dict[str, Any], validation: dict[str, Any] | None = None
) -> str:
    if int(payload.get("schema_version") or 0) != SCHEMA_VERSION:
        raise ValueError(f"Only AI evaluation schema v{SCHEMA_VERSION} is supported.")
    if validation is None:
        return "未执行门禁：以下强度区间与诊断信息仅供查看。"
    gate = str(validation.get("gate") or "")
    if gate in {"smoke", "quick"}:
        if not validation.get("valid"):
            state = "覆盖检查失败"
        elif validation.get("warnings"):
            state = "覆盖检查完成但存在警告"
        else:
            state = "覆盖检查完成"
        return f"{state}；Smoke/Quick 不输出策略强度结论。"
    if not validation.get("valid"):
        messages = [str(row.get("message") or row.get("code")) for row in validation.get("errors") or []]
        return "门禁未通过：" + ("；".join(messages[:3]) if messages else "存在结构化失败项。")
    if gate == "nightly-equivalence":
        suffix = "；且两项主指标均显示 A 统计上显著更强。" if _significant_a(payload) else "；这不等同于统计上显著更强。"
        return "通过等价性门禁" + suffix
    if gate == "nightly-superiority":
        return "通过保守优势门禁；镜像与角色交叉指标的 95% CI 下界均大于 0。"
    if gate == "nightly-stability":
        return "通过同策略稳定性门禁；该门禁不产生强度结论。"
    if gate == "deep-practical":
        return "通过 Deep 实用性门禁；镜像与角色交叉指标均满足容忍下界且零回退。"
    return "门禁通过。"


def _metric_card(title: str, value: str, note: str, tone: str = "") -> str:
    return (
        f'<article class="metric {escape(tone)}"><span>{escape(title)}</span>'
        f'<strong>{escape(value)}</strong><small>{escape(note)}</small></article>'
    )


def _delta_bar(value: Any, interval: Any, title: str) -> str:
    delta = _float(value)
    marker = 50.0 if delta is None else max(2.0, min(98.0, 50.0 + delta * 250.0))
    return (
        '<div class="delta-row">'
        f'<div><b>{escape(title)}</b><span>{escape(_pp(value))} · 95% CI {escape(_ci(interval))}</span></div>'
        '<div class="delta-track"><i class="zero"></i>'
        f'<i class="marker" style="left:{marker:.2f}%"></i></div>'
        '<div class="axis-labels"><span>偏向 B</span><span>0</span><span>偏向 A</span></div></div>'
    )


def _heat_color(value: float | None, *, raw: bool = False) -> str:
    if value is None:
        return "rgba(148,163,184,.10)"
    centered = value - 0.5 if raw else value
    alpha = min(0.82, 0.12 + abs(centered) * (2.8 if raw else 5.2))
    rgb = "34,197,94" if centered >= 0 else "239,68,68"
    return f"rgba({rgb},{alpha:.3f})"


def _fair_value(payload: dict[str, Any], row: str, column: str) -> float | None:
    if row == column:
        stats = (_strength(payload, "mirror").get("per_deck") or {}).get(row) or {}
    else:
        key = "_and_".join(sorted((row, column)))
        stats = (_strength(payload, "cross_role").get("per_unordered_matchup") or {}).get(key) or {}
    return _float((stats.get("overall") or {}).get("point_delta"))


def _raw_value(payload: dict[str, Any], row: str, column: str) -> float | None:
    stats = ((payload.get("raw_matrix") or {}).get(row) or {}).get(column) or {}
    return _float(stats.get("point_rate"))


def _heatmap(payload: dict[str, Any], *, raw: bool) -> str:
    decks = [str(deck) for deck in payload.get("deck_keys") or []]
    title = "原始对局视图（不参与强度门禁）" if raw else "公平调整视图（门禁统计单元）"
    description = (
        "行是策略 A 实际驾驶牌组，列是策略 B 实际驾驶牌组；显示 A 原始点数率。"
        if raw
        else "对角线为两局镜像差值；非对角线为四局角色交叉差值，矩阵关于对角线对称。"
    )
    head = "".join(f"<th title='{escape(deck)}'>{escape(_deck_label(deck))}</th>" for deck in decks)
    rows = []
    for row in decks:
        cells = []
        for column in decks:
            value = _raw_value(payload, row, column) if raw else _fair_value(payload, row, column)
            text = _pct(value) if raw else _pp(value)
            cells.append(
                f'<td style="background:{_heat_color(value, raw=raw)}" title="{escape(row)} × {escape(column)}">{escape(text)}</td>'
            )
        rows.append(f"<tr><th>{escape(_deck_label(row))}</th>{''.join(cells)}</tr>")
    return (
        f"<section><h2>{escape(title)}</h2><p class='muted'>{escape(description)}</p>"
        f"<div class='table-scroll'><table class='heat'><thead><tr><th>A \\ B</th>{head}</tr></thead>"
        f"<tbody>{''.join(rows)}</tbody></table></div></section>"
    )


def _fairness_table(
    payload: dict[str, Any], validation: dict[str, Any] | None
) -> str:
    coverage = payload.get("coverage") or {}
    fairness = payload.get("fairness") or {}
    config = payload.get("config") or {}
    canonical_nightly = str((validation or {}).get("gate") or "").startswith("nightly-")
    expected_games = 2800 if canonical_nightly else int(coverage.get("expected_games") or 0)
    expected_mirror = 500 if canonical_nightly else int(coverage.get("expected_mirror_units") or 0)
    expected_cross = 450 if canonical_nightly else int(coverage.get("expected_cross_units") or 0)
    actual_games = int(coverage.get("actual_games") or 0)
    actual_mirror = int(coverage.get("complete_mirror_units") or 0)
    actual_cross = int(coverage.get("complete_cross_units") or 0)
    missing_count = max(
        int(coverage.get("missing_match_count") or 0),
        expected_games - actual_games if canonical_nightly else 0,
    )
    unexpected_count = int(coverage.get("unexpected_match_count") or 0)
    shard_indices = [int(value) for value in coverage.get("source_task_shard_indices") or []]
    shard_counts = [int(value) for value in coverage.get("source_task_shard_counts") or []]
    shard_count = max(shard_counts, default=1)
    shards_complete = shard_indices == list(range(shard_count))
    checks = [
        ("发布牌组", 10 if canonical_nightly else len(payload.get("deck_keys") or []), len(payload.get("deck_keys") or []), not canonical_nightly or len(payload.get("deck_keys") or []) == 10),
        ("总局数", expected_games, actual_games, actual_games == expected_games and bool(coverage.get("complete"))),
        ("镜像两局块", expected_mirror, actual_mirror, actual_mirror == expected_mirror and bool(fairness.get("mirror_units_complete"))),
        ("交叉四局块", expected_cross, actual_cross, actual_cross == expected_cross and (bool(fairness.get("cross_units_complete")) or expected_cross == 0)),
        ("缺失 / 意外比赛", "0 / 0", f"{missing_count} / {unexpected_count}", missing_count == 0 and unexpected_count == 0),
        ("base seed", 17 if canonical_nightly else config.get("seed"), config.get("seed"), not canonical_nightly or int(config.get("seed") or -1) == 17),
        ("玩家编号与先后手", "完全平衡", "平衡" if fairness.get("assignment_balanced") else "不平衡", bool(fairness.get("assignment_balanced"))),
        ("按策略牌组角色", "完全平衡", "平衡" if fairness.get("per_strategy_deck_balanced") else "不平衡", bool(fairness.get("per_strategy_deck_balanced"))),
        ("分片覆盖", list(range(shard_count)), shard_indices, shards_complete),
    ]
    body = "".join(
        f"<tr><td>{escape(str(name))}</td><td>{escape(str(expected))}</td><td>{escape(str(actual))}</td>"
        f"<td><span class='pill {'ok' if passed else 'bad'}'>{'通过' if passed else '失败'}</span></td></tr>"
        for name, expected, actual, passed in checks
    )
    return f"<section><h2>公平性审计</h2><div class='table-scroll'><table><thead><tr><th>项目</th><th>期望</th><th>实际</th><th>状态</th></tr></thead><tbody>{body}</tbody></table></div></section>"


def _validation_section(validation: dict[str, Any] | None) -> str:
    if validation is None:
        return "<section><h2>门禁详情</h2><p class='muted'>本次未执行门禁。</p></section>"
    issues = list(validation.get("errors") or []) + list(validation.get("warnings") or [])
    issue_rows = "".join(
        f"<tr><td>{escape(str(row.get('section') or ''))}</td><td><code>{escape(str(row.get('code') or ''))}</code></td><td>{escape(str(row.get('message') or ''))}</td><td><code>{escape(json.dumps(row.get('details') or {}, ensure_ascii=False))}</code></td></tr>"
        for row in issues
    ) or "<tr><td colspan='4'>无失败或警告</td></tr>"
    check_rows = "".join(
        f"<tr><td>{escape(str(row.get('section') or ''))}</td><td>{escape(str(row.get('summary') or row.get('id') or ''))}</td><td><span class='pill {'ok' if row.get('status') == 'pass' else 'bad'}'>{escape(str(row.get('status') or ''))}</span></td></tr>"
        for row in validation.get("checks") or []
    )
    return (
        "<section><h2>门禁详情</h2><div class='split'><div class='table-scroll'><table><thead><tr><th>域</th><th>检查</th><th>状态</th></tr></thead>"
        f"<tbody>{check_rows}</tbody></table></div><div class='table-scroll'><table><thead><tr><th>域</th><th>代码</th><th>原因</th><th>详情</th></tr></thead><tbody>{issue_rows}</tbody></table></div></div></section>"
    )


def _behavior_section(payload: dict[str, Any]) -> str:
    decks = [str(deck) for deck in payload.get("deck_keys") or []]
    options = ["<option value='overall'>总体</option>"] + [
        f"<option value='{escape(deck)}'>{escape(_deck_label(deck))}</option>" for deck in decks
    ]
    return (
        "<section><div class='section-title'><div><h2>A/B 行为画像</h2><p class='muted'>诊断用途，不参与门禁。合法机会选择率 = 选择次数 / 该类别曾合法的决策次数。</p></div>"
        f"<label>实际驾驶牌组 <select id='behavior-deck'>{''.join(options)}</select></label></div>"
        "<div id='behavior-summary' class='mini-cards'></div><div class='table-scroll'><table><thead><tr><th>动作类别</th><th>A 选择占比</th><th>B 选择占比</th><th>A 有机会时选择率</th><th>B 有机会时选择率</th><th>A/B 合法机会</th></tr></thead><tbody id='behavior-body'></tbody></table></div>"
        "<h3>Choice 请求覆盖</h3><div id='choice-coverage' class='tag-list'></div></section>"
    )


def _search_depth_section(payload: dict[str, Any], validation: dict[str, Any] | None) -> str:
    performance = payload.get("performance") or {}
    latency = performance.get("metrics") or {}
    search_depth = performance.get("search_depth") or {}
    by_strategy = search_depth.get("by_strategy") or {}
    thresholds = (validation or {}).get("search_depth_thresholds") or {}
    depth_rows = []
    depth_specs = (
        ("requested_depth_min", "固定请求深度", "requested_depth_min"),
        ("completed_depth_p50", "完整层深度 P50", None),
        ("completed_depth_p95", "完整层深度 P95", None),
        (
            "complete_or_frontier_exhausted_rate",
            "完整深度或空间耗尽率",
            "complete_or_frontier_exhausted_rate_min",
        ),
        ("sample_count", "固定工作量搜索样本", None),
        ("deadline_truncations", "deadline 停止", None),
        ("node_budget_truncations", "节点预算停止", None),
    )
    for key, label, threshold_key in depth_specs:
        a_value = ((by_strategy.get("A") or {}).get("full_tier") or {}).get(key)
        b_value = ((by_strategy.get("B") or {}).get("full_tier") or {}).get(key)
        floor = thresholds.get(threshold_key) if threshold_key else None
        depth_rows.append(
            f"<tr><td>{escape(label)}</td><td>{escape(_number(a_value, 1))}</td>"
            f"<td>{escape(_number(b_value, 1))}</td><td>{escape(_number(floor, 1) if floor is not None else '诊断')}</td></tr>"
        )
    deck_rows = []
    for deck in payload.get("deck_keys") or []:
        a_scope = ((((by_strategy.get("A") or {}).get("per_deck") or {}).get(deck) or {}).get("full_tier") or {})
        b_scope = ((((by_strategy.get("B") or {}).get("per_deck") or {}).get(deck) or {}).get("full_tier") or {})
        deck_rows.append(
            f"<tr><td>{escape(DECK_LABELS.get(str(deck), str(deck)))}</td>"
            f"<td>{escape(_number(a_scope.get('completed_depth_p50'), 1))}</td>"
            f"<td>{escape(_number(b_scope.get('completed_depth_p50'), 1))}</td>"
            f"<td>{escape(_integer(a_scope.get('sample_count')))} / {escape(_integer(b_scope.get('sample_count')))}</td></tr>"
        )
    latency_rows = []
    for key, label in (
        ("decision_ms_p95", "单次决策 P95"),
        ("cache_hit_decision_ms_p95", "缓存命中决策 P95"),
        ("ai_turn_ms_p95", "AI 回合 P95"),
    ):
        latency_rows.append(
            f"<tr><td>{escape(label)}</td><td>{escape(_number((latency.get('A') or {}).get(key), 1, ' ms'))}</td>"
            f"<td>{escape(_number((latency.get('B') or {}).get(key), 1, ' ms'))}</td><td>不参与门禁</td></tr>"
        )
    note = f"{performance.get('games_total', 0)} 局：{performance.get('warmup_games', 0)} 局预热，{performance.get('measured_games', 0)} 局采样；门禁只使用后 40 局的实际 beam 深度。"
    if not performance.get("available"):
        note = "未提供单进程搜索深度探针；严格门禁会失败。"
    return (
        f"<section><h2>搜索深度门禁</h2><p class='muted'>{escape(note)}</p>"
        f"<div class='table-scroll'><table><thead><tr><th>指标</th><th>A</th><th>B</th><th>下限/用途</th></tr></thead><tbody>{''.join(depth_rows)}</tbody></table></div>"
        f"<h3>按实际驾驶牌组</h3><div class='table-scroll'><table><thead><tr><th>牌组</th><th>A 深度 P50</th><th>B 深度 P50</th><th>A/B 样本</th></tr></thead><tbody>{''.join(deck_rows)}</tbody></table></div>"
        f"<h3>延迟诊断（不参与门禁）</h3><div class='table-scroll'><table><thead><tr><th>指标</th><th>A</th><th>B</th><th>用途</th></tr></thead><tbody>{''.join(latency_rows)}</tbody></table></div></section>"
    )


def _terminal_and_golden(payload: dict[str, Any]) -> str:
    terminal = payload.get("terminal_reasons") or {}
    terminal_tags = "".join(
        f"<span class='tag'>{escape(TERMINAL_REASON_LABELS.get(str(key), str(key)))} <b>{_integer(value)}</b></span>"
        for key, value in terminal.items()
    )
    golden = payload.get("golden_scenarios") or {}
    failed = [row for row in golden.get("cases") or [] if not row.get("passed")]
    failures = "".join(
        f"<tr><td>{escape(str(row.get('scope') or ''))}</td><td>{escape(str(row.get('name') or ''))}</td><td>{escape(str(row.get('message') or row.get('reason') or ''))}</td></tr>"
        for row in failed
    ) or "<tr><td colspan='3'>无失败</td></tr>"
    return (
        "<section><div class='split'><div><h2>终局原因</h2>"
        f"<div class='tag-list'>{terminal_tags}</div></div><div><h2>金标失败详情</h2><p>{_integer(golden.get('passed'))} / {_integer(golden.get('total'))} 通过</p>"
        f"<div class='table-scroll'><table><thead><tr><th>范围</th><th>场景</th><th>详情</th></tr></thead><tbody>{failures}</tbody></table></div></div></div></section>"
    )


def _details_section(payload: dict[str, Any]) -> str:
    decks = [str(deck) for deck in payload.get("deck_keys") or []]
    deck_options = "<option value=''>全部</option>" + "".join(
        f"<option value='{escape(deck)}'>{escape(_deck_label(deck))}</option>" for deck in decks
    )
    reasons = sorted({str(row.get("terminal_reason") or "") for row in payload.get("matches") or []})
    reason_options = "<option value=''>全部</option>" + "".join(
        f"<option value='{escape(reason)}'>{escape(TERMINAL_REASON_LABELS.get(reason, reason))}</option>" for reason in reasons
    )
    return (
        "<section><h2>全部对局明细</h2><div class='filters'>"
        "<label>模式<select id='f-kind'><option value=''>全部</option><option value='mirror'>镜像</option><option value='cross'>角色交叉</option></select></label>"
        f"<label>A 牌组<select id='f-a'>{deck_options}</select></label><label>B 牌组<select id='f-b'>{deck_options}</select></label>"
        "<label>结果<select id='f-winner'><option value=''>全部</option><option>A</option><option>B</option><option value='draw'>平局</option></select></label>"
        f"<label>终局<select id='f-reason'>{reason_options}</select></label>"
        "<label>seed / block<input id='f-seed' placeholder='例如 17 或 block:2'></label></div>"
        "<p id='match-count' class='muted'></p><div class='table-scroll'><table><thead><tr><th>模式</th><th>A 牌组</th><th>B 牌组</th><th>seed</th><th>block</th><th>seat</th><th>先手</th><th>结果</th><th>终局</th><th>动作</th><th>耗时</th></tr></thead><tbody id='match-body'></tbody></table></div>"
        "<div class='pager'><button id='prev-page'>上一页</button><span id='page-label'></span><button id='next-page'>下一页</button></div></section>"
    )


def _embedded_json(value: Any) -> str:
    return (
        json.dumps(value, ensure_ascii=False, separators=(",", ":"))
        .replace("</", "<\\/")
        .replace("\u2028", "\\u2028")
        .replace("\u2029", "\\u2029")
    )


def _script(payload: dict[str, Any]) -> str:
    behavior = payload.get("behavior") or {}
    matches = payload.get("matches") or []
    labels = {**DECK_LABELS, **TERMINAL_REASON_LABELS}
    return f"""
<script>
const behavior={_embedded_json(behavior)};
const matches={_embedded_json(matches)};
const labels={_embedded_json(labels)};
const pct=v=>v===null||v===undefined?'—':(v*100).toFixed(1)+'%';
const esc=v=>String(v??'').replace(/[&<>\"']/g,c=>({{'&':'&amp;','<':'&lt;','>':'&gt;','\"':'&quot;',"'":'&#39;'}}[c]));
function behaviorScope(side,deck){{return deck==='overall'?(behavior.overall?.[side]||{{}}):(behavior.per_deck?.[side]?.[deck]||{{}})}}
function renderBehavior(){{
 const deck=document.getElementById('behavior-deck').value,a=behaviorScope('A',deck),b=behaviorScope('B',deck);
 const kinds=[...new Set([...Object.keys(a.selected_action_counts||{{}}),...Object.keys(b.selected_action_counts||{{}})])];
 document.getElementById('behavior-body').innerHTML=kinds.map(k=>`<tr><td><code>${{esc(k)}}</code></td><td>${{pct(a.selected_action_shares?.[k])}}</td><td>${{pct(b.selected_action_shares?.[k])}}</td><td>${{pct(a.selection_rate_when_available?.[k])}}</td><td>${{pct(b.selection_rate_when_available?.[k])}}</td><td>${{a.legal_action_opportunity_counts?.[k]||0}} / ${{b.legal_action_opportunity_counts?.[k]||0}}</td></tr>`).join('');
 document.getElementById('behavior-summary').innerHTML=['A','B'].map(s=>{{const x=s==='A'?a:b;return `<div><b>${{s}}</b><span>类别覆盖 ${{pct(x.action_kind_coverage)}}</span><span>归一化熵 ${{x.normalized_action_entropy??'—'}}</span></div>`}}).join('');
 const choices=[...new Set([...Object.keys(a.choice_request_counts||{{}}),...Object.keys(b.choice_request_counts||{{}})])];
 document.getElementById('choice-coverage').innerHTML=choices.length?choices.map(k=>`<span class='tag'>${{esc(k)}} <b>${{a.choice_request_counts?.[k]||0}} / ${{b.choice_request_counts?.[k]||0}}</b></span>`).join(''):'<span class="muted">无 Choice 请求</span>';
}}
document.getElementById('behavior-deck').addEventListener('change',renderBehavior);renderBehavior();
let page=1;const size=50;
const fields=['f-kind','f-a','f-b','f-winner','f-reason','f-seed'];
function filtered(){{const v=Object.fromEntries(fields.map(id=>[id,document.getElementById(id).value.trim()]));return matches.filter(m=>{{
 if(v['f-kind']&&m.matchup_kind!==v['f-kind'])return false;if(v['f-a']&&m.strategy_a_deck!==v['f-a'])return false;if(v['f-b']&&m.strategy_b_deck!==v['f-b'])return false;if(v['f-winner']&&m.winner!==v['f-winner'])return false;if(v['f-reason']&&m.terminal_reason!==v['f-reason'])return false;
 if(v['f-seed']){{const q=v['f-seed'].toLowerCase();if(q.startsWith('block:')){{if(String(m.seed_block)!==q.slice(6).trim())return false}}else if(!String(m.seed).includes(q))return false}}return true}})}}
function renderMatches(){{const rows=filtered(),pages=Math.max(1,Math.ceil(rows.length/size));page=Math.min(page,pages);const shown=rows.slice((page-1)*size,page*size);document.getElementById('match-count').textContent=`筛选后 ${{rows.length}} / ${{matches.length}} 局；每页 ${{size}} 局。`;
 document.getElementById('match-body').innerHTML=shown.map(m=>`<tr><td>${{esc(m.matchup_kind)}}</td><td>${{esc(labels[m.strategy_a_deck]||m.strategy_a_deck)}}</td><td>${{esc(labels[m.strategy_b_deck]||m.strategy_b_deck)}}</td><td><code>${{m.seed}}</code></td><td>${{m.seed_block}}</td><td>${{m.seat}}</td><td>P${{m.forced_first_player}}</td><td>${{esc(m.winner)}}</td><td title='${{esc(m.terminal_message)}}'>${{esc(labels[m.terminal_reason]||m.terminal_reason)}}</td><td>${{m.actions}}</td><td>${{m.elapsed_ms}} ms</td></tr>`).join('');
 document.getElementById('page-label').textContent=`第 ${{page}} / ${{pages}} 页`;document.getElementById('prev-page').disabled=page<=1;document.getElementById('next-page').disabled=page>=pages;}}
fields.forEach(id=>document.getElementById(id).addEventListener(id==='f-seed'?'input':'change',()=>{{page=1;renderMatches()}}));document.getElementById('prev-page').onclick=()=>{{page--;renderMatches()}};document.getElementById('next-page').onclick=()=>{{page++;renderMatches()}};renderMatches();
</script>"""


def render_report(
    payload: dict[str, Any], validation: dict[str, Any] | None = None
) -> str:
    if int(payload.get("schema_version") or 0) != SCHEMA_VERSION:
        raise ValueError(f"Only AI evaluation schema v{SCHEMA_VERSION} is supported.")
    if payload.get("artifact_kind") != "ai_evaluation_result":
        raise ValueError("Report input must be an authoritative ai_evaluation_result.")
    mirror = _strength(payload, "mirror").get("overall") or {}
    cross = _strength(payload, "cross_role").get("overall") or {}
    observed = payload.get("observed") or {}
    coverage = payload.get("coverage") or {}
    games = int(observed.get("games") or 0)
    clean_rate = int(observed.get("clean_games") or 0) / games if games else None
    search_depth_a = (((((payload.get("performance") or {}).get("search_depth") or {}).get("by_strategy") or {}).get("A") or {}).get("full_tier") or {})
    gate_state = "未执行"
    gate_tone = "warn"
    if validation is not None:
        gate_state = "通过" if validation.get("valid") else "失败"
        gate_tone = "ok" if validation.get("valid") else "bad"
    cards = "".join([
        _metric_card("门禁状态", gate_state, str((validation or {}).get("gate") or "无"), gate_tone),
        _metric_card("镜像强度差", _pp(mirror.get("point_delta")), f"95% CI {_ci(mirror.get('ci95'))}"),
        _metric_card("角色交叉差", _pp(cross.get("point_delta")), f"95% CI {_ci(cross.get('ci95'))}"),
        _metric_card("干净覆盖率", _pct(clean_rate), f"{_integer(observed.get('clean_games'))} / {_integer(games)} 局"),
        _metric_card(
            "候选 A 搜索深度",
            _number(search_depth_a.get("completed_depth_p50"), 1),
            f"完整层 P50；P95 {_number(search_depth_a.get('completed_depth_p95'), 1)}",
        ),
    ])
    provenance = payload.get("provenance") or {}
    provenance_text = f"source {str(provenance.get('source_hash') or '')[:12]} · git {str(provenance.get('git_commit') or '')[:12]}{' dirty' if provenance.get('git_dirty') else ''} · Godot {provenance.get('godot_runtime_version') or '—'}"
    verdict = evaluation_verdict(payload, validation)
    style = """
<style>
:root{color-scheme:dark;--bg:#07111f;--panel:#0d1b2e;--line:#23344c;--text:#e7eef8;--muted:#91a4bd;--blue:#38bdf8;--green:#22c55e;--red:#ef4444;--amber:#f59e0b}*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 15% 0,#143258 0,transparent 34%),var(--bg);color:var(--text);font:14px/1.55 Inter,"Segoe UI","Microsoft YaHei",sans-serif}main{max-width:1580px;margin:auto;padding:28px}header{padding:26px;border:1px solid var(--line);border-radius:18px;background:rgba(13,27,46,.9)}h1{margin:0 0 6px;font-size:28px}h2{margin:0 0 12px;font-size:19px}h3{margin-top:24px}.muted,small{color:var(--muted)}.verdict{font-size:16px;padding:13px 16px;border-left:4px solid var(--blue);background:#10243b;border-radius:8px}.metrics{display:grid;grid-template-columns:repeat(5,minmax(150px,1fr));gap:12px;margin:16px 0}.metric,section{border:1px solid var(--line);background:rgba(13,27,46,.94);border-radius:14px}.metric{padding:15px}.metric span,.metric small{display:block}.metric strong{font-size:22px;display:block;margin:6px 0}.metric.ok{border-color:#236b45}.metric.bad{border-color:#8e3035}.metric.warn{border-color:#88641d}section{padding:20px;margin:16px 0}.delta-row{margin:15px 0}.delta-row>div:first-child{display:flex;justify-content:space-between}.delta-track{height:13px;position:relative;border-radius:8px;background:linear-gradient(90deg,rgba(239,68,68,.55),#23344c 50%,rgba(34,197,94,.55))}.zero{position:absolute;left:50%;height:18px;top:-3px;border-left:1px solid #fff}.marker{position:absolute;top:-3px;width:4px;height:19px;background:#fff;border-radius:2px;box-shadow:0 0 8px #fff}.axis-labels{display:flex;justify-content:space-between;color:var(--muted);font-size:11px}.table-scroll{overflow:auto}table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}th,td{border-bottom:1px solid var(--line);padding:9px 10px;text-align:left;white-space:nowrap}th{color:#b9cae0;background:#101f33;position:sticky;top:0}.heat th,.heat td{text-align:center;min-width:86px}.split{display:grid;grid-template-columns:1fr 1fr;gap:20px}.pill{padding:3px 8px;border-radius:999px;background:#24364d}.pill.ok{background:#124d33;color:#86efac}.pill.bad{background:#5b2028;color:#fca5a5}.section-title{display:flex;align-items:end;justify-content:space-between}.mini-cards{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin:12px 0}.mini-cards>div{display:flex;gap:18px;padding:10px;background:#101f33;border-radius:8px}.tag-list{display:flex;flex-wrap:wrap;gap:8px}.tag{padding:6px 10px;background:#162840;border:1px solid var(--line);border-radius:999px}.perf-track{height:8px;margin-top:6px;background:#1d2e45;position:relative;max-width:260px}.perf-track i{display:block;height:100%}.perf-track .goodbar{background:var(--green)}.perf-track .badbar{background:var(--red)}.perf-track em{position:absolute;top:-3px;height:14px;border-left:2px solid var(--amber)}select,input,button{color:var(--text);background:#101f33;border:1px solid #334962;border-radius:7px;padding:7px 9px}.filters{display:flex;flex-wrap:wrap;gap:10px}.filters label,.section-title label{display:flex;flex-direction:column;gap:4px;color:var(--muted)}.pager{display:flex;justify-content:center;align-items:center;gap:12px;margin-top:14px}code{color:#bae6fd;white-space:normal}.provenance{word-break:break-all}@media(max-width:1000px){main{padding:12px}.metrics{grid-template-columns:1fr 1fr}.split{grid-template-columns:1fr}}@media(max-width:600px){.metrics{grid-template-columns:1fr}.delta-row>div:first-child{display:block}}
</style>"""
    return f"""<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>AI 策略评测 v6</title>{style}</head><body><main>
<header><h1>AI 策略评测 v6</h1><p>{escape(_strategy_label(payload,'A'))} <span class="muted">vs</span> {escape(_strategy_label(payload,'B'))}</p><p class="verdict">{escape(verdict)}</p><p class="muted provenance">{escape(provenance_text)}</p></header>
<div class="metrics">{cards}</div>
<section><h2>两项独立主指标</h2><p class="muted">两项指标不混合；仅完整、干净的实验单元进入固定 seed、10,000 次分层 cluster bootstrap。原始总点数率不生成主结论。</p>{_delta_bar(mirror.get('point_delta'),mirror.get('ci95'),'镜像强度：同牌组、同 seed 的两局换席块；十牌组等权')}{_delta_bar(cross.get('point_delta'),cross.get('ci95'),'角色交叉强度：同 seed 的四局牌组角色交叉块；无序对局等权')}</section>
{_validation_section(validation)}{_fairness_table(payload,validation)}{_heatmap(payload,raw=False)}{_heatmap(payload,raw=True)}{_behavior_section(payload)}{_search_depth_section(payload,validation)}{_terminal_and_golden(payload)}{_details_section(payload)}
{_script(payload)}</main></body></html>"""


def render_file(
    input_path: str | Path,
    output_path: str | Path,
    validation_path: str | Path | None = None,
) -> Path:
    source = Path(input_path)
    target = Path(output_path)
    payload = json.loads(source.read_text(encoding="utf-8-sig"))
    validation = None
    if validation_path is not None:
        validation = json.loads(Path(validation_path).read_text(encoding="utf-8-sig"))
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(render_report(payload, validation), encoding="utf-8")
    return target


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--validation")
    args = parser.parse_args()
    output = render_file(args.input, args.output, args.validation)
    print(json.dumps({"report": str(output), "schema_version": SCHEMA_VERSION}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
