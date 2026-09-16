"""Development-only protection of the best observed score for every deck."""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Sequence

from .challenge_arena_build import sha256_file
from .evaluation_protocol import EvaluationProtocol, GameEvidence
from .evaluation_fairness import canonical_hash, rules_content_hash


def _sealed_run(directory: Path) -> tuple[EvaluationProtocol, list[dict], dict]:
    manifest = json.loads((directory / "arena-manifest.json").read_text(encoding="utf-8"))
    if manifest.get("schema") != "ptcg.ai_evaluation.manifest/1":
        raise ValueError("protection_manifest_schema_invalid")
    protocol = EvaluationProtocol.from_dict(manifest["protocol"])
    if manifest.get("fingerprint") != protocol.fingerprint:
        raise ValueError("protection_protocol_mismatch")
    for name in ("games", "summary"):
        path = directory / ("arena-games.jsonl" if name == "games" else "arena-summary.json")
        if sha256_file(path) != manifest[name + "_sha256"]:
            raise ValueError("protection_evidence_hash_mismatch")
    rows = [json.loads(line) for line in (directory / "arena-games.jsonl").read_text(encoding="utf-8").splitlines()]
    tasks = {t.task_id: t for edge in protocol.comparisons
             for rep in range(protocol.maximum_replicates) for t in protocol.tasks(edge, rep)}
    if len(rows) != len(tasks) or {row["task_id"] for row in rows} != set(tasks):
        raise ValueError("protection_incomplete_matrix")
    for row in rows:
        GameEvidence.verify(protocol, tasks[row["task_id"]], row)
        if not row["strength_eligible"]:
            raise ValueError("protection_unreliable_game")
    summary = json.loads((directory / "arena-summary.json").read_text(encoding="utf-8"))
    if summary.get("protocol_fingerprint") != protocol.fingerprint or not summary["evidence"]["finalized"]:
        raise ValueError("protection_unsealed_report")
    return protocol, rows, summary


def _rules_identity(protocol: EvaluationProtocol, directory: Path) -> str:
    context = protocol.context
    semantic = context.get("rules_hash_schema") == "card_semantics_v1"
    expected = context.get("catalog_bundle_hash") if semantic else context["rules_hash"]
    if not isinstance(expected, str) or len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected):
        raise ValueError("protection_rules_evidence_missing")
    for role in ("candidate", "champion", "anchor"):
        path = directory / "runtime" / role / ".inputs" / f"catalog-{expected}.json"
        if not path.is_file():
            continue
        catalog = json.loads(path.read_text(encoding="utf-8"))
        if canonical_hash(catalog) != expected:
            raise ValueError("protection_rules_evidence_hash_mismatch")
        normalized = rules_content_hash(catalog)
        if semantic and normalized != context["rules_hash"]:
            raise ValueError("protection_rules_evidence_hash_mismatch")
        return normalized
    raise ValueError("protection_rules_evidence_missing")


def protect_anchor_scores(candidate_run: Path, protected_runs: Sequence[Path]) -> dict[str, Any]:
    """Require each deck to meet both sides of every prior sealed anchor screen.

    Conditions and anchor identity must match. This deliberately rejects scores
    from another seed cohort; finite development results are not promotion evidence.
    """
    if not protected_runs:
        raise ValueError("protection_reference_required")
    p, rows, summary = _sealed_run(candidate_run)
    if p.backend != "challenge" or p.mode != "screen" or p.comparisons != ("ac", "ah", "ch"):
        raise ValueError("protection_requires_paired_challenge_screen")
    def conditions(protocol: EvaluationProtocol, edge: str) -> list[dict]:
        return [task.conditions() for rep in range(protocol.maximum_replicates)
                for task in protocol.tasks(edge, rep)]
    def scores(records: list[dict], edge: str) -> dict[str, float]:
        return {deck: sum(row["candidate_score_x2"] / 2 for row in records
                         if row["comparison"] == edge and row["candidate_deck"] == deck)
                for deck in p.decks}
    current = scores(rows, "ah")
    references = []
    for directory in protected_runs:
        prior, records, _ = _sealed_run(directory)
        if (prior.backend != p.backend or prior.decks != p.decks or
                prior.participants["anchor"] != p.participants["anchor"] or
                any(prior.context.get(key) != p.context.get(key) for key in (
                    "decks_hash", "rules_profile", "apply_type_matchups"))):
            raise ValueError("protection_anchor_or_rules_mismatch")
        if (prior.context["rules_hash"] != p.context["rules_hash"] and
                _rules_identity(prior, directory) != _rules_identity(p, candidate_run)):
            raise ValueError("protection_anchor_or_rules_mismatch")
        for edge, role in (("ah", "candidate"), ("ch", "champion")):
            if edge not in prior.comparisons or conditions(prior, edge) != conditions(p, "ah"):
                raise ValueError("protection_scenario_mismatch")
            # Fixed search work must match; the engine may be historical.
            actual = {k: v for k, v in p.participants["candidate"].get("options", {}).items()
                      if k not in {"engine", "use_strategy_optimization"}}
            expected = {k: v for k, v in prior.participants[role].get("options", {}).items()
                        if k not in {"engine", "use_strategy_optimization"}}
            if actual != expected:
                raise ValueError("protection_search_contract_mismatch")
            references.append({"protocol_fingerprint": prior.fingerprint, "comparison": edge,
                               "participant": prior.participants[role], "scores": scores(records, edge)})
    per_deck = {}
    for deck in p.decks:
        count = sum(row["comparison"] == "ah" and row["candidate_deck"] == deck for row in rows)
        floor = max(reference["scores"][deck] for reference in references)
        per_deck[deck] = {"games": count, "score_rate": current[deck] / count,
                          "protected_score_rate": floor / count,
                          "difference": (current[deck] - floor) / count,
                          "passed": current[deck] >= floor}
    passed = summary["gate_status"] == "pass" and all(row["passed"] for row in per_deck.values())
    return {"schema": "ptcg.challenge_strategy_protection/1", "gate_status": "pass" if passed else "fail",
            "development_only": True, "promotion_passed": False, "allowed_regression": 0,
            "protocol_fingerprint": p.fingerprint, "references": references, "per_deck": per_deck,
            "uncertainty": "Finite paired development scores; no statistical noninferiority or promotion claim."}
