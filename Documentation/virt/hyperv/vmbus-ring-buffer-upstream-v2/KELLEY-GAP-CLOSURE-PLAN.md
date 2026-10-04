# VMBus v2: gap closure plan and execution prompts

Prepared: 2026-10-04. Status: **handoff plan; implementation and qualification have not been performed by writing this document**.

This document prepares the next working session to address the kernel audit. It belongs beside the kernel qualification tools, outside `series/`. It is not a cover letter, a patch, a test result, an approval to send mail, or a substitute for measured evidence.

## 1. Objective and scope

Correct the VMBus v2 contribution and its evidence so Michael Kelley can review a reproducible candidate with accurate claims. Close locally solvable gaps, prepare meaningful regression tests and CI, and distinguish hardware qualification from submission readiness.

The audit contains fourteen kernel findings, K01–K14, in section 8 of `/home/emdev/codespace/site-ramshared/codexaudite.md`. Sections 1–7 concern a separate website session and are outside this plan. Treat findings as questions to revalidate against current source, not as proof that every suspected defect exists.

There are three distinct deliverables:

1. Corrected code, tests, validators, and documentation that can be prepared locally.
2. A reproducible ordinary Hyper-V and CoCo qualification package, including capability checks and CI orchestration.
3. Evidence from actual executions, with hardware-dependent rows left open if no compatible environment is available.

Implementing a workflow does not qualify CoCo. An operator waiver does not change a measured PARTIAL into PASS. Review can be requested with disclosed gaps; all-platform qualification is a project criterion, not a requirement that Kelley explicitly imposed on the contributor personally.

## 2. Starting evidence: historical, not a frozen current manifest

| Surface | Audit starting point |
| --- | --- |
| Kernel repository | `/home/emdev/codespace/WSL2-Linux-Kernel-contribution` |
| Working branch at handoff | `vmbus-ring-buffer-upstream-v2` |
| HEAD observed | `71863d8d75788de3f549b330ca822f8f1b8f02b4` |
| Tested patch commit | `4758db87844728e2a7e746c5bc41ac09be200153` |
| Mainline base | `93f51579e7df248780214094418f205253383cc5`, Linux 7.3-rc4 |
| Audited shape | Thirteen patches, `0001`–`0013`, plus `0000` cover |
| Build/KUnit/static run | [37179681746](https://github.com/emersonbusson/WSL2-Linux-Kernel/actions/runs/37179681746), success |
| Runtime run | [37179681743](https://github.com/emersonbusson/WSL2-Linux-Kernel/actions/runs/37179681743), failure, two attempts |
| Completed ordinary guest | Four lifecycle subgates PASS, restore PARTIAL, aggregate PARTIAL; fragmentation INCONCLUSIVE |
| Other ordinary guest | Lifecycle NO_RESULT on both attempts; fragmentation INCONCLUSIVE then PASS |
| CoCo | Static necessary conditions checked; no measured platform qualification |
| Historical audited cover SHA | `1d46c8d1408e3b4c5eb8972b5bff203e0ab87d36ccc4ce2e75a14b23a056b709` |
| Historical dry-run | `/mnt/c/wsl/host-gate/DRY-RUN-build11-cover-1d46c8d1408e.txt` |

**Important:** the cover is already modified in the working tree after the audit. Changes observed while preparing this plan address the timeout attribution, integral lifecycle wording, and explanation of remaining GPADL duplication. Do not overwrite that work or declare those findings still unchanged without inspection. The previous dry-run is not a capture of the modified cover. Recompute all identities in phase 0. `Module.symvers.bak` is a pre-existing untracked file; it is not task-owned cleanup.

Primary reviewer context: [Michael Kelley's review](https://www.mail-archive.com/linux-kernel@vger.kernel.org/msg2658605.html). His objection concerns vmalloc decryption on CCA/TDX without a paravisor and proposes allocator/refactoring changes. Consult that message when mapping the response; do not invent a demand for three personal lab installations.

## 3. Authorization, resources, and preservation

- Read `/home/emdev/codespace/AGENTS.md` and all applicable descendant instructions before working. Before editing RamShared, read its `AGENTS.md`, `CLAUDE.md`, relevant rules, README, current memory, and upstream records. Respect its English documentation and public-hygiene rules.
- This handoff specifies work; external actions still require the operator's actual authorization. Proceed with authorized local edits and checks without asking for confirmation at every phase. Preserve any broader authorization already given in the receiving session.
- Execute builds and validation according to the current workspace resource policy and operator authorization.
- Tests, lint, typecheck, static checks, and E2E run directly and do not acquire, wait for, or inspect the heavy-build lock. If a test requires a separately built kernel, produce that image as the guarded build step; do not relabel a kernel compilation as a check to evade admission.
- Keep the daily WSL host unchanged. No live NIC rebind, pressure, swap changes, fault injection, kernel activation, reboot, or WSL restart there. Runtime belongs in disposable authorized lab guests.
- Preserve unrelated working changes, including concurrent cover edits. Use isolated trees/worktrees where appropriate. Inspect the real source generated by applying the mails to the pinned mainline base; the fork checkout and WSL backport are different surfaces.
- Without existing explicit authorization, do not push, dispatch remote workflows, provision/charge cloud resources, expose a self-hosted runner, contact maintainers, send the series, commit, merge, or deploy. Prepare reviewable artifacts first. A local SMTP dry-run must explicitly neutralize credentials and be unable to send.
- Never persist credentials, tokens, SMTP app-passwords, raw sensitive attestation payloads, or kernel addresses. Use opaque owner/lifetime identifiers in diagnostics. Rotation of an SMTP secret and rollover of a full validation log are operational tasks, not CoCo correctness gates.
- Keep this plan out of the mail series. Public cover/patch prose must explain technical behavior, not internal session instructions. Do not introduce prohibited attribution trailers; preserve legitimate kernel DCO trailers.

## 4. Evidence and status contract

Create one current candidate manifest and a gap ledger in a location permitted by repository rules. Prefer the existing feature evidence directory in RamShared after reading its rules; keep kernel-local reproducibility instructions here. Avoid duplicating independent current manifests.

Each gap row records: ID, revalidated finding, status, responsible party, affected surface, dependencies, test/oracle, exact candidate identity, result, evidence path/run/attempt/job, remaining limitation, next action, and whether that action needs an external capability or authorization.

Suggested statuses: `OPEN`, `IN_PROGRESS`, `PASS`, `PARTIAL`, `NO_RESULT`, `ENVIRONMENT_UNAVAILABLE`, and `NOT_APPLICABLE_WITH_REASON`. These are ledger states, not permission to alter established runtime exit semantics. Do not mix implementation completion, test completion, and review approval in one boolean.

The manifest binds:

- Mainline base, source commit and working diff identity, ordered patch list and SHA-256 of every patch and cover.
- Kernel config, toolchain/Sparse versions, image and relevant modules/initramfs hashes, test harness version.
- Architecture, platform, Hyper-V/CoCo mode and per-channel confidentiality path actually exercised.
- Run, attempt, job, timestamps and artifacts; distinguish rerun jobs from reused jobs.
- Verdict scope, exit codes and explicit exclusions. Diagnostic instrumentation must be identified and justified when different from the proposed production candidate; requalify final production bytes as needed.

Historical runs remain historical. A cover-only change can retain code test evidence if code/config/harness identities still match, while requiring a new cover hash and mail dry-run. Code or harness changes require new evidence for affected gates. Never infer body identity from the capture filename.

## 5. Phase 0 — reconcile current state before changing it

**Prompt for the receiving session:**

> Read the kernel audit and this plan, inspect current instructions and working changes, and reconstruct the exact mainline candidate from the mails in isolation. Revalidate all K01–K14 findings. Inventory existing tests, tools and evidence before implementing anything. Record which findings are already addressed and which remain open. Continue with independent authorized work; ask only for a missing capability or an action that truly needs authorization.

Tasks:

1. Capture `git status`, branch, HEAD, current cover diff, SHA256SUMS verification, mail ordering and actual base. Do not hardcode thirteen stages if a deliberate recut changes the series length.
2. Apply each patch sequentially with `git apply --check` before application. Confirm the candidate's struct fields, exported prototypes, release paths and configuration against the applied mainline tree.
3. Compare current cover claims to that source. In particular, verify claims about which struct owns `size`, differences between buffer/GPADL leak flags, and pin lifetime: the temporary bridge pin may be released at mapping establishment while the VMA holds its own page references.
4. Inventory current workflows and read existing public logs when credentials permit. Preserve conclusions and deduplicate repeated console blocks/reused jobs.
5. Reconcile current-status paragraphs in IMPL, COCO-GAP, upstream status, gap register and cover. Preserve explicitly historical sections. Do not conflate fork Build #11 with the mainline candidate.

**Exit:** a refreshed ledger and manifest skeleton, with no overwritten concurrent work and no “current” claims based solely on the old audit snapshot.

## 6. Phase 1 — correct claims and make gates describe their inputs

**Prompt:**

> Close the documentation and validator coverage gaps that do not require hardware. Describe timeout as an observation with an unproven cause, preserve aggregate PARTIAL when restore is partial, synchronize current candidate pins, and make CI check every byte of the proposed mails. Verify documentation statements against the applied mainline source.

Tasks and oracles:

- K01/K02/K10: use “timeout with NO_RESULT; runner starvation suspected, not established” unless new causal evidence exists. State that no current guest reached integral lifecycle PASS. Update old current pins and mark superseded results as history.
- K11: check complete mail patches, including newly added test files. The present `git apply` followed by unstaged cumulative `git diff` omits untracked additions. Use full-mail checkpatch or a controlled index/intent-to-add approach covering all staged additions; retain per-stage checks and full final mail checks.
- Allow only justified `FILE_PATH_CHANGES` warnings where applicable; fail on other warnings/errors according to the chosen policy. Do not hide arbitrary diagnostics or claim zero warnings when warnings are accepted.
- K12: prepare a matched baseline/candidate W=1/Sparse comparison. Normalize incidental path/line shifts without erasing warning type or context; report every introduced diagnostic and its disposition. Preserve actual baseline logs.
- Correct stale workflow comments that claim real host rescind testing when the harness only rebinds drivers. Capability probes, synthetic injections and real host actions must have different labels.
- Keep the CI job's infrastructure success distinct from gate PASS. Add an explicit qualification summary that reports PARTIAL/NO_RESULT as such; if a strict qualification job exists, it must require every selected required gate. Never change an inconclusive verdict to PASS to make the job green.

**Exit:** all current documentation agrees on identities and verdicts; complete-mail style coverage is demonstrated; warning claims have a linked differential or remain narrowly worded.

## 7. Phase 2 — review ownership and close production regression gaps

**Prompt:**

> Review and minimally correct the applied mainline production code, then add tests that exercise its actual behavior. Prioritize uncertain host ownership, page-state transitions, mmap integration and the three netvsc-related fixes. A passing helper or source pattern is not proof that the complete production path is safe.

### 7.1 Host ownership and struct invariants: K06/K13

- Map allocation, first possibly delivered GPADL post, response, teardown acknowledgement, host rescind, local unload, release, mapping pins, reclaim and shutdown as explicit transitions.
- Identify field authorities and synchronization for `addr`/`gpadl.buffer`, sizes, leak flags and retained owners. Explain exported compatibility needs rather than assuming embedded structs eliminate duplication.
- Obtain an applicable Hyper-V protocol guarantee or technical reviewer confirmation before treating host rescind as terminal revocation of all relevant GPADLs. Record its precise scope and ordering.
- Exercise partial posts, pending creates, late/duplicate responses, teardown allocation failure, local unload and lifetime/relid reuse. Real host ordering remains a separate qualification row even if a model passes.
- If no guarantee is available, retain uncertain backing and account for it. Do not clear ownership merely because a generic rescind flag is set. Do not grow permanent retention silently without an observable ledger and stated limitation.

### 7.2 Named regressions: K07

| Patch/functionality | Required behavior tests |
| --- | --- |
| 0011 requestor array | Forced vmalloc backing; ID allocation/consumption/reuse; bitmap allocation failure cleanup; paired kvfree; invalid/replayed IDs |
| 0012 RNDIS request | Forced vmalloc backing; zeroing and bounded request/response tail copy; successful completion; timeout/error cleanup; appropriate calling context |
| 0013 empty completion | NULL address, valid skb, valid SWITCH_DATA_PATH, both invalid sentinels and duplicate completion; exactly one request-ID consumption and queue decrement; correct queue, wake and drain behavior |

Choose seams that run the production path and assert its effects. Do not write tests that merely repeat implementation conditions. Verify assumptions such as NULL control requests always belonging to queue zero, all allocation users being sleepable, and objects never becoming DMA/direct-map inputs.

### 7.3 MM/UIO/kernfs integration: K08

- Test `/dev/uioN` and the sysfs ring separately against their actual contracts.
- Exercise prepare/action failure, partial page insertion, mapped/close/abandon, teardown/reclaim interleaving, munmap and last file close; fork/merge only when possible under actual VMA flags.
- Assert exactly one bridge-pin release, balanced folio references and no reclaim while pages remain mapped or host-owned. Demonstrate expected controlled invalidation when the sysfs node is removed.
- Verify UIO availability/policy on isolated guests. Do not remove isolation hardening/device filters to force a test. An unavailable surface is an explicit open or justified inapplicable row, not a pass.

**Exit:** relevant named tests pass, production changes are reviewed against failure paths, uncertainty remains conservatively represented, and hardware/protocol assumptions are still separately identified.

## 8. Phase 3 — owner accounting and baseline-controlled ordinary runtime

**Prompt:**

> Instrument enough to distinguish individual buffer lifetimes and locate stalled phases, then compare baseline and candidate in an authorized disposable ordinary Hyper-V guest. Resolve restoration and accounting before claiming complete lifecycle. Investigate timeout with a changed experiment rather than retrying until green.

Tasks:

- K09: use opaque lifetime/owner identifiers, device identity/role, allocation size and requested/actual orders, GPADL identity where appropriate, references and disposition counters. Do not log addresses. Reconcile allocate/release/retain/reclaim, owner identity and multiplicity after quiescence.
- K03: run baseline and candidate with the same config/toolchain, guest resources, device and harness. Hold fd/VMA during teardown, withdraw the sysfs node, release helpers, unmap, close descriptors, wait for reclaim and retry bind. Record channel state and exact errors at each boundary.
- Preserve valid intentional retention while a mapping is alive. Determine whether baseline and candidate both restore after consumers close; do not assume source similarity proves equivalent runtime behavior.
- K01: add timestamped phase markers and progress heartbeats independent of the potentially blocked reader; capture resource/memory mode and console-reader state. On timeout, retain stage and blocked-wait information if available. Missing BUG/Oops and identical images do not exclude silent hangs.
- K04: use bounded fragmentation with explicit memory margins, relevant node/zone/order supply and helper-time condition. The helper measurement, not an unrelated later reread, defines exhaustion for that observation. Exercise allocation success without turning global OOM into a fragmentation test.
- Separate ordinary `vzalloc` scope from shared chunk order descent. Require all five lifecycle subverdicts and relevant fragment verdicts for a full combined qualification.
- Predeclare attempts and stop conditions per hypothesis. Initially allow one diagnostic execution and one confirming execution where authorized; justify any extension from new information. Preserve every failed/inconclusive run. Do not blame the runner merely because the run is red.

**Exit:** restore/accounting/fragmentation either have measured candidate-specific PASS or remain individually open with a diagnosis and next test. A completed guest with PARTIAL is not integral lifecycle PASS.

## 9. Phase 4 — prepare CoCo CI without assuming access

**Prompt:**

> Design and implement, where authorized, a capability-gated CoCo qualification workflow. Reuse the existing build/artifact/guest-result mechanisms, but keep ordinary Hyper-V and real CoCo execution distinct. Discover available environments read-only; do not provision paid resources or attach a runner without authorization. Lack of access must not prevent completion of local tests, instrumentation, scripts, documentation and the tester package.

### 9.1 Choose an execution path after a capability preflight

| Path | Preparation possible now | External prerequisite |
| --- | --- | --- |
| Existing hosted Actions | Build candidate, run KUnit/static checks, ordinary runtime, prepare artifacts | Does not currently provide the required confidential guest |
| Authorized lab/self-hosted runner | Prepare launcher, labels, preflight and result collector | Owner supplies compatible hardware/hypervisor and approves runner connection |
| Actions orchestrating a remote CoCo guest | Prepare image transfer, launcher, bounded execution, artifact collection and cleanup | Authorized account/environment, quota, compatible image boot and selected CoCo mode |
| Maintainer/tester collaboration | Prepare a standalone tester bundle and unsent request | A volunteer with the required platform agrees to run it |

A self-hosted label or cloud SKU name is not proof of capability. A CoCo-capable CPU hosting a normal VM does not make that VM confidential. An ordinary nested Hyper-V guest inside another VM is not automatically confidential either.

Before expensive work, collect non-sensitive proof of architecture, hypervisor, active isolation technology, paravisor presence/absence, guest kernel/config and VMBus devices. Combine platform evidence/attestation where available with guest-reported isolation state. Missing CPU flags alone do not prove absence, since a paravisor can filter them. Unknown mode means unqualified.

For remote cloud, verify current official documentation and actual account capabilities for region/quota, custom kernel boot, boot trust/signing, required mode and serial/log access. `NonPersistedTPM`, disabling Secure Boot, selecting Generation 2, or choosing a size with “confidential” in its description must not be equated with “TDX without paravisor”. Do not invent a supported Arm CCA cloud option.

### 9.2 Workflow properties

- Build artifacts once per architecture/config as appropriate; include checksums and manifest. Do not build pressure helpers repeatedly in the scarce guest when they can be supplied as matched artifacts.
- Keep ordinary and CoCo results in distinct jobs/artifacts with explicit scope. Require runtime capability preflight before any CoCo verdict.
- Use isolated, approved resources and explicit resource ownership. Bound timeout, memory pressure and injection count. Support cancellation, collect evidence even on failure, and clean only resources created by the job.
- If implementing a self-hosted workflow, prevent untrusted fork/PR code from running on the privileged lab runner; require the repository's approved execution path. Prepare access via the existing credentials mechanism without embedding secrets in files/logs.
- Capability absence must produce `ENVIRONMENT_UNAVAILABLE`/PARTIAL in the evidence summary. A provisioner failure or lost guest must produce failed/NO_RESULT execution evidence. Neither can be reported as a hardware gate PASS.
- Make re-run identity explicit; preserve run/attempt/job and distinguish infrastructure status from qualification status.

**Exit:** launcher/preflight/result schema and test package are reviewable, locally checked within their scope, and ready for a named environment. If no environment exists, complete these artifacts and record the specific access requirement rather than claiming CoCo completion.

## 10. Phase 5 — execute real CoCo qualification when capability is available

**Prompt:**

> On an authorized compatible CoCo environment, boot the matched candidate and prove which buffer confidentiality path actually ran. Run normal allocation, controlled order descent, GPADL and teardown tests, then counted fault scenarios. Keep each platform/mode row separate and bind every result to the manifest. Do not equate a safe-looking log with verified page-state/lifetime transitions.

### Required matrix

| Row | Environment | Positive and negative evidence |
| --- | --- | --- |
| COCO-1 | AMD SEV-SNP on compatible Hyper-V | Shared chunk path, successful state transitions, GPADL/data access and correct release/retention; record paravisor mode |
| COCO-2 | Intel TDX on compatible Hyper-V, no paravisor | Same checks in the specific no-paravisor mode; a paravisor execution is a different row |
| COCO-3 | Arm CCA with compatible VMBus environment | Same checks with platform/page-size assumptions recorded; ordinary Arm boot is insufficient |
| COCO-4 | Each platform actually qualified | Partial/failed GPADL and uncertain state retain pages until ownership/state is proven; no premature re-encryption/free |
| COCO-5 | Each platform actually qualified | Counted page-state failure injection leaves guest alive, affected owner retained and resources accounted |

Verify the shared path decrypts each physically contiguous chunk through the applicable direct-map interface before its `vmap` alias is used. Verify mapping protection and that prepared GPADL does not decrypt the alias again. Exercise successful descent to order zero with instrumentation proving it happened, rather than merely enabling an injection option.

Confidential VMBus may offer encrypted private rings and different external-buffer requirements. Record `co_ring_buffer`/`co_external_memory` or their current equivalents. Test private and shared paths according to actual offers; never decrypt a private buffer solely to force shared-path coverage.

No concurrent user may access pages during a state transition. After host teardown/revocation is proven and the last guest reference is gone, observe appropriate re-encryption/reclaim. Retain unknown state. Inspect BUG/Oops/panic and unexpected faults, but also assert ownership balances, completion and data integrity.

Fault injection has levels: refusing a call before any transition, simulating partial progress in a model, returning an actual platform error, and exercising real partial platform behavior are different evidence. Label them accurately. Do not claim a mocked return code demonstrates a real hardware failure mechanism. Use only supported, bounded injection in a disposable guest; preserve untouched baseline control.

**Exit:** each available platform row has measured results and artifacts; unavailable modes remain named gaps. Passing SNP does not close TDX/CCA. If only a subset is available, prepare a partial technical review without expanding the support claim.

## 11. Phase 6 — provenance, patch organization and final candidate

**Prompt:**

> Recut a coherent, reviewable series only after resolving production changes. Establish the origin and regression tests of the netvsc fixes, decide subsystem/dependency routing, verify every stage, and bind final bytes to current evidence. Keep external transmission separate from preparation.

- K14: inspect history/blame for verified introductions of 0012/0013, include repro and before/after behavior, and add Fixes tags only when justified. Do not guess a commit or add stable routing automatically.
- Decide whether VMBus refactoring and netvsc fixes belong together or in dependent series. Document that runtime can rely on a fix even if its code is logically independent. Removing 0013 changes the tested candidate and invalidates affected runtime claims.
- Check exported symbol signatures and encryption contracts, callers, Kconfig combinations and each cumulative stage on x86_64/arm64. Keep WSL backport qualification separate; if porting is needed, preserve its source/image identity and relevant regressions.
- Fix introduced build/Sparse diagnostics. Run the named tests and full mail checkpatch; validate no omitted new files. Existing warnings require explicit disposition.
- Freeze the final candidate manifest, generate matching patch hashes, and update the cover/status docs from the ledger. Check every “PASS”, “current”, “all”, “both”, “no regression”, “no leak”, “qualified” and causal statement against its evidence.
- Prepare a strictly non-sending SMTP-neutralized dry-run and explicit ordered mail list. Confirm headers, recipients and threading; store cover and patch hashes alongside the capture. A dry-run does not prove SMTP delivery. Do not perform transport authentication tests that could send without authorization.
- Keep the new plan, manifest implementation internals and private operator artifacts out of `series/*.patch`. Update public descriptions around final behavior, not the history of agent sessions.

**Exit:** a reviewable candidate with consistent evidence and a clear list of outstanding rows. Actual send/push/remote rerun remains an explicitly authorized action, not an implication of “ready”.

## 12. Phase 7 — tester request when access is the remaining gap

**Prompt:**

> Prepare an unsent request for platform testing and a standalone reproduction bundle. Target the outstanding platform/mode rather than asking someone to build the entire unrelated project. Finish all locally solvable work first and state exactly what evidence is still missing. Do not contact anyone until the operator authorizes it.

The bundle includes mails/base, manifest, configuration, image-building instructions, scripts and prerequisites, capability checks, bounded test sequence, expected verdicts, failure/cleanup instructions and artifact schema. Mark any experimental diagnostic delta separately from production bytes. Confirm that instructions do not depend on local absolute workspace paths.

Draft request:

> I do not currently have access to Hyper-V CoCo on TDX without a paravisor or Arm CCA. This candidate uses direct-map chunk transitions before vmap and conservative retention on uncertain ownership/page state. I can provide the pinned patches, configuration and bounded reproduction package. Could someone test the named paths or advise on an accessible compatible environment? The currently available results cover ordinary Hyper-V and the listed static/unit tests; they do not qualify those CoCo modes.

Adapt this draft to the actual final source and measured results. A request prepared or sent is not a test result, a promise of volunteer availability, or a closed hardware row.

## 13. Gap-to-phase acceptance checklist

| ID | Required closure evidence | Phases |
| --- | --- | --- |
| K01 | Accurate hypothesis wording; independent progress/resource evidence and causal diagnosis if claimed | 0, 1, 3 |
| K02 | Aggregate reflects five subgates; integral PASS only after all required subgates PASS | 1, 3 |
| K03 | Matched baseline/candidate restore after consumer release, with channel and reclaim evidence | 2, 3 |
| K04 | Reproducible fragment condition at measurement time, allocation success and scoped completed gates | 3, 5 |
| K05 | Qualification requires measured platform/mode rows; a prepared CI/tester package leaves unavailable hardware rows open | 4, 5, 7 |
| K06 | Applicable revocation contract plus ordering tests; conservative retention while uncertain | 2, 5 |
| K07 | Named production-behavior regressions for requestor, RNDIS and completion accounting | 2, 6 |
| K08 | Real MM/UIO/kernfs integration failure/teardown cases with exactly-once pin release | 2, 3, 5 |
| K09 | Instance/lifetime balances and multiplicity, not only a size-class band | 3 |
| K10 | Current status/cover/manifest agree; superseded pins visibly historical | 0, 1, 6 |
| K11 | Full added-file/mail style coverage with justified explicit warning policy | 1, 6 |
| K12 | Matched normalized baseline/candidate diagnostic comparison | 1, 3, 6 |
| K13 | Field authority and synchronization demonstrated; compatibility rationale or consolidation reviewed | 0, 2, 6 |
| K14 | Verified fix provenance, before/after tests and explicit subsystem/dependency routing | 2, 6 |

## 14. Completion report required from the receiving session

Report in Portuguese to the operator; keep structural repository documentation in its required language.

1. Changes made and the concrete behavior they fix; include files and final candidate identity.
2. K01–K14 ledger: what is closed, partially addressed, unchanged or unavailable, with evidence and next action.
3. Actual checks/tests, results and scope; distinguish prepared scripts from executed tests and model injection from hardware execution.
4. Ordinary Hyper-V and CoCo matrices separately, including partial/failed/no-result attempts and unavailable modes.
5. Remaining external dependencies, expected artifacts and any specific authorization needed. Do not pause useful independent work just because one platform is unavailable.
6. Explicit transmission/deployment state. No approval guarantee, no “everything is done” while required rows are open, and no implied permission to send.

Preserve progress in the repository's existing session/evidence mechanism so a continuation does not redo validated work. Do not erase the historical audit; annotate later closures with evidence.

## 15. Master execution prompt

Copy this prompt into the receiving session after the operator has authorized its implementation scope:

```text
Work on the VMBus v2 contribution in
/home/emdev/codespace/WSL2-Linux-Kernel-contribution.

Read Documentation/virt/hyperv/vmbus-ring-buffer-upstream-v2/
KELLEY-GAP-CLOSURE-PLAN.md completely, and section 8 of
/home/emdev/codespace/site-ramshared/codexaudite.md.
Follow applicable repository instructions and the operator's resource contract.

Execute the plan through locally achievable closure, not merely another plan.
Start by reconciling current source, cover edits and evidence. Do not overwrite
concurrent changes or treat historical pins as current. Reconstruct the mainline
candidate from the ordered mails; distinguish it from the WSL fork/backport.

Maintain a current manifest and K01-K14 ledger. Correct claims/docs, fix meaningful
code/validator defects, add production-behavior regressions, establish baseline
comparisons and prepare bounded ordinary-runtime and CoCo qualification tools.
Use phase prompts and closure criteria in the document, adapting to verified
source and evidence. Preserve honest PARTIAL/NO_RESULT/UNAVAILABLE states.

CoCo can run in CI through an authorized compatible lab runner or remote
confidential guest. The existing hosted ordinary Hyper-V drill does not qualify
CoCo. Implement capability preflight and a reviewable tester package even if no
hardware is available. Do not stop local progress at that limitation. Do not fake
isolation, page transitions, restore, host revocation or hardware verdicts.

Proceed with already-authorized work without repeated confirmations. Keep the
daily WSL host untouched. Expensive builds require the real global permit;
checks/tests do not consult that lock. External sends, pushes, workflow dispatch,
cloud spending/provisioning, runner attachment and kernel activation need actual
authorization unless already explicitly granted in this session. Prepare the
concrete result before requesting any such final action.

Finish with changed files, exact candidate identities, K01-K14 dispositions,
executed validation, separate ordinary/CoCo matrices, unresolved access/protocol
dependencies and precise next steps. Do not guarantee reviewer acceptance or
declare complete qualification while required evidence remains open.
```

## 16. Technical references

- [Hyper-V CoCo requirements, modes and memory transitions](https://docs.kernel.org/virt/hyperv/coco.html).
- [GitHub self-hosted runner setup](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners).
- [Azure confidential VM image requirements and limitations](https://learn.microsoft.com/en-us/azure/confidential-computing/confidential-vm-faq).
- [Azure custom Secure Boot keys](https://learn.microsoft.com/en-us/azure/virtual-machines/trusted-launch-secure-boot-custom-uefi).

Recheck current documentation and environment capabilities before implementing a platform-specific launcher. These references are discovery inputs, not proof that a particular account/SKU supports the required no-paravisor mode or candidate image.
