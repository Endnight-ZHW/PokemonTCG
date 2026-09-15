"""Reproducible coverage/power audit; simulated data, never promotion evidence."""
from __future__ import annotations
import argparse
import json
import math
import sys
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))
from deep_ai.evaluation_statistics import BoundedMeanCS
from deep_ai.challenge_arena_build import write_json_atomic


def wilson_upper(successes: int, total: int) -> float:
    z = 1.6448536269514722  # one-sided 95% Wilson upper bound
    p = successes / total
    return (p + z*z/(2*total) + z*math.sqrt(p*(1-p)/total+z*z/(4*total*total))) / (1+z*z/total)


def simulate(*, cohorts: int, delta: float, trials: int, alpha: float, seed: int) -> dict:
    rng = np.random.default_rng(seed)
    scale = np.array([.5]*10+[1.0]*45)
    total = np.zeros(cohorts); variance = np.zeros(cohorts)
    stratum = np.zeros((cohorts,55)); lower = np.zeros(cohorts); upper = np.ones(cohorts)
    detected = np.zeros(cohorts,dtype=bool); missed = np.zeros(cohorts,dtype=bool)
    first = np.zeros(cohorts,dtype=int)
    weights = {i:(1 if i<10 else 2)/100 for i in range(55)}
    reference = BoundedMeanCS(weights, alpha=alpha)
    checkpoints = {}
    for rep in range(1,101):
        # A block contains fully correlated Bernoulli subunits. Four effective
        # trials gives block variance about .0625; one gives the worst .25 case.
        raw = rng.binomial(trials,.5+delta,size=(cohorts,55))/trials
        z = .5+scale*(raw-.5)
        predicted = (.5+stratum)/rep
        variance += ((z-predicted)**2).sum(axis=1)
        stratum += z; total += z.sum(axis=1)
        n = rep*55; v = np.maximum(variance,1)
        epoch = np.log2(v)
        ell = np.log((epoch+1)*(epoch+2)/(alpha/2))
        k1 = (2**.25+2**-.25)/math.sqrt(2); k2=(math.sqrt(2)+1)/2
        boundary = np.sqrt(k1*k1*v*ell+k2*k2*ell*ell)+k2*ell
        point = .5+1.1*(total/n-.5)
        radius = 1.1*boundary/n
        lower = np.maximum(lower,point-radius); upper = np.minimum(upper,point+radius)
        missed |= (lower > .5+delta) | (upper < .5+delta)
        reference.add_round(dict(enumerate(raw[0])))
        # Check vectorization against the production implementation each round.
        if not np.allclose(reference.snapshot()["interval"],[lower[0],upper[0]],atol=1e-12):
            raise AssertionError("calibration_vectorization_mismatch")
        if rep>=5:
            now = lower>.5
            first[(first==0)&now]=rep*400
            detected |= now
        if rep in (25,50,100):
            checkpoints[str(rep*400)]={"detection_rate":float(detected.mean()),
                                      "median_interval_width":float(np.median(upper-lower))}
    return {"cohorts":cohorts,"true_score_delta":delta,"effective_trials_per_block":trials,
            "block_variance":(.5+delta)*(.5-delta)/trials,"alpha":alpha,
            "miscoverage_rate":float(missed.mean()),"miscoverage_upper_95":wilson_upper(int(missed.sum()),cohorts),
            "false_improvement_upper_95":wilson_upper(int(detected.sum()),cohorts) if delta==0 else None,
            "median_games_when_detected":float(np.median(first[first>0])) if first.any() else None,
            "checkpoints":checkpoints}


def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cohorts",type=int,default=10000)
    parser.add_argument("--output",type=Path,required=True)
    args=parser.parse_args()
    if args.cohorts<10000: parser.error("at least 10,000 cohorts are required")
    cases=[(0,1,.025),(0,4,.025),(.025,4,.025),(.025,4,.025/20),(.025,1,.025)]
    rows=[simulate(cohorts=args.cohorts,delta=d,trials=t,alpha=a,seed=20260915+i) for i,(d,t,a) in enumerate(cases)]
    passed=all(r["miscoverage_upper_95"]<=.05 for r in rows)
    passed &= all(r["false_improvement_upper_95"]<=.05 for r in rows if r["true_score_delta"]==0)
    passed &= all(r["checkpoints"]["40000"]["detection_rate"]>=.8 for r in rows if r["true_score_delta"]==.025 and r["effective_trials_per_block"]==4)
    payload={"schema":"ptcg.ai_evaluation.calibration/1","simulated":True,"passed":bool(passed),
             "target_effect":.025,"target_power":.8,"declared_block_variance":.0625,
             "limitation":"Power depends on block variance; the worst-case row is a sensitivity analysis, not a promised detection rate.","cases":rows}
    write_json_atomic(args.output,payload)
    print(json.dumps(payload,ensure_ascii=False))
    return 0 if passed else 3


if __name__=="__main__": raise SystemExit(main())
