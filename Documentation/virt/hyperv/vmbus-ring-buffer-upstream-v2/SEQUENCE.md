# SEQUENCE — bounded test sequence for one CoCo attempt

**Role in the bundle:** what to run, in what order, and when to stop. The
narrative, the expected verdicts and the cleanup rules live in
`COCO-TESTER-BUNDLE.md`; this file is the steps themselves.

Run everything from the bundle root. Nothing here needs network access and
nothing here uses one.

**The sequence is bounded.** Each step has a stated stop condition. Do not
extend it into a soak, do not add steps, do not re-run a step that failed to
make the log look cleaner. A failed attempt is evidence and is preserved.

---

## Step 0 — record identity

```sh
./coco-collect.sh init COCO-1 attempt=1
```

Use the row and attempt number you are actually running (`COCO-1` …
`COCO-5`). Every attempt is kept; a later good attempt never overwrites an
earlier bad one.

If you do not yet know which row this is, stop after step 2 — the preflight
decides that, and guessing is how a result starts lying.

## Step 1 — verify the bytes in the guest

```sh
(cd series && sha256sum -c SHA256SUMS)
```

Every line must say `OK`. Capture the output; it becomes
`series-byte-pin.log` and the `series_sha256sums_ok` field.

This check runs **in the guest**, on the bytes that will be built. A hash
computed on the packaging machine is not this.

## Step 2 — build, boot, prove the mode

Follow `BUILD.md`. After boot:

```sh
uname -a
./coco-capability-preflight.sh > preflight-booted.txt
```

`preflight-booted.txt` must show the same isolation mode as the pre-boot
probe. A mode that changed between probe and boot invalidates the attempt.

Then read the decision table in `COCO-TESTER-BUNDLE.md` §4 and decide the
row. The short version:

| Proven mode | Row this attempt can address |
| --- | --- |
| SEV-SNP activation in `dmesg` | COCO-1, COCO-4, COCO-5 |
| TDX activation **and** `paravisor=absent` | COCO-2, COCO-4, COCO-5 |
| TDX activation, paravisor present or unknown | a different row — `tdx_paravisor`, not COCO-2 |
| Arm CCA activation | COCO-3, COCO-4, COCO-5 |
| Ordinary Hyper-V, or isolation `unknown` | **no CoCo row.** Stop, report `ENVIRONMENT_UNAVAILABLE` |

Non-negotiable: a CPU flag is not proof of absence; a SKU name is not
evidence; `paravisor=unknown` is not `paravisor=absent`; an unknown mode is
unqualified and never "probably fine".

## Step 3 — static invariants

```sh
./coco-static-invariants.py --tree /path/to/kernel-src
```

Offline; no guest needed. Proves no `set_memory_decrypted()` call is
reachable with a `vmap()` address.

**Necessary, not sufficient.** Passing this closes nothing on its own. It is
the check that answers the design objection; it cannot confirm the
memory-encryption transition that the objection is actually about.

## Step 4 — normal allocation and teardown

```sh
./drill/vmbus-lifecycle-drill.sh 100 /var/tmp/coco-lifecycle.log
```

One hundred rebind cycles.

**Stop when:** the script exits on its own, or the guest dies, or 30 minutes
elapse. Capture the whole log.

What to look for, and only these:

- The allocator took the **chunked** path, not the single `vzalloc()` path.
  This bundle does not yet expose chunk/order-descent counters at runtime.
  Without separate measurement of that path, these checks stay `not_run`. If
  the log shows only `vzalloc()`, the confidential path did not run and the
  row is `PARTIAL` at best.
- `PHASE1-BEFORE` and `PHASE1-AFTER` map accounting returns to the exact
  baseline across the cycles. Before and after describe the same counter
  name; report both, not a delta.
- Teardown re-encrypts cleanly: no `permanent_leak`, no `encryption_unknown`
  except where a later step deliberately injected a failure.
- Zero `#GP`, `#VC`, `BUG:`, `Oops:`, `panic:` across the whole run.

## Step 5 — order descent under fragmentation

```sh
./drill/vmbus-fragmentation-drill.sh 512 /var/tmp/coco-fragment.log
```

**Stop when:** the script exits on its own, or the buddy allocator is
exhausted to the point the script reports, or 30 minutes elapse.

What to look for:

- A successful descent to **order zero** with instrumentation proving it
  happened. Enabling an injection option is not proof the fallback ran.
- Channel open survived the fragmentation.
- The helper measurement at the moment of exhaustion defines exhaustion for
  that observation. A later reread does not redefine it.
- Zero `#GP`, `#VC`, `BUG:`, `Oops:`, `panic:`.

**Safety contract, unchanged and non-negotiable:** no swap activation, no
memory pressure outside the drill, no host lifecycle state change. This
drill is the only pressure and it lives inside the disposable guest.

## Step 6 — retained ownership on an unknown transition (COCO-4)

Needs a page-state transition that **fails or cannot be proven**. Do not
manufacture one by patching the production bytes. Use one of:

- a guest that genuinely cannot complete the transition (then say so), or
- a separately reviewed diagnostic delta (none is supplied in this bundle), recorded as
  `candidate.diagnostic_delta` with `experimental: true`.

What to look for — this is the whole row:

- `gpadl.leak` and/or `owner->encryption_unknown` is set.
- The buffer is **retained** — not freed, not re-encrypted.
- The map is still present after teardown. Observed at runtime. Source
  agreement is not evidence.

A run where the transition never failed proves nothing about this row.
Report it `not_run`, not `fail`.

## Step 7 — injected failure is survivable (COCO-5)

No injection hook for confidential page-state transition failures is
supplied in this bundle. Without a separately reviewed delta, record this
step `not_run`. When that delta exists, use its documented injection hook. The failure must fail **the
transition**, not the allocation — those are different claims.

What to look for:

- Guest stays alive. No `#GP`, `#VC`, `BUG:`, `Oops:`, `panic:`.
- Buffer retained. `permanent_leak` may be set; an unbounded leak under a
  counted owner may not.
- Owner accounting balances after quiescence: allocate / release / retain /
  reclaim reconcile.

## Step 8 — collect

```sh
mkdir -p artifacts
cp /var/tmp/coco-lifecycle.log artifacts/
cp /var/tmp/coco-fragment.log artifacts/
./coco-collect.sh finish \
  --row COCO-1 \
  --status PARTIAL \
  --justification "Available subchecks measured; transition injection not supplied" \
  --artifact dmesg:dmesg.txt \
  --artifact preflight_report:preflight-booted.txt \
  --artifact drill_log:artifacts/coco-lifecycle.log \
  --artifact drill_log:artifacts/coco-fragment.log \
  --out result.json
```

Substitute your actual row and status. `coco-collect.sh` walks the counters
it can find, hashes every artifact and writes `result.json` against
`coco-result.schema.json`. If it cannot classify something it leaves the
field for you to fill; it never invents a value.

It **refuses** to emit a result that would upgrade an unproven isolation
mode, a lost guest, an unknown paravisor, or a missing
`bug_oops_panic_total` counter to `PASS`. It also refuses any artifact that
still carries a kernel virtual address, a secret-shaped token, or an
absolute host path. Those refusals are working as intended.

Read `result.json` before sending it back. Then follow the return procedure
in `COCO-TESTER-BUNDLE.md` §9: validate, tar the named artifacts keeping
their bundle-relative paths, and return `result.json` and the tarball
together — the SHA-256 values in the result are the binding.

---

## Status vocabulary (read literally)

| Status | Means |
| --- | --- |
| `PASS` | platform proven, run completed on its own, every named subcheck `pass`, `bug_oops_panic_total` = 0, bytes verified in guest |
| `PARTIAL` | some named subchecks ran and produced evidence; others did not |
| `FAIL` | a named subcheck produced **negative** evidence (buffer freed while page state unproven; a `#VC`; …) |
| `NO_RESULT` | the run did not produce a readable outcome (guest lost, console dropped, timeout, provisioner failure) |
| `ENVIRONMENT_UNAVAILABLE` | the platform was never available (preflight could not prove the isolation mode) |

`inconclusive` is not `pass`. `not_run` is not `fail`. A lost guest or a
timeout is an infrastructure fact and produces `NO_RESULT` or `PARTIAL` —
never `PASS`, and never a bare `FAIL` that asserts a code defect. Do not
attribute the outcome to runner starvation, OOM or a deadlock unless a log
line names that cause; an inference goes in `status_justification` labelled
as a hypothesis.

A subcheck is never inherited from another row or another attempt. A
safe-looking log is not page-state or lifetime transition evidence — the
counters have to name the transition. `tdx_paravisor` does not close COCO-2.
Passing SNP does not close TDX or CCA.

---

## If something goes wrong

- **Guest panics:** capture the console up to the panic, then discard the
  guest. Do not reboot it into the same state and re-run. A panic is a
  finding, not a retry condition. Record it as evidence.
- **Timeout or guest lost:** record `infrastructure_status` faithfully
  (`timeout` / `guest_lost` / `provisioner_failed`) and return what you have.
  Partial logs beat no result. Do not reclassify a timeout as a test failure.
- **Buffer freed while its page state was unproven:** that is a `FAIL` on
  the row and a blocker for the series. Photograph the evidence before
  cleaning up.
- **Cleanup, always:** delete the disposable guest and everything the run
  created. Leave no kernel installed on any machine that is not that guest.

---

**Nothing in this file authorises sending anything.** Preparing a run, and
even completing one, is not authorization to post the patch series.
"Ready to send" is not "send it".
