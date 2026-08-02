# AlphaZero v2 native evidence

This directory versions only the compact evidence needed to reproduce and audit
the native AlphaZero v2 implementation. Raw trajectories, smoke runs, tuning
tables, process logs, checkpoints, and generated training data are intentionally
ignored.

The retained files cover:

- Python/C++/Godot action, choice, event, and RNG parity;
- information-set privacy and hidden-identity invariance;
- Godot native runtime and golden-rule contracts;
- native search batching and throughput benchmarks.

These artifacts validate implementation contracts only. They do **not** claim
that the v2 trained model met the strength, wall-clock, or release gates. Runtime
promotion remains disabled until a separately recorded candidate passes every
release requirement.
