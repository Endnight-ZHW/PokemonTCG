"use strict";

const deckLabels = {
  fire: "火", water: "水", psychic: "超能", lightning: "雷", fighting: "斗",
  colorless: "无色", dragon: "龙", grass: "草", steel: "钢", darkness: "恶",
};
const state = {
  csrf: "", runs: [], selected: "", source: null, lastEvent: null, events: [],
  anchorHistory: new Map(), anchorContext: "",
};
const $ = id => document.getElementById(id);
const activeStatuses = new Set([
  "starting", "running", "pausing", "paused", "cancelling",
]);
function toast(message) {
  $("toast").textContent = message;
  $("toast").classList.add("show");
  setTimeout(() => $("toast").classList.remove("show"), 2400);
}

async function api(path, options = {}) {
  const init = {...options, headers: {...(options.headers || {})}};
  if (init.method && init.method !== "GET") {
    init.headers["Content-Type"] = "application/json";
    init.headers["X-CSRF-Token"] = state.csrf;
  }
  const response = await fetch(path, init);
  const data = await response.json();
  if (!response.ok) throw new Error(data.message || data.error || response.statusText);
  return data;
}

function statusLabel(status) {
  return {
    created: "已创建", starting: "启动中", running: "训练中", pausing: "暂停中",
    paused: "已暂停", cancelling: "取消中", cancelled: "已取消",
    recoverable: "可恢复", failed: "失败", completed: "训练完成",
  }[status] || status;
}

function stageLabel(stage) {
  const value = String(stage || "");
  const labels = {
    created: "等待启动",
    initializing: "初始化",
    teacher_replay_imported: "教师回放已导入",
    teacher_warmup_epoch_complete: "教师预热",
    teacher_warmup_complete: "教师预热完成",
    teacher_retention_complete: "教师保持检查",
    self_play_complete: "原生自博弈",
    arena_progress: "棋力验证",
    cycle_complete: "训练周期完成",
    cycle_teacher_gate_repaired: "教师门禁修复",
    run_started: "训练开始",
    run_complete: "训练完成",
    completed: "训练完成",
    cancelled: "已取消",
    failed: "失败",
  };
  return labels[value] || value || "等待事件";
}

function localClock(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  return new Intl.DateTimeFormat("zh-CN", {
    hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false,
  }).format(date);
}

function setConnection(mode, text) {
  const node = $("connection");
  node.className = `connection muted ${mode}`;
  node.textContent = text;
}

async function refreshRuns() {
  const data = await api("/api/v1/runs");
  state.runs = data.runs;
  $("runs").replaceChildren(...state.runs.map(run => {
    const button = document.createElement("button");
    button.className = "run-row" + (run.run_id === state.selected ? " active" : "");
    button.dataset.status = run.status || "";
    button.type = "button";
    button.setAttribute("aria-pressed", run.run_id === state.selected ? "true" : "false");
    button.title = `${run.run_id} · ${statusLabel(run.status)}`;

    const head = document.createElement("span");
    head.className = "run-row-head";
    const dot = document.createElement("span");
    dot.className = "status-dot";
    dot.setAttribute("aria-hidden", "true");
    const kind = document.createElement("span");
    kind.className = "run-kind";
    kind.textContent = run.preset === "release"
      ? "Release" : run.preset === "pilot" ? "Pilot" : "Smoke";
    const status = document.createElement("span");
    status.className = "run-status";
    status.textContent = statusLabel(run.status);
    head.append(dot, kind, status);

    const id = document.createElement("span");
    id.className = "run-id";
    id.textContent = run.run_id;
    button.append(head, id);
    button.onclick = () => selectRun(run.run_id);
    return button;
  }));
  const hasActiveRun = state.runs.some(run => activeStatuses.has(run.status));
  $("create-smoke").disabled = hasActiveRun;
  $("create-pilot").disabled = hasActiveRun;
  $("create-release").disabled = hasActiveRun;
  $("smoke-deck").disabled = hasActiveRun;
  $("create-smoke").textContent = hasActiveRun ? "Smoke 已锁定" : "链路 Smoke";
  $("create-pilot").textContent = hasActiveRun ? "Pilot 已锁定" : "工程 Pilot";
  $("create-release").textContent = hasActiveRun ? "任务运行中" : "开始 Release";
  const createHint = hasActiveRun ? "已有训练或晋升任务正在运行" : "";
  $("create-smoke").title = createHint;
  $("create-pilot").title = createHint;
  $("create-release").title = createHint;
  if (state.selected) {
    const run = state.runs.find(row => row.run_id === state.selected);
    if (run) renderRun(run);
  }
}

async function selectRun(runId) {
  state.selected = runId;
  state.events = [];
  state.lastEvent = null;
  const url = new URL(window.location.href);
  url.searchParams.delete("run");
  url.hash = `run=${encodeURIComponent(runId)}`;
  window.history.replaceState({}, "", url);
  await refreshRuns();
  connectEvents();
}

function connectEvents() {
  if (state.source) state.source.close();
  if (!state.selected) return;
  const source = new EventSource(`/api/v1/runs/${encodeURIComponent(state.selected)}/events`);
  state.source = source;
  source.onopen = () => {
    setConnection("connected", "实时连接已建立");
  };
  source.addEventListener("training_event_v3", event => {
    const row = JSON.parse(event.data);
    state.lastEvent = row;
    state.events.push(row);
    if (state.events.length > 200) state.events.shift();
    renderEvents();
    applyEvent(row);
  });
  source.addEventListener("heartbeat", event => {
    const heartbeat = JSON.parse(event.data);
    setConnection("connected", `实时连接 · ${localClock(heartbeat.time)}`);
    renderRun(heartbeat.run);
  });
  source.onerror = () => {
    setConnection("reconnecting", "连接中断，正在自动续接…");
  };
}

function formatLoss(value) {
  return Number.isFinite(Number(value)) ? Number(value).toFixed(4) : "—";
}
function formatDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "—";
  const rounded = Math.ceil(seconds);
  const hours = Math.floor(rounded / 3600);
  const minutes = Math.floor((rounded % 3600) / 60);
  const rest = rounded % 60;
  return hours
    ? `${hours}小时${minutes}分`
    : minutes
      ? `${minutes}分${rest}秒`
      : `${rest}秒`;
}

function renderEvaluation(arena, cycle, accepted, learningPassed) {
  if (arena.schema !== "ptcg.ai_evaluation.report/1") {
    $("record").textContent = "— / — / —";
    $("evaluation-verdict").textContent = "等待有效评测报告";
    for (const id of ["evaluation-games", "evaluation-blocks", "evaluation-interval", "evaluation-anchor"]) $(id).textContent = "—";
    $("evaluation-decks").replaceChildren(); $("anchor-trend").replaceChildren();
    $("evaluation-reason").textContent = "";
    $("evaluation-performance").textContent = "";
    state.anchorHistory.clear(); state.anchorContext = "";
    return;
  }
  const record = arena.record;
  $("record").textContent = `${record.wins} / ${record.losses} / ${record.draws}`;
  const number = value => typeof value === "number" && Number.isFinite(value);
  const percent = value => number(value) ? `${(value * 100).toFixed(2)}%` : "—";
  const delta = value => number(value) ? `${value >= 0 ? "+" : ""}${(value * 100).toFixed(2)} 个百分点` : "—";
  const interval = (value, format) => Array.isArray(value) && value.every(number) ? `${format(value[0])} ～ ${format(value[1])}` : "证据不足";
  const strength = arena.strength || {};
  const status = {improved: "确认总体提升", regressed: "确认总体退步", inconclusive: "证据不足", not_evaluated: "仅诊断或评测未完成"};
  const gate = {pass: "通过", fail: "未通过", inconclusive: "证据不足", continue: "继续采样", infrastructure_fail: "运行故障"};
  const champion = typeof accepted === "boolean" ? (accepted ? " · 冠军已更新" : " · 冠军保留") : "";
  $("evaluation-verdict").textContent = `${status[strength.status] || "等待评测"} · 评测${gate[arena.gate_status] || "待定"}${champion}`;
  $("evaluation-games").textContent = `${arena.strength_games ?? 0} / ${arena.games ?? 0}`;
  $("evaluation-blocks").textContent = String(strength.blocks ?? 0);
  $("evaluation-interval").textContent = `${percent(strength.estimate)} · ${interval(strength.interval, percent)}（${percent(strength.confidence_level)} 置信序列）`;
  $("evaluation-anchor").textContent = `${delta(arena.anchor?.estimate)} · ${interval(arena.anchor?.interval, delta)}`;
  const reasons = {diagnostic_only: "本次只作诊断", overall_regression: "总体退步",
    primary_evidence_insufficient: "对冠军的证据不足", anchor_evidence_insufficient: "对历史锚点的证据不足",
    overall_improvement_and_anchor_protection: "总体提升且通过历史锚点保护", anchor_regression: "历史锚点表现退步",
    budget_exhausted_or_incomplete_evidence: "达到预算或证据尚未完整", truncated: "存在截断对局",
    timeout: "存在持续超时", agent_error: "AI 返回错误", infrastructure: "运行故障", infrastructure_error: "证据或执行器发生错误", cancelled: "评测取消"};
  $("evaluation-reason").textContent = (arena.stop_reasons || []).map(reason => reason.startsWith("deck_regression:") ? `${deckLabels[reason.split(":")[1]] || "套牌"}出现明确退步` : reasons[reason] || reason).join("；");
  if (learningPassed === false) $("evaluation-reason").textContent += "；训练质量检查未通过，保留冠军";
  const perf = arena.performance_advisory || {};
  $("evaluation-performance").textContent = `运行耗时 ${formatDuration(perf.elapsed_seconds)} · 复用 ${perf.cached_games ?? 0} 局 · 性能指标不参与棋力晋升`;
  $("evaluation-decks").replaceChildren(...Object.entries(arena.per_deck || {}).map(([deck, value]) => {
    const tr = document.createElement("tr");
    const labels = {noninferior: "已排除超过 5 个百分点的退步", confirmed_regression: "已确认明显退步", inconclusive: "证据不足"};
    for (const text of [deckLabels[deck] || deck, delta(value.estimate), interval(value.interval, delta), labels[value.status] || "证据不足"]) {
      const td = document.createElement("td"); td.textContent = text; tr.append(td);
    }
    return tr;
  }));
  const context = `${state.selected}:${arena.comparison_context_hash}:${arena.references?.anchor?.content_hash}`;
  if (state.anchorContext !== context) { state.anchorHistory.clear(); state.anchorContext = context; }
  const anchorScore = arena.anchor?.candidate_record?.score_rate;
  if (number(cycle) && number(anchorScore)) state.anchorHistory.set(cycle, anchorScore);
  const points = [...state.anchorHistory.entries()].sort((a, b) => a[0]-b[0]);
  const svg = $("anchor-trend"); svg.replaceChildren();
  if (points.length > 1) {
    const line = document.createElementNS("http://www.w3.org/2000/svg", "polyline");
    line.setAttribute("points", points.map((point, index) => `${10+580*index/(points.length-1)},${90-80*point[1]}`).join(" "));
    line.setAttribute("fill", "none"); line.setAttribute("stroke", "currentColor"); line.setAttribute("stroke-width", "2"); svg.append(line);
  }
}

function applyEvent(row) {
  const metrics = row.metrics || {};
  const training = metrics.training || metrics;
  const generated = metrics.generated || {};
  const arena = metrics.arena || {};
  const inference = metrics.inference || arena.performance_advisory?.inference || {};
  $("run-message").textContent = row.message || "";
  $("last-seq").textContent = `seq ${row.seq}`;
  const total = Number(row.total || 0);
  const completed = Number(row.completed || 0);
  const percent = total ? Math.min(100, Math.max(0, completed / total * 100)) : 0;
  $("progress-bar").style.width = `${percent}%`;
  $("progress-track").setAttribute("aria-valuenow", String(Math.round(percent)));
  const deck = deckLabels[row.deck] || row.deck || "";
  $("progress-label").textContent = [
    `${completed.toLocaleString()} / ${total.toLocaleString()}`,
    stageLabel(row.stage),
    deck,
  ].filter(Boolean).join(" · ");
  const speed = Number(training.learner_samples_per_second);
  $("speed").textContent = Number.isFinite(speed) ? `${speed.toFixed(1)} 样本/s` : "—";
  $("eta").textContent = `本阶段 ETA ${
    formatDuration(speed > 0 && total >= completed ? (total - completed) / speed : NaN)
  }`;
  $("gpu").textContent = Number.isFinite(Number(inference.average_batch))
    ? Number(inference.average_batch).toFixed(1) : "—";
  $("vram").textContent = Number.isFinite(Number(training.loader_to_learner_ratio))
    ? `${Number(training.loader_to_learner_ratio).toFixed(2)}×` : "—";
  const replaySamples = metrics.replay?.samples ?? generated.written_samples;
  $("replay").textContent = replaySamples == null
    ? "—" : Number(replaySamples).toLocaleString();
  const cycle = metrics.cycle ?? training.cycle;
  const globalStep = metrics.global_step ?? training.global_step;
  $("history").textContent = cycle == null && globalStep == null
    ? "—" : `C${cycle ?? "—"} · ${globalStep ?? "—"}`;
  $("policy-loss").textContent = formatLoss(training.policy_loss);
  $("value-loss").textContent = formatLoss(training.wdl_loss);
  $("choice-loss").textContent = formatLoss(training.normalized_policy_entropy);
  if (Object.keys(arena).length) renderEvaluation(arena, cycle, metrics.accepted, metrics.learning_gate?.passed);
}

function renderRun(run) {
  $("empty").hidden = true;
  $("detail").hidden = false;
  $("run-meta").textContent = `${run.preset?.toUpperCase() || ""} · ${statusLabel(run.status)}`;
  $("run-title").textContent = run.run_id;
  const progress = run.progress || {};
  if (!state.lastEvent && progress.metrics) applyEvent({
    stage: progress.stage, deck: progress.deck, completed: progress.completed,
    total: progress.total, metrics: progress.metrics, message: "", seq: 0,
  });
  const active = ["starting", "running", "pausing", "paused"].includes(run.status);
  $("pause").disabled = !["starting", "running"].includes(run.status);
  $("resume").disabled = !["paused", "recoverable", "failed", "cancelled"].includes(run.status);
  $("cancel").disabled = !active;
}

function renderEvents() {
  $("events").replaceChildren(...state.events.slice().reverse().map(row => {
    const div = document.createElement("div");
    const failed = ["error", "run_failed"].includes(row.event)
      || Number(row.metrics?.rule_exceptions || 0) > 0
      || Number(row.metrics?.invalid_actions || 0) > 0;
    div.className = "event" + (failed ? " error" : "");
    div.title = row.time ? new Date(row.time).toLocaleString("zh-CN") : "";
    const seq = document.createElement("span");
    seq.className = "event-seq";
    seq.textContent = `#${row.seq}`;
    const stage = document.createElement("span");
    stage.className = "event-stage";
    stage.textContent = stageLabel(row.stage);
    const message = document.createElement("span");
    message.className = "event-message";
    message.textContent = row.message || JSON.stringify(row.metrics || {});
    div.append(seq, stage, message);
    return div;
  }));
}

async function createRun(preset) {
  const deck = $("smoke-deck").value;
  const label = preset === "release"
    ? "将创建固定的完整 Release 训练；模型不会自动晋升。确认开始？"
    : preset === "pilot"
      ? "开始两个 25,000 样本周期的 v3 工程 Pilot？"
      : "开始 Deep AI v3 Smoke 链路检查？";
  if (!confirm(label)) return;
  try {
    const run = await api("/api/v1/runs", {
      method: "POST", body: JSON.stringify({preset, deck, seed: 17}),
    });
    toast("训练任务已创建");
    await selectRun(run.run_id);
  } catch (error) { toast(error.message); }
}

async function control(action) {
  if (!state.selected) return;
  if (
    action === "cancel"
    && !confirm("确定取消当前任务？已提交批次会保留，可从检查点恢复。")
  ) return;
  try {
    await api(`/api/v1/runs/${encodeURIComponent(state.selected)}/${action}`, {
      method: "POST", body: "{}",
    });
    toast(`${action} 请求已提交`);
    await refreshRuns();
  } catch (error) { toast(error.message); }
}

async function boot() {
  try {
    const session = await api("/api/v1/session");
    state.csrf = session.csrf_token;
    setConnection("connected", "已连接本机服务");
    await refreshRuns();
    const hashParams = new URLSearchParams(window.location.hash.replace(/^#/, ""));
    const requestedRun = hashParams.get("run")
      || new URLSearchParams(window.location.search).get("run");
    const requested = state.runs.find(run => run.run_id === requestedRun);
    const active = state.runs.find(run =>
      activeStatuses.has(run.status));
    const initial = requested || active || state.runs[0];
    if (initial) await selectRun(initial.run_id);
  } catch (error) {
    setConnection("reconnecting", `连接失败：${error.message}`);
  }
}

$("create-smoke").onclick = () => createRun("smoke");
$("create-pilot").onclick = () => createRun("pilot");
$("create-release").onclick = () => createRun("release");
$("refresh").onclick = refreshRuns;
$("pause").onclick = () => control("pause");
$("resume").onclick = () => control("resume");
$("cancel").onclick = () => control("cancel");
boot();
setInterval(() => refreshRuns().catch(() => {}), 10000);
