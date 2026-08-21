"use strict";

const deckLabels = {
  fire: "火", water: "水", psychic: "超能", lightning: "雷", fighting: "斗",
  colorless: "无色", dragon: "龙", grass: "草", steel: "钢", darkness: "恶",
};
const state = {
  csrf: "", runs: [], selected: "", source: null, lastEvent: null, events: [],
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

function applyEvent(row) {
  const metrics = row.metrics || {};
  const training = metrics.training || metrics;
  const generated = metrics.generated || {};
  const arena = metrics.arena || {};
  const inference = metrics.inference || arena.inference || {};
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
  const arenaLosses = Number.isFinite(Number(arena.games))
    ? Number(arena.games) - Number(arena.wins || 0) - Number(arena.draws || 0)
    : "—";
  $("record").textContent = `${arena.wins ?? "—"} / ${arenaLosses} / ${arena.draws ?? "—"}`;
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
