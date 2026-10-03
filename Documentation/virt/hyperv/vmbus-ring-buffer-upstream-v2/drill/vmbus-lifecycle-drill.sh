#!/usr/bin/env bash
# Guest-side VMBus GPADL/UIO lifecycle drill for the ring-buffer upstream v2 series.
#
# Runs INSIDE a disposable ordinary x86_64 Hyper-V guest that booted the exact
# thirteen-patch candidate. It is never run on the daily WSL2 host: it rebinds the
# production synthetic NIC and unloads/reloads VMBus sub-drivers.
#
# Covers the named SPEC gates that hosted KUnit cannot:
#   - vmbus_channel_lifecycle_buffer_balance   (open/close + vmallocinfo)
#   - uio_hv_ring_noncontiguous_mmap           (UIO mmap incl. hold-in-mmap)
#   - GPADL create/teardown/rescind/close balance
#
# Host-safety contract (vmbus-ring-buffer-upstream-v2/SPEC.md): no swap
# activation, no memory pressure, and no RamShared lifecycle state change. This
# script performs none of those. Fragmentation pressure lives in a separate
# drill and only ever inside the same disposable guest.
#
# usage: vmbus-lifecycle-drill.sh [cycles] [logfile]
#   cycles  default 100 (SPEC vmbus_channel_lifecycle_buffer_balance)
#
# Depends on vmbus_drill_helper (static, see hyperv-drill-initramfs/) for the
# mmap-hold primitive. The guest has no CPython and this is a Day-0
# dependency, not a shim.
set -euo pipefail

CYCLES="${1:-100}"
LOG="${2:-/var/tmp/vmbus-lifecycle-drill.log}"
: >"$LOG"

HELPER="${HELPER:-$(command -v vmbus_drill_helper || true)}"

# --- guards: refuse to run on the daily WSL2 host -----------------------------
guard() {
	if grep -qiE 'microsoft-standard-WSL2' /proc/version 2>/dev/null; then
		echo "REFUSE: this is the daily WSL2 host. Run only in a disposable Hyper-V guest." >&2
		exit 2
	fi
	if [ ! -d /sys/bus/vmbus ]; then
		echo "REFUSE: no VMBus on this kernel; drill requires a Hyper-V guest." >&2
		exit 2
	fi
	if ! grep -qi 'hyperv' /sys/bus/vmbus/devices/*/modalias 2>/dev/null &&
		[ "$(ls /sys/bus/vmbus/devices 2>/dev/null | wc -l)" -eq 0 ]; then
		echo "REFUSE: no VMBus devices visible." >&2
		exit 2
	fi
}
guard

say() { echo "$@" | tee -a "$LOG"; }

# emit_verdicts_and_exit <code>
# Every exit path prints the same four independent verdicts and then the
# aggregate. A refusal that fires before phase 2 reports MAP_* as SKIP with
# "not launched" rather than folding an unmeasured surface into a claim. The
# aggregate is narrowed by construction: it repeats what was measured and
# says when a surface was not.
emit_verdicts_and_exit() {
	say "CLEANUP_VERDICT=${CLEANUP_VERDICT:-SKIP} ${CLEANUP_WHY:-not reached}"
	say "MAP_UIO_VERDICT=${MAP_UIO_VERDICT:-SKIP} ${MAP_UIO_WHY:-not launched}"
	say "MAP_SYSFS_VERDICT=${MAP_SYSFS_VERDICT:-SKIP} ${MAP_SYSFS_WHY:-not launched}"
	say "RESTORE_VERDICT=${RESTORE_VERDICT:-SKIP} ${RESTORE_WHY:-not reached}"
	say "LIFECYCLE_VERDICT=${LIFE:-FAIL} cleanup=${CLEANUP_VERDICT:-SKIP} map_uio=${MAP_UIO_VERDICT:-SKIP} map_sysfs=${MAP_SYSFS_VERDICT:-SKIP} restore=${RESTORE_VERDICT:-SKIP} cycles=$CYCLES maps=(${SETTLE_TUPLE:-}) gap_retained=(${GAP_N:-0}/${GAP_B:-0}/${GAP_P:-0}) settle_tries=${SETTLE_TRIES:-0} rebind=${REBIND_OK:-no}"
	if [ "${LIFE:-FAIL}" != PASS ]; then
		say "  aggregate is narrowed: it reports only the surfaces that were measured"
		say "  map_uio=${MAP_UIO_WHY:-not launched}"
		say "  map_sysfs=${MAP_SYSFS_WHY:-not launched}"
	fi
	say "=== END vmbus-lifecycle-drill ==="
	say "log=$LOG"
	exit "$1"
}

# --- VMEM: VMBus map accounting ---------------------------------------------
# Counts live vmbus_alloc_buffer maps and total vmalloc area attributed to them.
# Never logs kernel virtual addresses (SPEC: no KASLR material in evidence).
vmbus_maps() {
	if [ ! -r /proc/vmallocinfo ]; then
		echo "MAPS unreadable (need root / CONFIG_PROC_PAGE_MONITOR)" | tee -a "$LOG"
		return 1
	fi
	# /proc/vmallocinfo line shape:
	#   0xffff....-0xffff....  61440 vmbus_alloc_buffer+0x... pages=14 vmalloc
	#   $1 = virtual range (never logged), $2 = size in bytes, pages= is the
	#   backing page count. Size is taken from field 2 directly: parsing the
	#   range as if it were field 2 produced negative totals and would have
	#   reported garbage inside the guest.
	awk '
		/vmbus_alloc_buffer/ {
			n++
			total += $2
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^pages=/) {
					split($i, p, "=")
					pages += p[2]
				}
			}
		}
		END {
			printf "MAPS count=%d bytes=%d pages=%d\n", n, total, pages
		}
	' /proc/vmallocinfo
}

# Per-map sizes of live vmbus_alloc_buffer areas, one byte count per line.
# Size is the owner attribution available here: /proc/vmallocinfo names the
# allocating symbol for every one of these, so one kernel owner cannot be told
# from another. What can be told is whether a size was already accounted for
# before the teardown. A size that appears only after it is a retention this
# run cannot name, and an unnamed retention does not become balanced by
# sitting under an aggregate budget.
vmbus_map_sizes() {
	if [ ! -r /proc/vmallocinfo ]; then
		return 1
	fi
	awk ' /vmbus_alloc_buffer/ { print $2 } ' /proc/vmallocinfo
}

# sizes_unknown_after <before> <after>
# Prints each size in <after> with no match in <before>, one per line.
# Exit 0 when at least one is unknown, 1 when every after-size is accounted.
sizes_unknown_after() {
	awk '
		NR == FNR { seen[$1] = 1; next }
		!($1 in seen) { print $1; found = 1 }
		END { exit(found ? 0 : 1) }
	' "$1" "$2"
}

# hold_ready_maps <path>
# Prints the maps= count from this path's MMAP_HOLD READY line, or nothing.
# The path is compared as a whole field, never as a regex: a sysfs path is
# not a pattern.
hold_ready_maps() {
	awk -v p="$1" '
		$1 == "MMAP_HOLD" {
			path = ""; maps = ""
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^path=/) path = substr($i, 6)
				if ($i ~ /^maps=/) maps = substr($i, 6)
			}
			if (path == p && maps != "") last = maps
		}
		END { if (last != "") print last }
	' "$LOG"
}

say "=== BEGIN vmbus-lifecycle-drill cycles=$CYCLES ==="
say "kernel=$(uname -r)  cmdline=$(cat /proc/cmdline 2>/dev/null | tr -d '\n')"
say "symbols: $(grep -cE 'vmbus_(alloc|free|release)_buffer' /proc/kallsyms 2>/dev/null || echo 0) present"

say "--- BEFORE ---"
say "devices=$(ls /sys/bus/vmbus/devices 2>/dev/null | wc -l)"
BASE_MAPS="$(vmbus_maps || echo 'MAPS unavailable')"
say "$BASE_MAPS"
: >"$LOG.sizes-base"
vmbus_map_sizes >>"$LOG.sizes-base" 2>/dev/null || true
dmesg 2>/dev/null | tail -5 >>"$LOG"

# --- synthetic NIC rebind setup ---------------------------------------------
# The instance id is host-assigned and differs on every VM. Discover it from
# the hv_netvsc binding instead of hardcoding a GUID that only held on one lab
# machine.
discover_nic() {
	local d n
	for d in /sys/bus/vmbus/drivers/hv_netvsc/*; do
		[ -e "$d" ] || continue
		n="$(basename "$d")"
		case "$n" in
		bind | unbind | uevent | module | new_id | remove_id) continue ;;
		esac
		[ -d "$d" ] || continue
		printf '%s\n' "$n"
		return 0
	done
	return 1
}

NIC="${NIC:-$(discover_nic || true)}"
if [ -z "${NIC:-}" ]; then
	say "REFUSE: no synthetic NIC bound to hv_netvsc; cannot force ring realloc"
	exit 2
fi
say "NIC=$NIC (discovered from hv_netvsc binding)"
# class_id_show() emits "{%pUl}" WITH braces, but new_id_store() hands the
# buffer to guid_parse() -> uuid_is_valid(), which accepts exactly the 36-char
# canonical form. Braces make guid_parse() return -EINVAL, the dynid is never
# registered, and uio_hv_generic/bind fails every cycle. Read the class id
# from sysfs and strip the braces; do not hardcode a GUID that only holds for
# one device class.
CLS="$(cat "/sys/bus/vmbus/devices/$NIC/class_id" 2>/dev/null || true)"
# Strip exactly one leading { and one trailing }. The braces are escaped so the
# expansion is unambiguous in bash, dash and busybox ash alike; the unescaped
# `${CLS#{}` form parses differently across them and would leave a brace on.
CLS="${CLS#\{}"
CLS="${CLS%\}}"
if [ -z "$CLS" ]; then
	# HV_NIC_GUID, unbraced: the synthetic NIC's offer class.
	CLS='f8615163-df3e-46c5-913f-f2d2f965ed0e'
	say "CLS fallback=$CLS (sysfs class_id unreadable)"
else
	say "CLS=$CLS (from sysfs class_id, braces stripped)"
fi
DRIVER_DIR="/sys/bus/vmbus/drivers"

# REBIND_OK records whether restore_nic actually got hv_netvsc back on the
# device. It is a scoring input, not a nicety: after the BUG-3 hold the
# channel is still CHANNEL_OPENED_STATE because hv_uio_remove() never calls
# vmbus_disconnect_ring() -- identical in mainline base 93f51579e7df -- and
# the rebind then fails with -22. When that happens the NIC's own ring maps
# left with this phase's own unbind and cannot come back, so the end-of-run
# map tuple cannot return to the boot baseline and must not be scored as if
# it should.
REBIND_OK=no

restore_nic() {
	say "RESTORE begin"
	echo "$NIC" >"$DRIVER_DIR/uio_hv_generic/unbind" 2>>"$LOG" || true
	echo "$CLS" >"$DRIVER_DIR/uio_hv_generic/remove_id" 2>>"$LOG" || true
	echo "$NIC" >"$DRIVER_DIR/hv_netvsc/bind" 2>>"$LOG" || true
	# readlink -f on the driver symlink resolves to .../drivers/hv_netvsc on
	# a successful bind. On failure the symlink is absent and readlink still
	# prints the unresolved .../device/driver path, which is the
	# rebind-failure signature.
	RESTORE_DRIVER="$(readlink -f "/sys/bus/vmbus/devices/$NIC/driver" 2>/dev/null || echo none)"
	say "RESTORE driver=$RESTORE_DRIVER"
	case "$RESTORE_DRIVER" in
	*/drivers/hv_netvsc)
		REBIND_OK=yes
		say "RESTORE rebind=yes"
		;;
	*)
		REBIND_OK=no
		say "RESTORE rebind=no (hv_netvsc did not rebind; open channel is the known hv_uio_remove gap)"
		;;
	esac
}

# The BUG-3 holds run in the background so their mappings are alive while
# restore_nic frees the ring. Reap them on every exit path so a failed cycle
# cannot leave a helper holding /dev/uio0 after the script is gone.
HOLD_PIDS=""
cleanup() {
	restore_nic
	for hp in $HOLD_PIDS; do
		wait "$hp" 2>/dev/null || true
	done
}
trap cleanup EXIT

# --- phase 1: lifecycle balance (open/close) --------------------------------
say "=== PHASE 1: $CYCLES bind/unbind cycles ==="
say "PHASE1-BEFORE $(vmbus_maps || echo 'MAPS unavailable')"

# A cycle that cannot bind is not a quiet log line: it means the exercise never
# ran. Count them and fail at the end, otherwise thirty consecutive bind_fail
# still exits 0 and init scores the drill as passed.
CYCLE_FAILS=0

for i in $(seq 1 "$CYCLES"); do
	echo "$NIC" >"$DRIVER_DIR/hv_netvsc/unbind" 2>>"$LOG" ||
		{ say "cycle$i unbind_fail"; CYCLE_FAILS=$((CYCLE_FAILS + 1)); }
	# new_id must succeed: without a registered dynid, uio_hv_generic has
	# id_table = NULL and will never bind. A silent || true here hid exactly
	# that failure for thirty cycles and left the BUG-3 path unexercised.
	#
	# vmbus_add_dynid() ends in driver_attach(), so new_id binds the
	# matching device by itself. A following explicit bind then hits
	# __driver_probe_device() with dev->driver already set and returns
	# -EBUSY, which counted a correct attach as bind_fail thirty times.
	# Verify the binding instead of requiring the redundant write.
	echo "$CLS" >"$DRIVER_DIR/uio_hv_generic/new_id" 2>>"$LOG" ||
		{ say "cycle$i newid_fail"; CYCLE_FAILS=$((CYCLE_FAILS + 1)); }
	bound="$(readlink -f "/sys/bus/vmbus/devices/$NIC/driver" 2>/dev/null || echo none)"
	case "$bound" in
	*/uio_hv_generic) ;;
	*)
		echo "$NIC" >"$DRIVER_DIR/uio_hv_generic/bind" 2>>"$LOG" ||
			{ say "cycle$i bind_fail"; CYCLE_FAILS=$((CYCLE_FAILS + 1)); }
		;;
	esac
	echo "$NIC" >"$DRIVER_DIR/uio_hv_generic/unbind" 2>>"$LOG" || true
	echo "$CLS" >"$DRIVER_DIR/uio_hv_generic/remove_id" 2>>"$LOG" || true
	echo "$NIC" >"$DRIVER_DIR/hv_netvsc/bind" 2>>"$LOG" ||
		{ say "cycle$i rebind_fail"; CYCLE_FAILS=$((CYCLE_FAILS + 1)); }
	if [ $((i % 10)) -eq 0 ]; then
		say "cycle$i $(vmbus_maps || echo 'MAPS unavailable')"
	fi
done
say "PHASE1 cycle_fails=$CYCLE_FAILS / $((CYCLES * 4)) steps"

say "PHASE1-AFTER $(vmbus_maps || echo 'MAPS unavailable')"

# --- phase 2: UIO mmap + hold-in-mmap (BUG-3 candidate repro) ---------------
say "=== PHASE 2: UIO mmap + hold-in-mmap ==="
echo "$NIC" >"$DRIVER_DIR/hv_netvsc/unbind" 2>>"$LOG" || true
# The unbind releases the NIC's ring buffers through the owner reclaim path,
# which is asynchronous: vmbus_release_buffer() schedules the free and
# vmbus_buffer_unpin_pages() only drops the folio ref without waking the
# worker, so a map can outlive the unbind write by one or more
# VMBUS_BUFFER_RECLAIM_RETRY_MS intervals. Measured on run 37151705350: two
# of the three netvsc ring maps were gone the instant unbind returned and the
# third was still present, so a single sample reported 10 maps while the
# settled end state correctly reported 9. Sampled that way PRE_UIO is a
# transient inside the unbind's own teardown, not the state PHASE 2 starts
# from, and scoring against it invents an over-free that never happened.
# Settle first: hold the tuple unchanged across PRE_UIO_STABLE samples before
# treating it as PRE_UIO. The instant reading is kept beside it so a run where
# they differ still shows the drain.
PRE_UIO_INSTANT="$(vmbus_maps || echo 'MAPS unavailable')"
say "PRE_UIO_INSTANT $PRE_UIO_INSTANT"
PRE_UIO_BUDGET_S=15
PRE_UIO_STABLE=5
PRE_UIO_TRIES=0
PRE_UIO_MAPS=""
PRE_UIO_LAST=""
PRE_UIO_RUN=0
while [ "$PRE_UIO_TRIES" -le "$PRE_UIO_BUDGET_S" ]; do
	PRE_UIO_NOW="$(vmbus_maps || echo 'MAPS unavailable')"
	PRE_UIO_MAPS="$PRE_UIO_NOW"
	say "PRE_UIO_SETTLE try=$PRE_UIO_TRIES run=$PRE_UIO_RUN $PRE_UIO_NOW"
	if [ -n "$PRE_UIO_LAST" ] && [ "$PRE_UIO_NOW" = "$PRE_UIO_LAST" ]; then
		PRE_UIO_RUN=$((PRE_UIO_RUN + 1))
	else
		PRE_UIO_RUN=1
	fi
	PRE_UIO_LAST="$PRE_UIO_NOW"
	if [ "$PRE_UIO_RUN" -ge "$PRE_UIO_STABLE" ]; then
		break
	fi
	PRE_UIO_TRIES=$((PRE_UIO_TRIES + 1))
	if [ "$PRE_UIO_TRIES" -gt "$PRE_UIO_BUDGET_S" ]; then
		break
	fi
	sleep 1
done
if [ "$PRE_UIO_RUN" -lt "$PRE_UIO_STABLE" ]; then
	LIFE=PARTIAL
	CLEANUP_VERDICT=PARTIAL
	CLEANUP_WHY="pre-UIO tuple did not settle (instant='$PRE_UIO_INSTANT' last='$PRE_UIO_MAPS' run=$PRE_UIO_RUN)"
	RESTORE_VERDICT=PARTIAL
	RESTORE_WHY="the expected end tuple is unreadable while the unbind is still freeing"
	say "  instant='$PRE_UIO_INSTANT'"
	say "  last='$PRE_UIO_MAPS' run=$PRE_UIO_RUN"
	emit_verdicts_and_exit 3
fi
say "PRE_UIO $PRE_UIO_MAPS"
# new_id's driver_attach() is what binds the device; no separate bind.
echo "$CLS" >"$DRIVER_DIR/uio_hv_generic/new_id" 2>>"$LOG" || true
sleep 1

UIO_DEV=""
for u in /sys/class/uio/uio*; do
	[ -e "$u/name" ] || continue
	UIO_DEV="/dev/$(basename "$u")"
	say "UIO $(basename "$u") name=$(cat "$u/name" 2>/dev/null) maps=$(ls "$u/maps" 2>/dev/null | tr '\n' ' ')"
done

# mmap-hold sleeps `hold` seconds before releasing, so it has to run
# CONCURRENTLY with the teardown. Running it in the foreground mapped, held,
# released, and only then let restore_nic run -- the mapping was already gone
# when the ring was freed, so the BUG-3 window was never open and a green run
# proved nothing about mmap-versus-release.
#
# Two surfaces, two helpers, two verdicts. A sysfs ring map that never opened
# is not cured by a UIO map that did, and the reverse. Each helper publishes
# its own READY line (MMAP_HOLD path=... maps=N) after the maps exist and
# before the hold sleep, and its RELEASE line (MMAP_HOLD released maps=N)
# after munmap. Those are the barriers. A blind sleep is not: it scores a
# closed window as open whenever the helper is slower than the nap.
HOLD_PID_UIO=""
HOLD_PID_RING=""
UIO_MAPS_HELD=0
RING_MAPS_HELD=0
UIO_HOLD_STATUS=absent
RING_HOLD_STATUS=absent

if [ -n "$UIO_DEV" ] && [ -e "$UIO_DEV" ] && [ -n "$HELPER" ]; then
	say "PHASE2 mmap all maps of $UIO_DEV (held across teardown)"
	# UIO map N lives at offset N * pagesize. 8 maps of 4 KiB covers every
	# map the driver advertises.
	"$HELPER" mmap-hold "$UIO_DEV" 4096 8 8 >>"$LOG" 2>&1 &
	HOLD_PID_UIO=$!
	HOLD_PIDS="$HOLD_PIDS $HOLD_PID_UIO"
else
	say "PHASE2 no UIO device or no vmbus_drill_helper; skipping UIO mmap"
	say "PHASE2 note UIO hold-in-mmap did NOT run"
fi

RING="$(find /sys/devices -path "*$NIC*" -name 'ring' 2>/dev/null | head -1 || true)"
if [ -n "$RING" ]; then
	say "PHASE2 sysfs ring present: ${RING#/sys}"
	if [ -n "$HELPER" ]; then
		# hv_uio_new_channel() opens subchannels with ring_bytes = SZ_2M,
		# and VMBUS_RING_SIZE(SZ_2M) is 512 pages. hv_uio_ring_mmap_prepare()
		# treats pgoff as a page offset into that ring, so mapping 4 MiB at
		# pgoff 0 asked for 1024 pages of a 512-page ring and
		# hv_uio_mmap_range_valid() correctly rejected it. Map the ring at
		# its real size. chan_attr_ring_buffer has no .size, so the length
		# is not discoverable from stat(); it is fixed at SZ_2M by the
		# driver.
		say "PHASE2 ring mmap 2097152 bytes = SZ_2M subchannel ring (held across teardown)"
		"$HELPER" mmap-hold "$RING" 2097152 8 1 >>"$LOG" 2>&1 &
		HOLD_PID_RING=$!
		HOLD_PIDS="$HOLD_PIDS $HOLD_PID_RING"
	else
		say "PHASE2 no vmbus_drill_helper; skipping ring mmap"
	fi
else
	say "PHASE2 no sysfs ring found"
fi

# READY barrier. Wait for each launched helper to publish its own line. The
# budget is bounded because a helper that never publishes is not readiness,
# it is a hang -- and tearing down underneath a hold that never opened scores
# a closed window as open. maps=0 is a published failure, not a slow helper.
READY_BUDGET_S=10
READY_TRIES=0
READY_UIO_PUBLISHED=no
READY_RING_PUBLISHED=no
while [ "$READY_TRIES" -le "$READY_BUDGET_S" ]; do
	if [ "$READY_UIO_PUBLISHED" = no ] && [ -n "$HOLD_PID_UIO" ]; then
		_r="$(hold_ready_maps "$UIO_DEV" || true)"
		if [ -n "$_r" ]; then
			UIO_MAPS_HELD=$_r
			READY_UIO_PUBLISHED=yes
			say "READY UIO path=$UIO_DEV maps=$_r"
		fi
	fi
	if [ "$READY_RING_PUBLISHED" = no ] && [ -n "$HOLD_PID_RING" ]; then
		_r="$(hold_ready_maps "$RING" || true)"
		if [ -n "$_r" ]; then
			RING_MAPS_HELD=$_r
			READY_RING_PUBLISHED=yes
			say "READY SYSFS path=$RING maps=$_r"
		fi
	fi
	# Every launched helper has published, or was never launched. No outer
	# "someone published" guard: with no helper at all this must break at
	# once rather than spend the whole READY budget spinning.
	if { [ -z "$HOLD_PID_UIO" ] || [ "$READY_UIO_PUBLISHED" = yes ]; } &&
		{ [ -z "$HOLD_PID_RING" ] || [ "$READY_RING_PUBLISHED" = yes ]; }; then
		break
	fi
	READY_TRIES=$((READY_TRIES + 1))
	if [ "$READY_TRIES" -gt "$READY_BUDGET_S" ]; then
		break
	fi
	sleep 1
done
if [ -n "$HOLD_PID_UIO" ] && [ "$READY_UIO_PUBLISHED" = no ]; then
	say "READY UIO timeout after ${READY_BUDGET_S}s (helper published no MMAP_HOLD line)"
fi
if [ -n "$HOLD_PID_RING" ] && [ "$READY_RING_PUBLISHED" = no ]; then
	say "READY SYSFS timeout after ${READY_BUDGET_S}s (helper published no MMAP_HOLD line)"
fi

# Snapshot the sizes the teardown is allowed to leave behind, before it runs.
# This is the owner ledger: anything present afterwards that is not in this
# set is a retention no prior state accounts for.
: >"$LOG.sizes-before"
vmbus_map_sizes >>"$LOG.sizes-before" 2>/dev/null || true

say "=== PHASE 2 teardown while maps held (BUG-3 window) ==="
PHASE2_MAPS="$(vmbus_maps || echo 'MAPS unavailable')"
say "PHASE2-BEFORE-TEARDOWN $PHASE2_MAPS"
restore_nic
say "PHASE2-AFTER-TEARDOWN $(vmbus_maps || echo 'MAPS unavailable')"

# Collect the hold results with their real exit status. mmap-hold returns 0
# when at least one map was held and 1 when none were: swallowing that turns
# a failed mapping into a quiet skip and the run scores green on an exercise
# that never ran. The MMAP_HOLD lines go to the console so the uploaded
# artifact carries the numbers (and the errno when a mmap fails).
if [ -n "$HOLD_PID_UIO" ]; then
	if wait "$HOLD_PID_UIO"; then
		UIO_HOLD_STATUS=ok
	else
		UIO_HOLD_STATUS=failed
	fi
	say "HOLD UIO status=$UIO_HOLD_STATUS maps=$UIO_MAPS_HELD"
fi
if [ -n "$HOLD_PID_RING" ]; then
	if wait "$HOLD_PID_RING"; then
		RING_HOLD_STATUS=ok
	else
		RING_HOLD_STATUS=failed
	fi
	say "HOLD SYSFS status=$RING_HOLD_STATUS maps=$RING_MAPS_HELD"
fi
for p in $HOLD_PIDS; do
	wait "$p" 2>/dev/null || true
done
say "--- MMAP_HOLD evidence ---"
grep 'MMAP_HOLD\|HELPER mmap\|HELPER open' "$LOG" | tee -a "$LOG" || true
RELEASED_LINES="$(grep -c 'MMAP_HOLD released' "$LOG" 2>/dev/null || echo 0)"
say "RELEASE acks=$RELEASED_LINES (one per helper that reached munmap)"

# --- phase 3: reconciliation -------------------------------------------------
say "=== PHASE 3: reconciliation ==="
# Sampled the instant the hold helpers have been reaped. This is the racy
# window: the pins are already down, but the reclaim worker may not have
# run yet. Kept as evidence of that race, not as the verdict input.
FINAL_MAPS="$(vmbus_maps || echo 'MAPS unavailable')"
say "FINAL $FINAL_MAPS"
say "BASELINE $BASE_MAPS"
say "devices_final=$(ls /sys/bus/vmbus/devices 2>/dev/null | wc -l)"

say "--- dmesg fault scan ---"
if dmesg 2>/dev/null | tail -400 | grep -E 'BUG:|Oops:|WARNING:|hung task|accept4 failed|page allocation failure' >>"$LOG"; then
	say "FAULTS_PRESENT see log"
else
	say "FAULTS_NONE"
fi

# Extract "count bytes pages" from a vmbus_maps() line. Prints nothing and
# returns 1 when the tuple is missing or is a placeholder. Absent measurement
# is not a zero: treating "MAPS unavailable" as balanced is how an unread
# /proc/vmallocinfo looks like a clean accounting pass.
maps_tuple() {
	printf '%s\n' "$1" | awk '
		/^MAPS count=[0-9]+ bytes=[0-9]+ pages=[0-9]+$/ {
			sub(/^MAPS count=/, "")
			split($0, a, " bytes=")
			n = a[1]
			split(a[2], b, " pages=")
			print n, b[1], b[2]
			found = 1
		}
		END { exit(found ? 0 : 1) }
	'
}

# What band is the end of the run supposed to land in?
#
# PHASE 2 deliberately takes the production NIC down. restore_nic puts it
# back only if hv_netvsc rebinds. After the BUG-3 hold it does not: the
# channel is still CHANNEL_OPENED_STATE because hv_uio_remove() never calls
# vmbus_disconnect_ring() -- identical in mainline base 93f51579e7df -- and
# the probe then fails with -22. Two consequences follow, and both are
# properties of that disclosed gap rather than of this candidate:
#
#   1. The NIC's own maps leave with this phase's own unbind and cannot come
#      back, so the end tuple cannot equal the boot baseline.
#   2. UIO teardown is NOT the inverse of UIO probe. The probe re-establishes
#      the channel's ring maps; the gap leaves them in place because the
#      channel is never disconnected. Measured on run 37153111273 (both legs
#      identical): the unbind freed 5 maps / 19972096 bytes / 4871 pages, the
#      probe added 6 / 53608448 / 13082, teardown released exactly 4 /
#      49397760 / 12056 (UIO's own buffers, ~12 MiB each), and 2 maps /
#      4210688 bytes / 1026 pages stayed -- the ~2 MiB ring set the probe
#      re-established and the gap retains. Scoring the end against PRE_UIO
#      alone demands a state the gap makes unreachable and reports that
#      disclosure as a leak.
#
#   rebind=yes  -> the run is closed: the end must be the boot baseline
#                  exactly, because restore_nic put the NIC back.
#   rebind=no   -> a BAND. Lower bound is the settled PRE_UIO tuple: nothing
#                  PHASE 2 still owned may be freed below it. Upper bound is
#                  the boot baseline (no growth) and PRE_UIO plus a bounded
#                  ring-retention budget: UIO's own buffers are ~12 MiB each
#                  and must be gone, while the gap may keep only the ~2 MiB
#                  ring maps. A settled tuple above the budget is a UIO leak;
#                  below PRE_UIO is an over-free; above baseline is growth.
#
# PRE_UIO here is the settled one, not the instant sample: the unbind frees
# through the owner reclaim path and a map can still be queued when the write
# returns. Run 37151705350 measured that race -- a single sample reported 10
# maps while a third netvsc map was still draining and the settled state was
# 9 -- so an instant PRE_UIO invents an over-free that never happened.
#
# GAP_RING_BUDGET bounds what the disclosed hv_uio_remove() gap may retain.
# Sized to the ring class only: 4 maps (main send/recv plus up to two
# subchannel rings), 8 MiB, 2048 pages. One leaked UIO buffer is 12349440
# bytes / 3015 pages and blows the byte and page budget on its own.
GAP_RING_BUDGET_N=4
GAP_RING_BUDGET_B=8388608
GAP_RING_BUDGET_P=2048

# tuple_within_end_band <settle> <pre> <base> <rebind>
# Prints a reason and returns 1 outside the band; prints nothing and returns 0
# inside it. Safe under set -euo pipefail: every field is defaulted before use.
tuple_within_end_band() {
	_tws="${1:-}"
	_twp="${2:-}"
	_twb="${3:-}"
	_twr="${4:-no}"
	_sn=$(printf '%s\n' "$_tws" | awk '{print $1+0}')
	_sb=$(printf '%s\n' "$_tws" | awk '{print $2+0}')
	_sp=$(printf '%s\n' "$_tws" | awk '{print $3+0}')
	_pn=$(printf '%s\n' "$_twp" | awk '{print $1+0}')
	_pb=$(printf '%s\n' "$_twp" | awk '{print $2+0}')
	_pp=$(printf '%s\n' "$_twp" | awk '{print $3+0}')
	_bn=$(printf '%s\n' "$_twb" | awk '{print $1+0}')
	_bb=$(printf '%s\n' "$_twb" | awk '{print $2+0}')
	if [ "$_sn" -eq 0 ] && [ "$_sb" -eq 0 ]; then
		echo "tuple unreadable"
		return 1
	fi
	if [ "$_sn" -gt "$_bn" ] || [ "$_sb" -gt "$_bb" ]; then
		echo "growth above the boot baseline ($_sn/$_sb > $_bn/$_bb)"
		return 1
	fi
	if [ "$_twr" = yes ]; then
		if [ "$_sn" -ne "$_bn" ] || [ "$_sb" -ne "$_bb" ]; then
			echo "rebind=yes but the end is not the boot baseline ($_sn/$_sb != $_bn/$_bb)"
			return 1
		fi
		return 0
	fi
	if [ "$_sn" -lt "$_pn" ] || [ "$_sb" -lt "$_pb" ]; then
		echo "over-free below the settled pre-UIO tuple ($_sn/$_sb < $_pn/$_pb)"
		return 1
	fi
	_dn=$((_sn - _pn))
	_db=$((_sb - _pb))
	_dp=$((_sp - _pp))
	if [ "$_dn" -gt "$GAP_RING_BUDGET_N" ] || [ "$_db" -gt "$GAP_RING_BUDGET_B" ] || [ "$_dp" -gt "$GAP_RING_BUDGET_P" ]; then
		echo "ring retention over budget ($_dn maps $_db bytes $_dp pages > $GAP_RING_BUDGET_N/$GAP_RING_BUDGET_B/$GAP_RING_BUDGET_P); UIO buffers are not released"
		return 1
	fi
	return 0
}

BASE_TUPLE="$(maps_tuple "$BASE_MAPS")" || BASE_TUPLE=""
PRE_TUPLE="$(maps_tuple "${PRE_UIO_MAPS:-}")" || PRE_TUPLE=""
if [ -z "$BASE_TUPLE" ] || [ -z "$PRE_TUPLE" ]; then
	LIFE=PARTIAL
	CLEANUP_VERDICT=PARTIAL
	CLEANUP_WHY="map accounting unavailable, release unprovable"
	RESTORE_VERDICT=PARTIAL
	RESTORE_WHY="a phase-2 verdict needs the boot tuple and the tuple phase 2 started from"
	say "  baseline='$BASE_MAPS'"
	say "  pre_uio='${PRE_UIO_MAPS:-}'"
	say "  final='$FINAL_MAPS'"
	emit_verdicts_and_exit 3
fi
# The unbind may only remove maps. A settled PRE_UIO above the boot baseline
# means the unbind itself grew the accounting, and scoring the end against it
# would launder that growth in as the expected state. Count and bytes are
# compared; pages can differ by guard-page accounting and is not a growth
# signal on its own.
PRE_N=$(printf '%s\n' "$PRE_TUPLE" | awk '{print $1}')
PRE_B=$(printf '%s\n' "$PRE_TUPLE" | awk '{print $2}')
BASE_N=$(printf '%s\n' "$BASE_TUPLE" | awk '{print $1}')
BASE_B=$(printf '%s\n' "$BASE_TUPLE" | awk '{print $2}')
if [ -n "$PRE_N" ] && [ -n "$BASE_N" ]; then
	if [ "$PRE_N" -gt "$BASE_N" ] || [ "$PRE_B" -gt "$BASE_B" ]; then
		LIFE=FAIL
		CLEANUP_VERDICT=FAIL
		CLEANUP_WHY="the unbind grew the accounting (baseline=$BASE_TUPLE pre_uio=$PRE_TUPLE); not a reachable end state"
		RESTORE_VERDICT=FAIL
		RESTORE_WHY="pre-UIO tuple exceeds the boot baseline"
		say "  baseline=$BASE_TUPLE"
		say "  pre_uio=$PRE_TUPLE"
		say "  the unbind grew the accounting; that is not a reachable end state"
		emit_verdicts_and_exit 1
	fi
fi
if [ "${REBIND_OK:-no}" = yes ]; then
	EXPECT_TUPLE="$BASE_TUPLE"
	EXPECT_SRC="baseline (hv_netvsc rebound, run closed)"
else
	EXPECT_TUPLE="$PRE_TUPLE"
	EXPECT_SRC="band pre_uio..pre_uio+${GAP_RING_BUDGET_N}maps/${GAP_RING_BUDGET_B}B/${GAP_RING_BUDGET_P}p capped at baseline (hv_netvsc did not rebound; ring maps the UIO probe re-establishes are retained by the hv_uio_remove gap)"
fi

# Reclaim is asynchronous. vmbus_release_buffer() hands the buffer to
# delayed work, and vmbus_buffer_unpin_pages() only drops the folio ref --
# it does not wake the worker. The free can therefore land up to
# VMBUS_BUFFER_RECLAIM_RETRY_MS (1000 ms) after the last pin drops, and
# UIO teardown itself is not a clean inverse of UIO probe when the
# hv_uio_remove gap fires. Poll until the tuple is stable and inside the
# band this run is supposed to end on, or the settle budget expires. The
# budget is a few retry intervals, not an unbounded wait: a tuple still
# outside the band afterwards is a real accounting failure and stays FAIL.
# Stability is required so a mid-drain tuple that happens to land inside
# the band is not scored as the end state.
SETTLE_BUDGET_S=5
SETTLE_TRIES=0
SETTLE_TUPLE=""
SETTLE_PREV=""
SETTLE_WHY=""
while [ "$SETTLE_TRIES" -le "$SETTLE_BUDGET_S" ]; do
	SETTLE_NOW="$(vmbus_maps || echo 'MAPS unavailable')"
	SETTLE_TUPLE="$(maps_tuple "$SETTLE_NOW")" || SETTLE_TUPLE=""
	say "SETTLE try=$SETTLE_TRIES $SETTLE_NOW"
	if [ -n "$SETTLE_TUPLE" ]; then
		if SETTLE_WHY="$(tuple_within_end_band "$SETTLE_TUPLE" "$PRE_TUPLE" "$BASE_TUPLE" "${REBIND_OK:-no}")"; then
			if [ -n "$SETTLE_PREV" ] && [ "$SETTLE_TUPLE" = "$SETTLE_PREV" ]; then
				break
			fi
		fi
		SETTLE_PREV="$SETTLE_TUPLE"
	else
		SETTLE_WHY="tuple unreadable"
		SETTLE_PREV=""
	fi
	SETTLE_TRIES=$((SETTLE_TRIES + 1))
	if [ "$SETTLE_TRIES" -gt "$SETTLE_BUDGET_S" ]; then
		break
	fi
	sleep 1
done
SETTLE_MAPS="${SETTLE_NOW:-$FINAL_MAPS}"

# Scoring. Four independent verdicts and one aggregate that is explicitly a
# conjunction of them. The aggregate never folds a skipped surface into a
# green line, and never lets one mapping path's success stand in for the
# other's.
#
#   CLEANUP_VERDICT    bind/unbind steps succeeded and the teardown released
#                      something (the hold dropped its buffers)
#   MAP_UIO_VERDICT    the /dev/uioN character-device maps were established,
#                      held across restore_nic and released
#   MAP_SYSFS_VERDICT  the channel "ring" sysfs maps were established, held
#                      across restore_nic and released
#   RESTORE_VERDICT    the end tuple is in the band for this rebind outcome,
#                      and every retained map size is one a prior state
#                      already accounted for
#
# Reporting success after a silent skip -- or after a mapping that was
# already released -- is how a broken dynid registration looked green for
# thirty cycles and how a closed window looked like a hold-in-mmap pass.
# Reporting success without comparing the MAPS tuples is how a leak looks
# like balanced accounting: the scorer printed both and checked neither.
# Reporting failure because the tuple did not return to the *boot* baseline
# is one opposite error: it scores the known rebind gap as if it were a
# kernel defect, and a green run becomes unreachable on this guest.
# Reporting failure because the tuple sat above the settled pre-UIO tuple
# is the other: UIO teardown is not the inverse of UIO probe when the gap
# fires, so the ring maps the probe re-establishes survive it. Scoring
# that disclosure as a leak makes the gate unreachable for the opposite
# reason. The ring-retention budget separates the two: it is sized to the
# ~2 MiB ring class and is blown on its own by one ~12 MiB UIO buffer.
#
# The budget is not the whole test. A retention can sit inside it and still
# have no owner this run can name -- a synthetic 64 KiB area is well under
# the 8 MiB ceiling and is not a ring the probe re-established. Such a
# retention is unknown_owner_inside_retention_budget_is_not_complete_pass:
# it is a FAIL even though the aggregate numbers look balanced. Size is the
# only owner attribution /proc/vmallocinfo offers here (every area is
# attributed to vmbus_alloc_buffer), so the claim this scorer makes is
# narrowed to size classes, and it says so.

FINAL_TUPLE="$(maps_tuple "$FINAL_MAPS")" || FINAL_TUPLE=""
SETTLE_TUPLE="$(maps_tuple "$SETTLE_MAPS")" || SETTLE_TUPLE=""
PRE_INSTANT_TUPLE="$(maps_tuple "${PRE_UIO_INSTANT:-}")" || PRE_INSTANT_TUPLE="${PRE_UIO_INSTANT:-}"
PHASE2_TUPLE="$(maps_tuple "${PHASE2_MAPS:-}")" || PHASE2_TUPLE=""

# gap_retained is what the end state holds above the settled pre-UIO tuple.
# With rebind=no that is the ring set the UIO probe re-establishes and the
# hv_uio_remove gap retains, and it must sit inside the ring-retention
# budget. With rebind=yes the end is the boot baseline and the delta is
# informational only -- the band check there is the exact baseline match --
# but it is printed in both cases so one log format covers both runs.
GAP_N=0
GAP_B=0
GAP_P=0
if [ -n "$SETTLE_TUPLE" ] && [ -n "$PRE_TUPLE" ]; then
	GAP_N=$(($(printf '%s\n' "$SETTLE_TUPLE" | awk '{print $1+0}') - $(printf '%s\n' "$PRE_TUPLE" | awk '{print $1+0}')))
	GAP_B=$(($(printf '%s\n' "$SETTLE_TUPLE" | awk '{print $2+0}') - $(printf '%s\n' "$PRE_TUPLE" | awk '{print $2+0}')))
	GAP_P=$(($(printf '%s\n' "$SETTLE_TUPLE" | awk '{print $3+0}') - $(printf '%s\n' "$PRE_TUPLE" | awk '{print $3+0}')))
fi

# Owner ledger. Anything the end holds whose size no prior state showed is a
# retention this run cannot attribute.
: >"$LOG.sizes-after"
vmbus_map_sizes >>"$LOG.sizes-after" 2>/dev/null || true
UNKNOWN_SIZES=""
if [ -s "$LOG.sizes-before" ]; then
	cat "$LOG.sizes-base" "$LOG.sizes-before" 2>/dev/null | sort -n -u >"$LOG.sizes-known" || true
	if [ -s "$LOG.sizes-after" ] && [ -s "$LOG.sizes-known" ]; then
		UNKNOWN_SIZES="$(sizes_unknown_after "$LOG.sizes-known" "$LOG.sizes-after" || true)"
	fi
elif [ -s "$LOG.sizes-after" ]; then
	# No prior ledger: the retention cannot be attributed to anything.
	UNKNOWN_SIZES="$(sort -n -u "$LOG.sizes-after")"
fi

say "  baseline=$BASE_TUPLE"
say "  pre_uio=$PRE_TUPLE"
say "  pre_uio_instant=$PRE_INSTANT_TUPLE"
say "  phase2_before=$PHASE2_TUPLE"
say "  final=$FINAL_TUPLE"
say "  settle=$SETTLE_TUPLE tries=$SETTLE_TRIES"
say "  expected=$EXPECT_TUPLE source=$EXPECT_SRC"
say "  gap_retained=$GAP_N/$GAP_B/$GAP_P budget=$GAP_RING_BUDGET_N/$GAP_RING_BUDGET_B/$GAP_RING_BUDGET_P"
say "  rebind=${REBIND_OK:-no}"
if [ -n "$UNKNOWN_SIZES" ]; then
	say "  unidentified_retained_sizes: $(printf '%s' "$UNKNOWN_SIZES" | tr '\n' ' ')"
else
	say "  unidentified_retained_sizes: none"
fi

# --- CLEANUP_VERDICT --------------------------------------------------------
CLEANUP_VERDICT=PASS
CLEANUP_WHY="steps ok, teardown released"
if [ "${CYCLE_FAILS:-0}" -gt 0 ]; then
	CLEANUP_VERDICT=FAIL
	CLEANUP_WHY="cycle_fails=$CYCLE_FAILS"
elif [ -n "$PHASE2_TUPLE" ] && [ -n "$SETTLE_TUPLE" ]; then
	PH2_N=$(printf '%s\n' "$PHASE2_TUPLE" | awk '{print $1+0}')
	PH2_B=$(printf '%s\n' "$PHASE2_TUPLE" | awk '{print $2+0}')
	ST_N=$(printf '%s\n' "$SETTLE_TUPLE" | awk '{print $1+0}')
	ST_B=$(printf '%s\n' "$SETTLE_TUPLE" | awk '{print $2+0}')
	if [ "$ST_N" -ge "$PH2_N" ] && [ "$ST_B" -ge "$PH2_B" ]; then
		CLEANUP_VERDICT=FAIL
		CLEANUP_WHY="teardown released nothing (phase2_before=$PHASE2_TUPLE settle=$SETTLE_TUPLE)"
	fi
elif [ -z "$SETTLE_TUPLE" ]; then
	CLEANUP_VERDICT=PARTIAL
	CLEANUP_WHY="map accounting unavailable, release unprovable"
fi

# --- MAP_UIO_VERDICT / MAP_SYSFS_VERDICT ------------------------------------
# Independent by construction: each surface has its own helper, its own READY
# ack and its own exit status. One path's success is not the other's.
MAP_UIO_VERDICT=SKIP
MAP_UIO_WHY="surface not launched"
if [ -n "$HOLD_PID_UIO" ]; then
	if [ "$UIO_HOLD_STATUS" != ok ]; then
		MAP_UIO_VERDICT=FAIL
		MAP_UIO_WHY="helper status=$UIO_HOLD_STATUS (mmap-hold returns 1 when no map was held)"
	elif [ "${UIO_MAPS_HELD:-0}" -eq 0 ]; then
		MAP_UIO_VERDICT=FAIL
		MAP_UIO_WHY="published maps=0 (opened nothing)"
	elif [ "$READY_UIO_PUBLISHED" != yes ]; then
		MAP_UIO_VERDICT=FAIL
		MAP_UIO_WHY="no READY ack within ${READY_BUDGET_S}s"
	else
		MAP_UIO_VERDICT=PASS
		MAP_UIO_WHY="maps=$UIO_MAPS_HELD held across teardown, status=$UIO_HOLD_STATUS"
	fi
fi

MAP_SYSFS_VERDICT=SKIP
MAP_SYSFS_WHY="surface not launched"
if [ -n "$HOLD_PID_RING" ]; then
	if [ "$RING_HOLD_STATUS" != ok ]; then
		MAP_SYSFS_VERDICT=FAIL
		MAP_SYSFS_WHY="helper status=$RING_HOLD_STATUS (mmap-hold returns 1 when no map was held)"
	elif [ "${RING_MAPS_HELD:-0}" -eq 0 ]; then
		MAP_SYSFS_VERDICT=FAIL
		MAP_SYSFS_WHY="published maps=0 (opened nothing)"
	elif [ "$READY_RING_PUBLISHED" != yes ]; then
		MAP_SYSFS_VERDICT=FAIL
		MAP_SYSFS_WHY="no READY ack within ${READY_BUDGET_S}s"
	else
		MAP_SYSFS_VERDICT=PASS
		MAP_SYSFS_WHY="maps=$RING_MAPS_HELD held across teardown, status=$RING_HOLD_STATUS"
	fi
fi

# --- RESTORE_VERDICT --------------------------------------------------------
RESTORE_VERDICT=PASS
RESTORE_WHY="end tuple in band, retained sizes identified"
if [ -z "$SETTLE_TUPLE" ]; then
	RESTORE_VERDICT=PARTIAL
	RESTORE_WHY="map accounting unavailable"
elif ! BAND_WHY="$(tuple_within_end_band "$SETTLE_TUPLE" "$PRE_TUPLE" "$BASE_TUPLE" "${REBIND_OK:-no}")"; then
	RESTORE_VERDICT=FAIL
	RESTORE_WHY="outside the expected band: ${BAND_WHY:-unknown}"
elif [ -n "$UNKNOWN_SIZES" ]; then
	RESTORE_VERDICT=FAIL
	RESTORE_WHY="unknown_owner_inside_retention_budget_is_not_complete_pass: retained sizes no prior state accounted for"
fi

# --- aggregate --------------------------------------------------------------
# PASS requires every verdict to be PASS. A skipped or partial surface makes
# the aggregate PARTIAL, never PASS: a green line that silently omitted a
# mapping path is the exact failure this scorer exists to refuse.
LIFE=PASS
LIFE_CODE=0
for _v in "$CLEANUP_VERDICT" "$MAP_UIO_VERDICT" "$MAP_SYSFS_VERDICT" "$RESTORE_VERDICT"; do
	case "$_v" in
	FAIL)
		LIFE=FAIL
		LIFE_CODE=1
		break
		;;
	SKIP | PARTIAL)
		if [ "$LIFE" = PASS ]; then
			LIFE=PARTIAL
			LIFE_CODE=3
		fi
		;;
	esac
done

emit_verdicts_and_exit "$LIFE_CODE"
