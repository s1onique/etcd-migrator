# Doctrine

This directory contains the core migration doctrine and safety boundaries for etcd-migrator.

## Documents

- [Migration Contract](migration-contract.md) - What the tool preserves and does not preserve
- [Safety Boundaries](safety-boundaries.md) - When it's safe to use etcd-migrator
- [Verification Doctrine](verification-doctrine.md) - How to verify migration correctness

## Core Principles

1. **Offline-first**: The tool operates on snapshots, not live replication
2. **Narrow scope**: Only raw keys and values are preserved; metadata is recorded but not restored
3. **Deterministic**: Digest-based verification ensures consistency across runs
4. **LLM-friendly**: Small, focused files that are easy to understand and modify
