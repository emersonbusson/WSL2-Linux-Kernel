# IMPL — Fragmentation-resilient VMBus ring allocation candidate

> SSDV3 Step 3 · SPEC: `docs/specs/no-milestone/vmbus-ring-buffer-upstream-v2/SPEC.md`

## Status

**PARTIAL — the earlier six-patch candidate passed hosted gates, but the
current seven-patch source has not yet run hosted build/KUnit. Host runtime,
UIO interleaving, and CoCo qualification remain open. Not ready to send or
install.**

The exact source and patch files are in this dossier's `series/` directory
and `vmbus-ring-buffer-v2.patch`, against Linux `v7.3-rc4`
(`93f51579e7df248780214094418f205253383cc5`). The current seventh patch is a
plain unified diff; it is not yet a signed-off upstream email or a replacement
kernel/distribution backport.

## Implemented draft

| Path | Intended change |
| --- | --- |
| `include/linux/hyperv.h` | Aggregate ring buffer ownership and separate GPADL layout from decryption. |
| `drivers/hv/channel.c` | Allocate rings with the chunk allocator; preserve uncertain host ownership and reclaim retained pages only after GPADL, page-state, and mapping-reference gates pass. |
| `drivers/hv/ring_buffer.c`, `drivers/hv/hyperv_vmbus.h` | Resolve each wraparound page from a virtual mapping. |
| `drivers/net/hyperv/hyperv_net.h`, `drivers/net/hyperv/netvsc.c` | Group netvsc allocation fields and retain memory after failed revoke/teardown. |
| `drivers/uio/uio_hv_generic.c` | Map ring, control, receive, and send pages through UIO/sysfs with page protection matching shared/private backing. |

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

1. Hosted CI run 36148296003 passed all six patch stages on x86_64 and arm64,
   the separate WSL backport, and x86_64 KUnit 14/14 (VMBus suite 10/10). The
   added callback-injection case descends through failures above order zero,
   allocates/frees a real order-zero page, then verifies order-zero exhaustion.
   This proves helper behavior under deterministic injection, not fragmentation
   under live memory pressure. Host response/rescind interleaving remains
   untested.
2. The exact candidate kernel has been linked and booted in an ordinary
   x86_64 Hyper-V guest. This does not qualify the separate WSL 6.18 backport
   or any CoCo platform.
3. The GPADL callback tests cover header/body/teardown send errors and
   response-state mapping. Real no-paravisor TDX and CCA memory-state contracts
   remain unverified.
4. CoCo memory-state tests, live rescind/close races, allocator fallback under
   fragmentation, and a matched performance run remain absent. Ordinary
   Hyper-V UIO/sysfs mmap validation is recorded in EVD-0054.

## September 24 candidate update

The reviewable, versioned diff and contribution dossier are maintained in the
public kernel fork at
[`Documentation/virt/hyperv/vmbus-ring-buffer-upstream-v2/`](https://github.com/emersonbusson/WSL2-Linux-Kernel/tree/vmbus-ring-buffer-upstream-v2/Documentation/virt/hyperv/vmbus-ring-buffer-upstream-v2),
based on `93f51579e7df248780214094418f205253383cc5`. The local mainline
checkout contains four commits: `50aac3dc3` for ring ownership,
`ca42ecd6b` for allocator/cleanup safety, `cd8c10eab` for UIO ownership,
and `5959b9109` for the corrected fallback-order test vector. Each has a
complete commit message and `Signed-off-by` trailer.
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
warnings, 0 checks). Hosted run 36038457091 passed per-commit x86_64/arm64
builds and all five named VMBus KUnit cases (9 KUnit cases passed in total);
its WSL job used a nonexistent object target. Run 36039517554 passed arm64 and
x86_64 build/KUnit, but its WSL DXG compile found trace-only variables that
become unused with DEBUG disabled. Commit `e4f31922b` fixed those warnings;
run 36040552037 passed the corrected WSL gate. The workflow records the
base/series SHA, configs, and logs. Sparse runs on WSL VMBus, NetVSC, and UIO
objects; DXG is compile-checked separately because its signed-bitfield
warning prevents a clean Sparse run. These checks do not include GPADL stage
fault injection, UIO mmap, or a linked and booted Hyper-V guest.

The first commit message's unsupported universal CoCo claim has been removed.
The original four mail patches include descriptions and matching `Signed-off-by`
trailers. Run 36042727085 passed WSL but exposed missing trailers on patches
2–4. Run 36046920733 passed with the corrected patch files: per-commit
x86_64/arm64 compile and Sparse, WSL VMBus/NetVSC/UIO Sparse, the separate DXG
compile, and all five named VMBus KUnit cases (nine KUnit cases passed in
total). It builds a pinned Sparse revision and fails if Sparse is not
functional or is silently disabled. UIO mmap and live Hyper-V/CoCo evidence
remain open. The GPADL stage injection candidate is described below.

Sparse logs still contain diagnostics in unchanged baseline code, including
the VMBus driver context-imbalance warning and the flexible-array warning in
the GPADL header declaration. The workflow records these logs; the four
original patches pass strict checkpatch without warnings.

## September 25 GPADL post-injection qualification

Added a fifth patch that routes production GPADL header/body and teardown
posts through a private callback. KUnit injects failure at the header and both
body positions, checks that uncertain ownership remains marked posted, checks
host rejection/rescind response-state mapping, and exercises teardown-post
failure. The changes were rebuilt against the exact state after patches 1–4;
the earlier draft had been reverted because it targeted an obsolete GPADL
structure. The new mail patch applies cleanly to that exact state and passes
strict checkpatch with zero errors, warnings, and checks. Hosted run 36143196834
passed all five patch stages on x86_64 and arm64, the WSL backport, and all 13
x86_64 KUnit tests. The `hyperv-vmbus-buffer` suite passed 9/9, including the
four new GPADL cases; arm64 KUnit was skipped. This covers injected outgoing
post failures and response-state mapping, not real host-response/rescind races,
allocator failure, UIO mmap, or CoCo memory transitions.

The WSL 6.18 backport remains a separate tree. Its DXG destruction path now
keeps user pages pinned while a GPADL is active or uncertain, and releases its
`vmap()` only after confirmed teardown. The hosted WSL build now enables
`DXGKRNL` so that consumer is compiled. DXG's externally pinned user pages
still lack CoCo page-state testing; the exact source candidate has not been
booted there. The
September 17 mailing-list message was unversioned `[PATCH 2/2]`, so the next
submission is v2 if and when all gates pass. No new email was sent.

## September 25 order-zero injection patch

A sixth patch factors the production order-descent allocation loop behind a
private callback. Its KUnit case injects failure at every order above zero,
then allows a real order-0 allocation and frees it; a second pass injects
order-0 failure and checks clean exhaustion. The patch applies after patch 5
and passes strict checkpatch locally. Hosted x86_64/arm64 build and KUnit
qualification passed in run 36148296003: all six stages built on x86_64 and
arm64, the WSL backport passed, and x86_64 KUnit passed 14/14 (VMBus suite
10/10). The artifacts bind to base
`93f51579e7df248780214094418f205253383cc5` and series commit
`dbec28671d5f7bb3c1017151574a7649019671aa`. Real allocator fragmentation,
live response/rescind interleavings, and CoCo SEV-SNP/TDX/CCA transitions
remain lab gates. Ordinary Hyper-V UIO mmap is recorded in EVD-0054.

## WSL rescind ownership follow-up — unbuilt

The WSL backport branch now keeps an explicit GPADL state (`NONE`, `PENDING`,
`UNCERTAIN`, `LIVE`, or `TEARING_DOWN`) and reserves an owner record before
allocating a buffer. A create candidate is recorded before the first post; an
explicit `GPADL_CREATED` rejection clears it, while missing/partial responses
retain the candidate and its backing pages. A teardown allocation failure
restores `LIVE` because no teardown was posted. Once a teardown may have reached
the host, only a matching `CHANNELMSG_GPADL_TORNDOWN` response clears the
handle. Concurrent teardown attempts are rejected while one is in flight.

The rescind path records host provenance separately from generic channel
removal. Locally synthesized suspend rescinds and unload marks do not set that
provenance. The backport does not treat a host rescind alone as sufficient to
reclaim VMBus-owned pages. Ownerless DXG GPADLs keep their caller-managed
lifecycle; DXG stops the allocation before teardown and does not call
`vmbus_free_buffer()`. Local suspend/unload and ambiguous partial creates
remain retained. Independent `leak` and unknown-encryption flags also prevent
reclamation.

For buffers whose GPADL teardown is acknowledged, the UIO lifetime audit found
that device unregister does not wait for existing `/dev/uio` mappings. Its
fault handler takes a page reference for each mapped virtual page, and the
sysfs ring path uses `vm_map_pages()`. The backport now checks those references
for both page chunks and `vzalloc()` backing before re-encryption or release.
If references remain, the owner stays retained and a delayed worker retries
once per second; it frees only after references return to the allocator
baseline and GPADL/encryption state is known. VMBus module exit cancels pending
reclaim work and drains active work before unloading. Host rescind and
ambiguous teardown remain retained because their GPADL ownership is not
cleared. These source changes still need hosted build/KUnit and live mmap
close/unregister validation.

The legacy UIO mmap callback now maps all five regions with kernel page
references, rejects `MAP_PRIVATE`, and applies decrypted page protection to
shared ring/receive/send backing and the monitor page. Private `vzalloc()` and
interrupt-page mappings keep the default protection. The sysfs ring path uses
zero-based page insertion after validating the user offset, so its page offset
is applied once. Three named UIO KUnit cases cover mapping bounds, offset
selection, and protection selection; hosted execution is still pending.

The allocator now checks page rounding before storing the aligned size in its
`u32` field; requests that would round to 4 GiB are rejected instead of
wrapping the recorded size to zero. Host-visible buffers use page chunks on
arm64 because `hv_is_isolation_supported()` has only a weak default there,
while arm64 confidential guests use the generic memory-encryption callbacks.
Guest-private buffers continue to use `vzalloc()`. KUnit cases cover the
rounding boundary and arm64 shared-page selection. An additional KUnit case
checks that a live reference delays `vzalloc()` release, alongside the chunk
reference test. The current backport suite contains 11 cases; hosted build and
KUnit have not run on this source revision.

Named KUnit cases cover owner-backed versus ownerless rescind handling, create
response racing rescind, ambiguous partial post, teardown acknowledgment and
pre-post allocation rollback, re-encryption failure, page-reference deferral
for chunk and `vzalloc()` backing, and repeated cleanup. The UIO suite covers
shared-map/range validation, offset selection, and per-region page protection.
They exercise
production state helpers and retention, but do not drive real VMBus message
posting or host interleavings. Hosted build and KUnit are required for this
follow-up. The observed `vmbus_alloc_buffer`
vmalloc-map growth remains consistent with retained GPADL-backed buffers but
does not prove that rescind handling caused the host incident; allocator
ownership and live channel attribution are still needed to establish that
causal link.

## September 28 mainline retained-owner patch

The earlier WSL-backport section above describes that separate backport and
its remaining UIO mapping gap. The current seven-patch mainline candidate has
a production retained-owner list and delayed reclaimer. It records channel
lifetime identity, keeps pages after uncertain GPADL posts/teardowns or unknown
encryption state, and waits for page references to return to the allocator
baseline before releasing pages. UIO and sysfs ring mappings use the
kernel-page mapping action, which takes references for inserted pages. The UIO
callback now selects backing-page arrays for all five map slots, preserves
`VM_DONTEXPAND`/`VM_DONTDUMP`, rejects private mappings, and sets
`pgprot_decrypted()` for shared ring/receive/send pages and the decrypted
monitor page. Private `vzalloc()` buffers and the interrupt page keep the
default protection. This fixes a source-level encrypted-alias mismatch found
in the latest review; page-state behavior still needs hosted compile and CoCo
runtime qualification.

The source keeps the original exported allocator/free, GPADL establish,
caller-decrypted establish, and teardown signatures. Migrated in-tree callers
use descriptor-aware `_owned` APIs. KUnit source now names 16 VMBus cases and
four UIO mmap cases for range handling, page selection, shared/private mapping,
and protection choice; runtime KUnit has not run on this current series.

Local source qualification: seven ordered patches apply cleanly to the pinned
base; `git diff --check` and cumulative strict checkpatch pass at each stage;
the resulting nine touched source files match the exact candidate byte for
byte. The CI workflow was changed to run checkpatch against each applied
cumulative source diff, then build that stage. The duplicate stale seventh
patch was removed and the consolidated snapshot regenerated.

These local checks do not include compilation. Hosted run `36148296003`
qualified the previous six-patch series, not this seventh patch or the
latest API adapters. No build or KUnit execution has been performed on this
exact candidate, and no local heavy build, install, stress, or CoCo test was
run. The implementation treats a host-generated rescind as GPADL revocation;
Linux VMBus documentation describes device removal but does not explicitly
define the GPADL page-access ordering. That ordinary Hyper-V interleaving must
be tested before sending. CoCo transitions, live UIO mmap/unregister races,
and performance remain open. No all-architecture or universal CoCo claim is
made.

## Rollback trigger

Any freed page with unconfirmed GPADL removal or unknown encryption state,
kernel warning/oops, ring corruption, or >3% matched throughput loss blocks
promotion; restore the previous booted kernel in a lab rather than hot-swap.
