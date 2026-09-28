# SPEC — Fragmentation-resilient VMBus rings across confidential guests

## Closed scope

Prepare a locally testable upstream v2 against Linux v7.3-rc4. In scope:
`drivers/hv/channel.c`, `drivers/hv/ring_buffer.c`,
`drivers/hv/hyperv_vmbus.h`, `include/linux/hyperv.h`,
`drivers/uio/uio_hv_generic.c`, and the netvsc
buffer owner. Out of scope: balloon/watermark changes from the former 1/2
patch, WSL deployment, and upstream transmission. The upstream tag already
contains Kameron Carr's `vmbus_alloc_buffer()` series.

## Traceability

| PRD | SPEC |
| --- | --- |
| RF-1 | ITEM-2, ITEM-4 |
| RF-2 | ITEM-2, ITEM-3 |
| RF-3 | ITEM-1, ITEM-3, ITEM-5 |
| RF-4 | ITEM-3, ITEM-5, ITEM-6 |
| RF-5 | ITEM-4, ITEM-5, ITEM-6 |
| NFR-1 | ITEM-2, ITEM-5 |
| NFR-2 | ITEM-6 |

## Technical decisions

| ID | Decision | Reason |
| --- | --- | --- |
| DT-1 | One `struct vmbus_buffer` owns address, chunks, GPADL, and leak state | Avoid split lifetime metadata and make unsafe-to-free explicit. |
| DT-2 | Ring and netvsc pass their own confidentiality flag to allocation | `co_ring_buffer` and `co_external_memory` are distinct contracts. |
| DT-3 | GPADL layout (`BUFFER` vs `RING`) is separate from whether the caller already handled encryption | A ring needs gap/offset encoding but may already be decrypted. |
| DT-4 | Ring wraparound maps `vmalloc_to_page()` results from the virtual buffer | The allocator no longer promises one contiguous `struct page` array. |
| DT-5 | Failed teardown or unknown re-encryption retains backing pages; cleanup is idempotent | The host may still access them, or their private/shared state may be unknown. |
| DT-6 | Preserve the existing exported GPADL and buffer allocator/free signatures; add descriptor-aware `_owned` entry points for migrated in-tree users | Avoid an unrelated exported-API migration while keeping owned lifetime state attached to the new call sites. |
| DT-7 | Give each owned buffer a page-pointer array for UIO/sysfs mapping, and expose UIO memory as virtual with page protections matching each backing page's encryption state | A single physical range is no longer valid, and userspace aliases must agree with the shared/private page state. |
| DT-8 | Keep backing pages on a channel-keyed retained-owner list until GPADL ownership is resolved, page-state is known, and page references return to the allocator's baseline | Close the asynchronous UIO mapping and GPADL lifetime gap without freeing pages still mapped or host-visible. |

## Atomicity and rollback

Allocation, GPADL messages, and `vmap`/`vunmap` run in sleepable process
context. No spinlock is held across allocation or host response wait.
The host-ownership frontier begins when the first GPADL post may have reached
the host. Backing pages remain retained after an ambiguous post or teardown.
The current implementation treats a host-generated channel rescind as a
revocation event; the upstream VMBus documentation describes device removal
but does not spell out the GPADL page-revocation ordering. That assumption
remains a runtime/protocol qualification gate. Before reclaim, page-state must
be known and all mapping references must be gone. No userspace or persistent
host state changes occur during patch preparation. A test kernel is rolled
back by rebooting the prior image.

## Kahneman map

| Stage | Discipline | Question | Minimum executable evidence | Abort |
| --- | --- | --- | --- | --- |
| ITEM-2 | #13 refusal/legitimate | Do private and shared ring/UIO mappings use the correct backing pages and page protections? | Named KUnit allocation, map-selection, and page-protection tests plus CoCo lab | Any decryption on a `vmap()` alias or encrypted mapping of shared pages |
| ITEM-3 | #16 exhaustion | Does a high-order allocation failure fall to smaller chunks without exposing partial pages? | Fault-injection allocation test | Any freed page with unknown encryption state |
| ITEM-5 | #17 replay | Can close/error cleanup repeat without double free? | Named teardown/failure-injection test | Double free, host-visible free, or nonzero GPADL retained as safe |

## Security checklist

- Privilege/uAPI: N/A — no new user interface.
- Host copy: GPADL physical page list remains bounded by validated buffer size.
- IRQ/atomic: all touched allocation and unmapping paths remain process-context.
- Lifetime: one buffer owns backing pages, mapping, and GPADL state.
- CoCo: direct-map decryption precedes virtual mapping; failed re-encryption leaks.
- Host safety: no pressure or kernel install on the daily WSL2 environment.
- Replay: a cleaned buffer cannot be freed a second time.

## Files and implementation order

1. **ITEM-1:** Extend `include/linux/hyperv.h` with `struct vmbus_buffer` and replace split ring/netvsc buffer fields.
2. **ITEM-2:** Update `drivers/hv/channel.c` allocation/free API to accept the correct confidentiality condition and the aggregate owner.
3. **ITEM-3:** Decouple GPADL layout from encryption state; retain host ownership on teardown uncertainty.
4. **ITEM-4:** Update `drivers/hv/ring_buffer.c` and `drivers/hv/hyperv_vmbus.h` to map the virtual ring's backing pages.
5. **ITEM-5:** Convert ring, netvsc, and UIO call sites and their failure unwinds to the aggregate lifecycle.
6. **ITEM-6:** Run style/build/static/fault-injection and isolated live tests; write exact result in `IMPL.md`.

## Required tests matrix

| Production path | Named test | Kind | Cover |
| --- | --- | --- | --- |
| Page rounding | `vmbus_buffer_size_rounding_test` | KUnit | N/A — kernel slice |
| Page-rounding overflow | `vmbus_buffer_size_overflow_test` | KUnit | N/A — kernel slice |
| Allocation-order descent | `vmbus_ring_fallback_order_zero_test`, `vmbus_buffer_order_zero_allocation_test` | KUnit helper test plus injected failures above order 0; exercises a real order-0 allocation and order-0 exhaustion | N/A — kernel slice; live fragmentation drill remains required |
| GPADL release ownership predicate | `vmbus_buffer_failed_teardown_leaks_test` | KUnit predicate test; callback-injected header/body/teardown post failures and response-state mapping are covered separately | N/A — kernel slice; live response/rescind drill |
| Retained GPADL lifetime | `vmbus_buffer_owner_reclaim_gate_test`, `vmbus_buffer_reclaim_schedule_gate_test`, `vmbus_buffer_host_revoke_state_test`, `vmbus_buffer_repeated_owner_release_test` | KUnit state/scheduling tests; does not prove concurrent host protocol behavior | N/A — kernel slice; live acknowledgment/rescind interleaving |
| UIO backing-page lifetime and page state | `vmbus_buffer_mapping_reference_test`, `hv_uio_ring_mmap_prepare_test`, `hv_uio_mmap_region_select_test`, `hv_uio_mmap_prepare_test` | KUnit verifies range checks, UIO map selection, MAP_SHARED refusal, private/shared page protection, and page-reference reclamation gate | N/A — kernel slice; live UIO mmap close/unregister race |
| Legacy exported API compatibility | `vmbus_alloc_buffer`, `vmbus_free_buffer`, `vmbus_establish_gpadl`, `vmbus_establish_gpadl_caller_decrypted`, `vmbus_teardown_gpadl` | Hosted compile and symbol/prototype checks; adapters preserve the legacy signatures | N/A — compile/static contract; external module integration remains untested |
| Partial allocation cleanup | `vmbus_buffer_partial_allocation_cleanup_test` | KUnit | N/A — kernel slice; allocation fault injection still required |
| GPADL message post ordering and failure ownership | `vmbus_gpadl_post_failure_test`, `vmbus_gpadl_post_success_test`, `vmbus_gpadl_response_state_test`, `vmbus_gpadl_teardown_post_failure_test` | KUnit with injected post callback; exercises header, each body position, teardown, host rejection status, and rescind status | N/A — kernel slice; live Hyper-V response/rescind remains required |
| Confidential ring GPADL | `vmbus_ring_buffer_coco_decrypt_once` | CoCo lab; not implemented | N/A — kernel slice; CCA/TDX/SNP evidence |
| Netvsc buffer migration | `netvsc_buffer_lifecycle` | integration / Hyper-V lab | N/A — kernel slice; live drill |
| UIO ring and buffer mapping | `hv_uio_mmap_prepare_test` | Four named KUnit cases cover sysfs ring offsets and UIO ring/control/receive/send map selection and protection; live mmap/close/unregister drill remains unqualified | N/A — kernel slice; Hyper-V runtime drill |

## Observability and living docs

Kernel warnings report only stable error codes and buffer role; no addresses.
Update this SPEC, `AUDIT-2.5.md`, `IMPL.md`, `trovaldo.md`, and
`validation.md` with observed results. The public README is unchanged until
new qualification exists.

## Validation checklist

- [ ] RED tests execute against unmodified upstream source.
- [ ] Named tests above execute and pass.
- [ ] `scripts/checkpatch.pl` accepts each cumulative source diff after patch application; `git diff --check` passes after each patch.
- [ ] Targeted Hyper-V and netvsc build succeeds; sparse succeeds if enabled.
- [ ] Isolated Hyper-V normal, failure, rescind and pressure tests pass.
- [ ] CCA and no-paravisor TDX evidence is recorded; otherwise PARTIAL.
- [ ] No patch is emailed without a separate operator review and approval.
