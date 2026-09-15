"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const source = fs.readFileSync(path.join(__dirname, "../tools/ai_training_dashboard/app.js"), "utf8");
const nodes = new Map();
function element() { return {textContent: "", children: [], append(value) { this.children.push(value); },
  replaceChildren(...values) { this.children = values; }, setAttribute() {}}; }
const context = {state: {selected: "run", anchorHistory: new Map(), anchorContext: ""}, deckLabels: {fire: "火"},
  $: id => { if (!nodes.has(id)) nodes.set(id, element()); return nodes.get(id); },
  document: {createElement: element, createElementNS: element}, formatDuration: value => `${value || 0}s`};
vm.createContext(context);
vm.runInContext(source.slice(source.indexOf("function renderEvaluation("), source.indexOf("function applyEvent(")), context);
context.renderEvaluation({games: 10, wins: 2, draws: 1}, 1);
assert.equal(nodes.get("record").textContent, "— / — / —");
context.renderEvaluation({schema: "ptcg.ai_evaluation.report/1", mode: "promotion", gate_status: "inconclusive",
  games: 10, strength_games: 4, record: {wins: 2, losses: 1, draws: 1},
  strength: {status: "inconclusive", estimate: .625, interval: [null, null], confidence_level: .975, blocks: 1},
  anchor: {estimate: null, interval: [null, null]},
  per_deck: {fire: {estimate: null, interval: [null, null], status: "inconclusive"}}}, 1);
assert.equal(nodes.get("record").textContent, "2 / 1 / 1");
assert.match(nodes.get("evaluation-interval").textContent, /证据不足/);
assert.match(nodes.get("evaluation-verdict").textContent, /证据不足/);
assert.equal(nodes.get("evaluation-games").textContent, "4 / 10");
assert.equal(nodes.get("evaluation-decks").children.length, 1);
console.log("EVALUATION_DASHBOARD_OK");
