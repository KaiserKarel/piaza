---
description: Run one review tick — pick up to N pending crates and review each.
argument-hint: [batch-size]
---

Run one tick of the review queue. This is the entry point the scheduled
agent calls.

Batch size is `${1:-5}` — review at most that many crates per tick to keep
each run bounded.

Steps:

1. Refresh the pending queue:
   ```
   ./scripts/tick.sh enumerate > /tmp/pending.tsv
   ```
   Each line is `name<TAB>version<TAB>checksum`. The script already excludes
   crates with an existing proof in `proofs/`.

2. Pick the first `${1:-5}` lines. Prefer ordering that prioritizes:
   - Direct dependencies of targets first (depth=1)
   - Then transitive deps
   - Within a tier, alphabetical so it's deterministic
   `tick.sh enumerate` already sorts this way.

3. For each picked `(name, version)`:
   - Run `/review-crate <name> <version>` as a self-contained subtask. Each
     review is one commit; do not batch them.
   - If a review fails, log it to `/tmp/review-errors.log` and continue with
     the next. Don't abort the tick on a single failure.

4. After the batch, summarize: how many reviewed, how many failed, list of
   failures. Don't push — pushing is the operator's call.

Important: each review is independent. Don't carry state between them in
your head. Start each `/review-crate` invocation fresh.
