# Bounded ordinary local integrity

The installed ordinary WSL backport is distinct from the thirteen mainline
mails. Its source is 22d912949f44c0b377f7612d048d92a2b9a6ee79, kernel GNU
identity 524c9914b466a5407e6a215424fb745087fc926c, and complete running-note
SHA-256 c20ab50c62d0c83f30f650aef7fcdf2ef27a2b785b5ebd1348badc50c4e05b2a.

On 2026-10-06 UTC, two Windows-supervised ordinary local rounds each verify
3,200 MiB in fifty chunks with equal before/after SHA-256 digests. ZRAM is
observed first at 19 seconds in each round; NBD follows at 59/57 seconds.
Captured logical NBD occupancy peaks at 40,956 KiB. Fallback SSD swap remains
unused; authoritative origin writes are recorded separately. Swapoff-first
cleanup proves both managed tiers absent before daemon release. The guest
boot and kernel/daemon bytes remain unchanged. The previous topology is
restored and fresh readiness returns healthy. No observed kernel fault or
distribution restart/termination occurs.

The preceding unpaced attempt stops at the existing PSI-full threshold and
verifies 2,752 MiB. The retry spaces existing 64 MiB allocations by 1,000 ms
without lowering any host reserve, guest limit, PSI threshold or ownership
guard. All private identity/checksum/custody records are retained.

The completed retry's old harness reports PASS for integrity and cleanup.
Independent phase/monitor review finds guarded control at all four before/
after checkpoints and two measurement-error records, including stale guardian
telemetry. The corrected current-schema outcome reader accepts the proved
cleanup but rejects whole-campaign control qualification for those captures.
Historical output is preserved; it is not rewritten. Native regressions
cover both acceptance and refusal of these actual records.

Scope: bounded ordinary installed-backport ZRAM/NBD integrity PASS; host-
control continuity PARTIAL. This is not a three-tier saturation, prolonged
operation, mainline unload, confidential transition or performance result.
No mail or send qualifier.
