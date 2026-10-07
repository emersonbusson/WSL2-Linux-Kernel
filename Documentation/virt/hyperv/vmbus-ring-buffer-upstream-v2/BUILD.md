> Current snapshot: fourteen-patch build and runtime requalification is in
> progress.
> Results below for the thirteen-patch series are historical and do not qualify
> patch 0014. Ordinary WSL results qualify only the distinct WSL backport.
> Sending remains NO_GO until the exact current bytes pass the final review.

# BUILD — image for one CoCo attempt

**Role in the bundle:** how to turn the fourteen patches into a kernel a
disposable guest can boot. Everything here is already in the tree; this file
names the recipe rather than inventing one.

Read `MANIFEST.txt` first. It pins the base commit, the tip, the cover hash
and the build-recipe identity. A build started from different bytes cannot
be reported against these bytes.

---

## 1. Two supported shapes

| Shape | When to use | Output |
| --- | --- | --- |
| **A. Self-booting drill image** | disposable Gen2 Hyper-V guest, no distro, no disk root | one EFI application: `BOOTX64.EFI` |
| **B. Distro-style build** | the guest already has a root filesystem and a bootloader | `bzImage` installed the way that guest installs kernels |

Shape A is the one the hosted runs use and the one this bundle is sized for.
Shape B is allowed when the tester's environment already boots kernels; the
**bytes** are the same, only the packaging differs.

Both shapes build the **production bytes only**. No diagnostic delta is
applied here. This bundle supplies no runtime transition-failure injection
delta. COCO-4/5 remain `not_run` unless a separately reviewed diagnostic
delta is supplied and recorded as `candidate.diagnostic_delta` with
`experimental: true` in the result. Never fold a diagnostic into the series
and then report it as the candidate.

## 2. Shape A — the drill image (default)

The recipe is `drill/build-drill-kernel.sh`. It is self-contained: the PID 1
init, the static mmap/mlock helper, and the three guest drills all live
beside it under `drill/`. No other repository is needed.

### 2.1 Prerequisites on the build machine

- `gcc`, `make`, `cpio`, `gzip`
- `busybox` (static; the script defaults to `/bin/busybox`, override with
  `BUSYBOX=/path/to/busybox`)
- A mainline kernel tree already at the candidate (section 3)
- Python 3 with `jsonschema` on the report collection machine (offline schema validation)

A dynamic helper would not run in an initramfs. The script builds the helper
with `-static` and then proves it with `ldd`; if that check finds a dynamic
link the build stops.

### 2.2 Build

```sh
# from the bundle root, after section 3 has produced the candidate tree
./drill/build-drill-kernel.sh /path/to/kernel-src /path/to/out
```

`kernel-src` is the mainline tree with `0001`–`0014` applied. `out` receives
the image and the evidence the build itself produced:

| File | Why it is kept |
| --- | --- |
| `bin/vmbus_drill_helper` | the static helper that was actually linked |
| `helper-file.txt` | `file(1)` output; the static proof |
| `initramfs.cpio.gz` | the guest userspace that was embedded |
| `config-drill-requested` | every symbol the recipe asked for |
| `config-drill-resolved` | the `.config` after `olddefconfig` |
| `bzImage` / `BOOTX64.EFI` | the image |

The script refuses to continue if any requested symbol was dropped by
`olddefconfig`. A kernel that builds and does not boot is the failure mode
that check exists to prevent. Do not bypass it.

### 2.3 What the recipe configures, and what it deliberately does not

The base is `tinyconfig`, not `defconfig`, so the guest is small and every
symbol is listed explicitly. It enables the Hyper-V guest bus, the VMBus
sub-drivers the drills rebind, UIO, the EFI stub, an 8250 console at
`ttyS0,115200`, proc/sysfs/debugfs, and the introspection the drills read.

It **disables**, on purpose:

- `MODULES` — the initramfs needs no `modules.dep`
- `RANDOMIZE_BASE` (KASLR) — a logged failure must be reproducible
- `KUNIT` / `KUNIT_TEST` — this image exercises **runtime** behaviour; the
  KUnit measurements are a separate, local claim on a different config
- `DEBUG_INFO*`, `DYNAMIC_DEBUG`, `KPROBES`, `FUNCTION_TRACER`, `KGDB` — not needed
  and they change what a clean dmesg looks like

Event tracing is enabled for opaque owner accounting from boot. Function
tracing remains disabled. Missing metadata or trace loss makes accounting
PARTIAL.

The command line is baked in with `CMDLINE_OVERRIDE`:

```
console=ttyS0,115200 earlyprintk=serial,ttyS0,115200 panic=1 oops=panic nmi_watchdog=0 trace_event=hyperv:vmbus_buffer_owner trace_buf_size=512K
```

`panic=1 oops=panic` is deliberate: on this disposable guest an Oops is a
finding, and the guest must stop rather than limp on and produce a second,
confused observation. It is also why the guest must be disposable.

### 2.4 Booting the image

Drop `BOOTX64.EFI` at `\EFI\BOOT\BOOTX64.EFI` on a FAT32 ESP of a **Gen2**
Hyper-V VM. No GRUB, no distro, no separate initrd, no disk root. The
initramfs is embedded.

Attach a serial console before boot:

```
console=ttyS0,115200
```

Capture it to a file from the first byte. The raw console is a progress and
diagnostic stream; it is not the authority for a verdict because printk can
interleave with guest output. The guest also sends a replicated, indexed,
SHA-256-bound report containing both drill logs and the decision fields. The
host reconstructs that report as `drill-evidence.verified.txt`; a missing or
invalid report, or a missing guest-completion marker, is `NO_RESULT` and must
not pass either the candidate or baseline policy.

## 3. Getting the candidate bytes

This is the step that decides whether anything measured later means anything.

```sh
# 1. start from the pinned mainline base
git -C /path/to/kernel-src checkout 93f51579e7df248780214094418f205253383cc5

# 2. verify the patches are the ones MANIFEST.txt names
(cd series && sha256sum -c SHA256SUMS)

# 3. apply them
TASK_BUNDLE_ROOT=$(pwd)
git -C /path/to/kernel-src am \
  "$TASK_BUNDLE_ROOT"/series/000[1-9]-*.patch \
  "$TASK_BUNDLE_ROOT"/series/001[0-4]-*.patch
```

Every line of `sha256sum -c` must say `OK`. Run it **inside the guest too**
before building there — a hash computed on the packaging machine is not the
hash of the bytes that were built (see `SEQUENCE.md` step 1).

`0000-cover-letter.patch` is the cover. It is **not** applied and it is
**outside** `SHA256SUMS`, by design. Do not `git am` it.

If `git am` fails, stop and report. Do not hand-edit a patch to make it
apply. A series that does not apply cleanly to its own pinned base is a
finding about the candidate, and the attempt is not a test of anything.

## 4. Shape B — distro-style

Only when the guest already boots kernels through its own loader.

```sh
# after section 3, in the candidate tree
make olddefconfig
# enable at minimum:
#   CONFIG_HYPERV=y CONFIG_HYPERV_VMBUS=y CONFIG_HYPERV_NET=y
#   CONFIG_UIO=y CONFIG_UIO_HV_GENERIC=y
#   CONFIG_SERIAL_8250_CONSOLE=y CONFIG_PRINTK_TIME=y
make -j"$(nproc)" bzImage
# then install that bzImage the way this guest installs kernels
```

Record in the result which shape was used and, for shape B, the exact
`.config` that was built. A shape-B run is comparable to a shape-A run on
the counters the drills report, not on anything that depends on the
initramfs layout.

## 5. What is verified before a result may be claimed

Not one of these is optional.

- `sha256sum -c SHA256SUMS` in the guest reports `OK` for all fourteen.
- The tree that was built is the tree those hashes name.
- `uname -a` after boot matches the image you built.
- `coco-capability-preflight.sh` after boot shows the **same** isolation mode
  as before boot. A mode that changed between probe and boot invalidates the
  attempt.
- The serial pipe is attached before boot and its capture begins with the
  first byte.
- The indexed guest report reconstructs fully and its SHA-256 verifies;
  `drill-evidence.verified.txt` is retained with the job artifacts.
- The host reader observes the guest-completion marker before shutdown.

If any of these cannot be established, the attempt is `NO_RESULT` or
`ENVIRONMENT_UNAVAILABLE` as `SEQUENCE.md` and `coco-result.schema.json`
specify. It is never a `PASS` on the strength of a build that "looked fine".

## 6. Safety

- Build and boot only on a **disposable** guest. The lifecycle step rebinds
  VMBus sub-drivers. Nothing with state on it.
- Leave no kernel installed on any machine that is not that guest.
- No swap activation, no memory pressure outside the drills, no host
  lifecycle change. The fragmentation drill is the only pressure and it
  lives inside the guest.
- If you are unsure whether something is safe: stop and ask. There is no
  step here that is worth a damaged machine.

## 7. Rollback trigger

If the built image produces a `#GP`, `#VC`, guest panic, or a buffer freed
while its page state was unproven, the series is **not** ready and the send
gate stays closed. Record the failure as evidence. Do not retry around it,
and do not rebuild with a different config hoping it goes away.

---

**Nothing in this file authorises sending anything.** The patch series
workspace still requires explicit operator approval before any mail leaves,
and a successful build is not that approval.
