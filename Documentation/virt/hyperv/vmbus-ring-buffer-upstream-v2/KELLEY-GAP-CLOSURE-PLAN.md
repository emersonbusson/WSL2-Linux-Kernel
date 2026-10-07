# Qualification status — 2026-10-07

The exact fourteen-patch series now passes its architecture, KUnit, and
ordinary Hyper-V runtime gates. The host-rescind subgate passes on both
windows-2025 and windows-latest, and the intended baseline negative control
passes its exact-signature policy. Current evidence and scope are recorded in
MANIFEST.txt and the refreshed cover letter.

The original pre-qualification plan below is retained as historical context;
its earlier test counts and pending-run statements are superseded by the
qualification update. Its exact original bytes are preserved at
history/KELLEY-GAP-CLOSURE-PLAN-pre-final-qualification-20261007.md.

Mail-package audit is complete: all fourteen patch hashes pass, DCO author
and sign-off identities match 14/14, and get_maintainer.pl maps the series to
linux-hyperv, netdev, linux-kernel and their listed maintainers. Fixes tags
present in patches 0012 and 0013 resolve to commits in the source repository.
Strict checkpatch has zero errors; the remaining warnings are the generic
new-file/MAINTAINERS notices for the added KUnit files.

The package is ready for maintainer review with these explicit limits:
confidential hardware transitions, full saturation, and complete VMBus
module unload/retained-owner destruction remain unqualified. The separate
local WSL candidate remains uninstalled pending a safe maintenance window.
No e-mail has been sent.

# Corrected VMBus validation plan

This unsent kernel snapshot replaces the withdrawn source for new validation.
The original measurements below qualify the prior thirteen-patch snapshot
only. Patch 0014 changes the large NetVSC device-state allocation, so the
current fourteen-patch tree requires fresh architecture and runtime runs.
The manifest pins every mail and the expected applied source tree.

1. Historical PASS: all thirteen W=1/C=2 stages on x86_64 and arm64
   (37402766418).
2. PASS: all 68 linked mainline QEMU cases, including native queue/MM cases.
3. Keep the 25-case WSL backport and actual Windows results separate.
4. Ordinary mainline lifecycle/rescind PASS on both disposable runners
   (37405207883); fragmentation PASS on windows-2025 and PARTIAL on
   windows-latest at the safety cap. Bounded local active-data integrity
   passes two 3,200 MiB rounds; guarded/stale control evidence still refuses
   whole-host qualification. Full three-tier pressure remains unmeasured.
5. Preserve explicit limits on full unload/destruction and confidential guests.
6. Reaudit final source, cover, routing, DCO/Fixes and exact mail bytes.

The original send qualifier remains withdrawn. A green build does not permit
unqualified claims or substitute for the final review. No email has been sent.
