# Corrected VMBus validation plan

This unsent kernel snapshot replaces the withdrawn source for new validation.
The manifest pins every mail and the expected applied source tree.

1. PASS: all thirteen W=1/C=2 stages on x86_64 and arm64 (37402766418).
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
