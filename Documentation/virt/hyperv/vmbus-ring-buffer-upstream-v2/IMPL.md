# IMPL — Fragmentation-resilient VMBus rings across confidential guests

> SSDV3 Step 3 · SPEC: `docs/specs/no-milestone/vmbus-ring-buffer-upstream-v2/SPEC.md`

## Status

**PARTIAL — local design and source draft only. Not ready to send or install.**

The draft at `docs/upstream/patches/vmbus-ring-buffer-v2-draft.patch` is a
working diff against Linux `v7.3-rc4` (`93f51579e7df248780214094418f205253383cc5`).
It is not a replacement kernel, distribution backport, or upstream email.

## Implemented draft

| Path | Intended change |
| --- | --- |
| `include/linux/hyperv.h` | Aggregate ring buffer ownership and separate GPADL layout from decryption. |
| `drivers/hv/channel.c` | Allocate every ring with the accepted chunk allocator; preserve teardown errors and unsafe-to-free state. |
| `drivers/hv/ring_buffer.c`, `drivers/hv/hyperv_vmbus.h` | Resolve each wraparound page from a virtual mapping. |
| `drivers/net/hyperv/hyperv_net.h`, `drivers/net/hyperv/netvsc.c` | Group netvsc allocation fields and retain memory after failed revoke/teardown. |
| `drivers/uio/uio_hv_generic.c` | Map noncontiguous ring pages through virtual UIO and sysfs paths. |

## Evidence so far

- A scratch structural contract test was RED on the unmodified source and
  GREEN (6/6) after the first draft edits. Two additional ownership regressions
  were RED on the draft and GREEN (8/8) after guarding GPADL teardown and UIO
  cleanup. These are **not** KUnit or runtime tests.
- `git diff --check` passed in the upstream worktree.
- Upstream `scripts/checkpatch.pl --no-tree --terse --strict` reported zero
  errors, zero warnings, and zero checks on the draft diff.
- `git apply --check --reverse` confirmed the saved patch matches the local
  upstream worktree.
- On Linux `v7.3-rc4`, `make O=<isolated-build-dir> -j4 W=1
  drivers/hv/channel.o drivers/hv/ring_buffer.o
  drivers/net/hyperv/netvsc.o` passed with no compiler diagnostics.
- The follow-up `make O=<isolated-build-dir> -j4 W=1 drivers/hv/
  drivers/net/hyperv/` also passed with no compiler diagnostics. `sparse` is
  not installed in this environment, so it was not run.
- After adding conservative ownership tracking for a partially posted GPADL,
  the same `W=1` directory build passed again with no compiler diagnostics;
  strict checkpatch still reported zero errors/warnings/checks.
- An explicit `uio_hv_generic.o` build was RED because the old UIO code still
  required `ringbuffer_page`. After conversion to virtual/page-array mapping,
  a combined `W=1` build of Hyper-V, netvsc, and UIO passed with no compiler
  diagnostics. This is still not a live mmap test.
- The current host runs WSL2 `6.18.40.1-microsoft-standard-WSL2+` and has
  neither a CCA nor a TDX guest. It cannot prove the maintainer's cross-CoCo
  objection is closed.
- A later source-only audit found that a failed GPADL teardown could still
  re-encrypt pages, and UIO could free buffers after an ambiguous post or
  teardown. The draft now records an unsafe-to-free flag in each GPADL,
  avoids re-encryption on teardown failure, and checks teardown errors in UIO.
  The 8 structural tests, `git diff --check`, and strict checkpatch pass after
  this change.
- After this audit, the four touched objects (`channel.o`, `ring_buffer.o`,
  `netvsc.o`, and `uio_hv_generic.o`) compiled with `W=1` against the isolated
  v7.3-rc4 build tree. The Hyper-V and netvsc directory builds also completed
  their `built-in.a` archives with `W=1` and no compiler diagnostics. These
  are compile checks, not a linked/booted kernel or fault-injection evidence.
- The booted WSL2 6.18.40.1 source tree was checked read-only. It still owns
  rings through `ringbuffer_page` and does not provide `vmbus_alloc_buffer()`.
  `git apply --check` of this v7.3-rc4 draft failed for all seven touched
  files. This is a confirmed API/backport boundary, not a patch to install
  directly on the host.

## Blocking gaps

1. The SPEC's named functional/fault-injection tests have not been built or
   run. Static source assertions do not substitute for them.
2. The target objects compiled but the kernel has not been linked or booted.
   The available WSL2 6.18 tree predates the accepted allocation API and is
   not this patch's base; a separate backport and isolated-guest validation
   would be required before even considering host installation.
3. The draft marks a partially posted GPADL or failed teardown as unsafe to
   free, but these branches still need real fault injection across every
   header/body/response failure and rescind interleaving. The no-paravisor
   TDX and CCA memory-state contracts remain unverified.
4. CoCo memory-state tests, normal/rescind/close integration tests, UIO/sysfs
   mmap tests, and a
   matched performance run remain absent.

## September 24 candidate update

The reviewable, versioned diff and contribution dossier are maintained in the
public kernel fork at
[`Documentation/virt/hyperv/vmbus-ring-buffer-upstream-v2/`](https://github.com/emersonbusson/WSL2-Linux-Kernel/tree/vmbus-ring-buffer-upstream-v2/Documentation/virt/hyperv/vmbus-ring-buffer-upstream-v2),
based on `93f51579e7df248780214094418f205253383cc5`. The local mainline
checkout contains four commits: `504b66eb5` for ring ownership,
`edd48a46d` for allocator/cleanup safety, `fc5abc6ec` for UIO ownership,
and `52b4700eb` for the corrected fallback-order test vector.
The public dossier carries one patch file per commit under `series/`, plus a
consolidated snapshot. The hosted workflow applies and builds after each patch.

The candidate checks the rounded `u32` allocation size before rounding and
uses `cc_platform_has(CC_ATTR_GUEST_MEM_ENCRYPT)` alongside Hyper-V isolation
to avoid sending arm64 CCA shared pages through `vzalloc()`. UIO's receive and
send GPADL buffers now use `vmbus_alloc_buffer()` and aggregate teardown
ownership. A failed teardown metadata allocation marks the buffer unsafe to
free. The candidate now includes five KUnit cases for page rounding, overflow,
the allocation-order descent, uncertain GPADL release, and partial-allocation
cleanup. They do not inject failures into GPADL header/body posting, exercise
CoCo page-state transitions, or test UIO mmap. These changes have not been
built or tested on CCA, TDX, or SEV-SNP.

Linux `checkpatch.pl --strict` passed on the current patch (0 errors, 0
warnings, 0 checks). The hosted workflow pins the base, records each patch SHA
and configuration, and requires x86_64/arm64 builds with sparse after each
commit and the five KUnit cases above. It creates its KUnit configuration in
the runner. Run 36034196665 passed the WSL build and all three mainline patch
builds on x86_64 and arm64, then exposed an incorrect expected order in the
new fallback test (4/5 tests passed). Commit `52b4700eb` fixes the vector; a
new hosted run is pending. No linked kernel or live Hyper-V guest has been
qualified for this candidate.

The WSL 6.18 backport remains a separate tree. Its DXG destruction path now
keeps user pages pinned while a GPADL is active or uncertain, and releases its
`vmap()` only after confirmed teardown. The hosted WSL build now enables
`DXGKRNL` so that consumer is compiled. DXG's externally pinned user pages
still lack CoCo page-state testing; the exact source candidate has not been
booted there. The
September 17 mailing-list message was unversioned `[PATCH 2/2]`, so the next
submission is v2 if and when all gates pass. No new email was sent.

## Next gate

Complete GPADL header/body/response failure injection, UIO mmap validation,
and teardown/rescind interleaving tests. Then link and boot one isolated
upstream kernel, run Hyper-V integration tests in a disposable guest, and
qualify CCA plus no-paravisor TDX. Only after those results and maintainer
review may the diff be formatted as a sendable v2.

## Rollback trigger

Any freed page with unconfirmed GPADL removal or unknown encryption state,
kernel warning/oops, ring corruption, or >3% matched throughput loss blocks
promotion; restore the previous booted kernel in a lab rather than hot-swap.
