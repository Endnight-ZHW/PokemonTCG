"use strict";

const deckLabels = {
  fire: "火", water: "水", psychic: "超能", lightning: "雷", fighting: "斗",
  colorless: "无色", dragon: "龙", grass: "草", steel: "钢", darkness: "恶",
};
const state = {
  csrf: "", runs: [], selected: "", source: null, lastEvent: null, events: [],
  strengthDeck: "", strengthChartKey: "", visibleRun: null,
};
const $ = id => document.getElementById(id);
const activeStatuses = new Set([
  "starting", "running", "pausing", "paused", "cancelling", "promoting",
]);
const gateLabels = {
  godot_2800_deep_release_gate: "Godot 2800 局配对门禁",
  python_encoder_golden: "Python encoder golden",
  godot_encoder_golden_windows: "Windows encoder golden",
  godot_encoder_golden_android: "Android encoder golden",
  pytorch_onnx_ordinary_and_empty_parity: "PyTorch / ONNX 双输入 parity",
  windows_x86_64_load_infer: "Windows x86_64 加载与推理",
  android_arm64_load_infer: "Android ARM64 加载与推理",
  complete_schema_and_hash_set: "十套模型 schema 与哈希完整",
};

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
    promoting: "晋升中", promoted: "已晋升",
  }[status] || status;
}

function stageLabel(stage) {
  const value = String(stage || "");
  const labels = {
    created: "等待启动",
    initializing: "初始化",
    teacher: "Teacher",
    dagger: "DAgger",
    completed: "训练完成",
    cancelled: "已取消",
    failed: "失败",
  };
  if (labels[value]) return labels[value];
  const generation = value.match(/^population_generation_(\d+)$/);
  return generation ? `人口自博弈 G${generation[1]}` : value || "等待事件";
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
    kind.textContent = run.preset === "release" ? "Release" : "Smoke";
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
  $("create-release").disabled = hasActiveRun;
  $("smoke-deck").disabled = hasActiveRun;
  $("create-smoke").textContent = hasActiveRun ? "Smoke 已锁定" : "链路 Smoke";
  $("create-release").textContent = hasActiveRun ? "任务运行中" : "开始 Release";
  const createHint = hasActiveRun ? "已有训练或晋升任务正在运行" : "";
  $("create-smoke").title = createHint;
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
  source.addEventListener("training_event_v1", event => {
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

function sumObject(value) {
  return Object.values(value || {}).reduce((total, item) => total + Number(item || 0), 0);
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

function formatPointDelta(value, digits = 1) {
  const number = Number(value);
  if (!Number.isFinite(number)) return "—";
  const points = number * 100;
  return `${points >= 0 ? "+" : ""}${points.toFixed(digits)}pp`;
}

function setStrengthTone(node, value) {
  node.classList.remove("positive", "negative");
  const number = Number(value);
  if (!Number.isFinite(number) || number === 0) return;
  node.classList.add(number > 0 ? "positive" : "negative");
}

function checkpointLabel(row) {
  if (row.stage === "teacher") return `T${row.completed}`;
  if (row.stage === "dagger") return `D${row.completed}`;
  const generation = String(row.stage || "").match(/population_generation_(\d+)/);
  return generation ? `G${generation[1]}` : `#${row.index}`;
}

function svgNode(name, attributes = {}, text = "") {
  const node = document.createElementNS("http://www.w3.org/2000/svg", name);
  Object.entries(attributes).forEach(([key, value]) => node.setAttribute(key, String(value)));
  if (text) node.textContent = text;
  return node;
}

function renderStrengthChart(rows) {
  const svg = $("strength-chart");
  svg.replaceChildren();
  if (!rows.length) return;
  const width = 900;
  const height = 250;
  const margin = {left: 58, right: 24, top: 22, bottom: 44};
  const plotWidth = width - margin.left - margin.right;
  const plotHeight = height - margin.top - margin.bottom;
  const observed = rows.flatMap(row => [
    Math.abs(Number(row.point_delta) || 0),
    ...((row.ci95 || []).map(value => Math.abs(Number(value) || 0))),
  ]);
  const domain = Math.min(
    1,
    Math.max(0.25, Math.ceil(Math.max(...observed, 0.25) * 10) / 10),
  );
  const x = index => rows.length === 1
    ? margin.left + plotWidth / 2
    : margin.left + plotWidth * index / (rows.length - 1);
  const y = value => margin.top + (domain - Math.max(-domain, Math.min(domain, value)))
    / (domain * 2) * plotHeight;

  [-domain, -domain / 2, 0, domain / 2, domain].forEach(value => {
    const line = svgNode("line", {
      x1: margin.left, x2: width - margin.right,
      y1: y(value), y2: y(value),
      class: value === 0 ? "chart-zero" : "chart-grid",
    });
    svg.append(line);
    svg.append(svgNode("text", {
      x: margin.left - 9, y: y(value) + 4,
      "text-anchor": "end", class: "chart-label",
    }, formatPointDelta(value, 0)));
  });
  svg.append(svgNode("text", {
    x: width - margin.right, y: y(0) - 7,
    "text-anchor": "end", class: "chart-label",
  }, "Challenge 基线"));

  if (rows.length > 1) {
    const path = rows.map((row, index) =>
      `${index ? "L" : "M"} ${x(index).toFixed(2)} ${y(Number(row.point_delta)).toFixed(2)}`,
    ).join(" ");
    svg.append(svgNode("path", {d: path, class: "chart-line"}));
  }

  const labelStep = Math.max(1, Math.ceil(rows.length / 8));
  rows.forEach((row, index) => {
    const pointX = x(index);
    const pointY = y(Number(row.point_delta));
    const low = y(Number(row.ci95?.[0] ?? row.point_delta));
    const high = y(Number(row.ci95?.[1] ?? row.point_delta));
    svg.append(svgNode("line", {
      x1: pointX, x2: pointX, y1: high, y2: low, class: "chart-ci",
    }));
    svg.append(svgNode("line", {
      x1: pointX - 5, x2: pointX + 5, y1: high, y2: high, class: "chart-ci",
    }));
    svg.append(svgNode("line", {
      x1: pointX - 5, x2: pointX + 5, y1: low, y2: low, class: "chart-ci",
    }));
    const circle = svgNode("circle", {
      cx: pointX, cy: pointY, r: 5, class: "chart-point",
    });
    circle.append(svgNode("title", {}, [
      checkpointLabel(row),
      `点率差 ${formatPointDelta(row.point_delta)}`,
      `95% CI ${formatPointDelta(row.ci95?.[0])} ~ ${formatPointDelta(row.ci95?.[1])}`,
      `${row.games} 局：${row.wins}胜 / ${row.losses}负 / ${row.draws}平`,
    ].join("\n")));
    svg.append(circle);
    svg.append(svgNode("text", {
      x: pointX, y: Math.max(13, pointY - 10),
      "text-anchor": "middle", class: "chart-value",
    }, formatPointDelta(row.point_delta)));
    if (index % labelStep === 0 || index === rows.length - 1) {
      svg.append(svgNode("text", {
        x: pointX, y: height - 16,
        "text-anchor": "middle", class: "chart-label",
      }, checkpointLabel(row)));
    }
  });

  const wrap = svg.parentElement;
  const chartKey = [
    rows[0]?.deck,
    rows.length,
    rows.at(-1)?.checkpoint_sha256,
    Math.round(wrap?.clientWidth || 0),
  ].join(":");
  if (wrap && chartKey !== state.strengthChartKey) {
    state.strengthChartKey = chartKey;
    const latestRenderedX = x(rows.length - 1) / width * svg.clientWidth;
    requestAnimationFrame(() => {
      wrap.scrollLeft = Math.max(
        0,
        latestRenderedX - wrap.clientWidth / 2,
      );
    });
  }
}

function renderStrength(probe = {}) {
  const history = Array.isArray(probe.history) ? probe.history : [];
  const available = [...new Set(history.map(row => row.deck).filter(Boolean))];
  const configured = state.visibleRun?.config?.decks || [];
  const deckOptions = available.length ? available : configured;
  const latestOverall = history.at(-1);
  if (!deckOptions.includes(state.strengthDeck)) {
    state.strengthDeck = latestOverall?.deck
      || state.visibleRun?.progress?.deck
      || deckOptions[0]
      || "";
  }
  const select = $("strength-deck");
  const currentOptions = [...select.options].map(option => option.value);
  if (JSON.stringify(currentOptions) !== JSON.stringify(deckOptions)) {
    select.replaceChildren(...deckOptions.map(deck => {
      const option = document.createElement("option");
      option.value = deck;
      option.textContent = deckLabels[deck] || deck;
      return option;
    }));
  }
  select.value = state.strengthDeck;
  select.disabled = !deckOptions.length;

  const status = String(probe.status || "waiting");
  const statusNode = $("strength-status");
  const statusLabels = {
    waiting: "等待探针",
    evaluating: "评测中",
    idle: "实时",
    error: "探针错误",
    stopped: "已停止",
  };
  statusNode.textContent = statusLabels[status] || status;
  statusNode.className = `badge ${status}`;

  const rows = history.filter(row => row.deck === state.strengthDeck);
  const latest = rows.at(-1);
  const empty = $("strength-empty");
  const chartWrap = $("strength-chart-wrap");
  empty.hidden = Boolean(latest);
  chartWrap.hidden = !latest;
  if (!latest) {
    const currentDecks = probe.current?.decks || [];
    empty.textContent = status === "evaluating"
      ? `正在评测 ${currentDecks.map(deck => deckLabels[deck] || deck).join("、")} 的固定种子检查点…`
      : "等待首个已提交检查点完成固定种子强度探针。";
  }

  $("strength-delta").textContent = formatPointDelta(latest?.point_delta);
  setStrengthTone($("strength-delta"), latest?.point_delta);
  $("strength-ci").textContent = latest
    ? `${formatPointDelta(latest.ci95?.[0])} ～ ${formatPointDelta(latest.ci95?.[1])}`
    : "—";
  $("strength-change").textContent = formatPointDelta(latest?.change_from_first);
  setStrengthTone($("strength-change"), latest?.change_from_first);
  $("strength-games").textContent = latest ? `${latest.games} 局配对` : "—";
  $("strength-note").textContent = probe.last_error
    ? `探针错误：${probe.last_error}`
    : "该曲线用于观察变化方向，小样本波动较大；最终结论以 2800 局 Godot 门禁为准。";
  renderStrengthChart(rows);
}

function applyEvent(row) {
  const metrics = row.metrics || {};
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
  const speed = Number(metrics.games_per_second);
  $("speed").textContent = Number.isFinite(speed) ? `${speed.toFixed(3)} 局/s` : "—";
  $("eta").textContent = `本阶段 ETA ${
    formatDuration(speed > 0 && total >= completed ? (total - completed) / speed : NaN)
  }`;
  $("gpu").textContent = metrics.gpu_utilization_percent == null ? "—" : `${metrics.gpu_utilization_percent}%`;
  $("vram").textContent = metrics.gpu_memory_used_mb == null ? "—" : `${metrics.gpu_memory_used_mb} / ${metrics.gpu_memory_total_mb} MB`;
  $("replay").textContent = metrics.replay_pool ? sumObject(metrics.replay_pool).toLocaleString() : "—";
  const history = metrics.history_generations || (metrics.history_generation == null ? [] : [metrics.history_generation]);
  $("history").textContent = history.length ? history.map(value => `G${value}`).join(" · ") : "—";
  const losses = metrics.losses || metrics;
  const firstLoss = Object.values(losses).find(item => item && typeof item === "object" && "policy_loss" in item) || losses;
  $("policy-loss").textContent = formatLoss(firstLoss.policy_loss);
  $("value-loss").textContent = formatLoss(firstLoss.value_loss);
  $("choice-loss").textContent = formatLoss(metrics.choice_loss ?? firstLoss.choice_loss);
  const lossCount = metrics.losses_a
    ?? (typeof metrics.losses === "number" ? metrics.losses : "—");
  $("record").textContent = `${
    metrics.wins ?? metrics.wins_a ?? "—"
  } / ${lossCount} / ${metrics.draws ?? "—"}`;
}

function renderRun(run) {
  state.visibleRun = run;
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
  const gate = run.gate || {};
  const gateMetrics = gate.metrics || {};
  const mirrorDelta = gateMetrics.mirror_point_delta;
  const crossDelta = gateMetrics.cross_point_delta;
  $("point-delta").textContent = mirrorDelta == null || crossDelta == null
    ? "—"
    : `${(Number(mirrorDelta) * 100).toFixed(2)}pp / ${(Number(crossDelta) * 100).toFixed(2)}pp`;
  $("promote").disabled = !(run.promotable && gate.status === "passed" && run.status === "completed");
  renderStrength(run.strength_probe || {});
  renderGate(gate);
  renderMatrix((progress.metrics || {}).matchup_matrix || run.matchup_matrix || {});
}

function renderGate(gate) {
  const badge = $("gate-status");
  badge.textContent = {passed: "全部通过", failed: "未通过", not_evaluated: "未评测"}[gate.status] || gate.status || "未评测";
  badge.className = `badge ${gate.status || ""}`;
  const checks = gate.checks || {};
  const entries = Object.entries(checks);
  if (!entries.length) {
    const waiting = document.createElement("li");
    const label = document.createElement("span");
    label.textContent = "等待训练完成及 Release 评测证据";
    const marker = document.createElement("strong");
    marker.textContent = "—";
    waiting.append(label, marker);
    $("gate-list").replaceChildren(waiting);
    return;
  }
  $("gate-list").replaceChildren(...entries.map(([name, value]) => {
    const li = document.createElement("li");
    const passed = value === true || value?.passed === true;
    const label = document.createElement("span");
    label.textContent = gateLabels[name] || name;
    const marker = document.createElement("strong");
    marker.className = passed ? "passed" : "";
    marker.textContent = passed ? "✓" : "—";
    li.append(label, marker);
    return li;
  }));
}

function renderMatrix(matrix) {
  const decks = Object.keys(deckLabels);
  const table = $("matrix");
  const hasValues = decks.some(a =>
    decks.some(b => Number.isFinite(Number(matrix?.[a]?.[b]))));
  $("matrix-empty").hidden = hasValues;
  $("matrix-wrap").hidden = !hasValues;
  if (!hasValues) {
    table.replaceChildren();
    return;
  }
  const header = `<tr><th>牌组</th>${decks.map(deck => `<th>${deckLabels[deck]}</th>`).join("")}</tr>`;
  const rows = decks.map(a => `<tr><th>${deckLabels[a]}</th>${decks.map(b => {
    const value = matrix[a]?.[b];
    return `<td>${value == null ? "·" : `${Number(value) >= 0 ? "+" : ""}${Number(value).toFixed(1)}pp`}</td>`;
  }).join("")}</tr>`).join("");
  table.innerHTML = header + rows;
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
    : "开始 2/2/2 局的 Smoke 链路检查？";
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

async function promote() {
  const run = state.runs.find(row => row.run_id === state.selected);
  if (!run) return;
  const expected = `PROMOTE ${run.run_id}`;
  const confirmation = prompt(`输入以下文本确认原子晋升：\n${expected}`);
  if (confirmation !== expected) return;
  try {
    await api(`/api/v1/runs/${encodeURIComponent(run.run_id)}/promote`, {
      method: "POST",
      body: JSON.stringify({
        evidence_sha256: run.gate.evidence_sha256, confirmation,
      }),
    });
    toast("晋升事务已启动");
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
$("create-release").onclick = () => createRun("release");
$("refresh").onclick = refreshRuns;
$("pause").onclick = () => control("pause");
$("resume").onclick = () => control("resume");
$("cancel").onclick = () => control("cancel");
$("promote").onclick = promote;
$("strength-deck").onchange = event => {
  state.strengthDeck = event.target.value;
  renderStrength(state.visibleRun?.strength_probe || {});
};
boot();
setInterval(() => refreshRuns().catch(() => {}), 10000);
