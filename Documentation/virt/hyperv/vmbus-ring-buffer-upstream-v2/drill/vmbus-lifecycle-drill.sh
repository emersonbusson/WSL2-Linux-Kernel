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

# --self-test exercises this scorer's own decision code against fixtures.
# It runs before the guest guards so it can execute on any host. Every
# fixture is a validator demonstration; none of them is a reproduced kernel
# leak, and none of them authorizes a claim about a running kernel.
SELF_TEST=0
if [ "${1:-}" = --self-test ]; then
	SELF_TEST=1
	shift
fi

CYCLES="${1:-100}"
if [ "$SELF_TEST" -eq 1 ]; then
	LOG="$(mktemp /tmp/vmbus-lifecycle-selftest.XXXXXX)"
else
	LOG="${2:-/var/tmp/vmbus-lifecycle-drill.log}"
	: >"$LOG"
fi

HELPER="${HELPER:-$(command -v vmbus_drill_helper || true)}"

say() { echo "$@" | tee -a "$LOG"; }

# emit_verdicts_and_exit <code>
# Every exit path prints the same five independent verdicts and then the
# aggregate. A refusal that fires before phase 2 reports MAP_* as SKIP with
# "not launched" rather than folding an unmeasured surface into a claim. The
# aggregate is narrowed by construction: it repeats what was measured and
# says when a surface was not. owner_attribution is printed on every path so
# no reader can mistake the size-class ledger for an owner ledger.
emit_verdicts_and_exit() {
	say "CLEANUP_VERDICT=${CLEANUP_VERDICT:-SKIP} ${CLEANUP_WHY:-not reached}"
	say "MAP_UIO_VERDICT=${MAP_UIO_VERDICT:-SKIP} ${MAP_UIO_WHY:-not launched}"
	say "MAP_SYSFS_VERDICT=${MAP_SYSFS_VERDICT:-SKIP} ${MAP_SYSFS_WHY:-not launched}"
	say "MAP_ACCOUNTING_VERDICT=${MAP_ACCOUNTING_VERDICT:-SKIP} ${MAP_ACCOUNTING_WHY:-not reached}"
	say "RESTORE_VERDICT=${RESTORE_VERDICT:-SKIP} ${RESTORE_WHY:-not reached}"
	say "owner_attribution=size_class_only (/proc/vmallocinfo names the allocating symbol, not the instance)"
	say "LIFECYCLE_VERDICT=${LIFE:-FAIL} cleanup=${CLEANUP_VERDICT:-SKIP} map_uio=${MAP_UIO_VERDICT:-SKIP} map_sysfs=${MAP_SYSFS_VERDICT:-SKIP} map_accounting=${MAP_ACCOUNTING_VERDICT:-SKIP} restore=${RESTORE_VERDICT:-SKIP} cycles=$CYCLES maps=(${SETTLE_TUPLE:-}) gap_retained=(${GAP_N:-0}/${GAP_B:-0}/${GAP_P:-0}) settle_tries=${SETTLE_TRIES:-0} rebind=${REBIND_OK:-no}"
	if [ "${LIFE:-FAIL}" != PASS ]; then
		say "  aggregate is narrowed: it reports only the surfaces that were measured"
		say "  map_uio=${MAP_UIO_WHY:-not launched}"
		say "  map_sysfs=${MAP_SYSFS_WHY:-not launched}"
		say "  map_accounting=${MAP_ACCOUNTING_WHY:-not reached}"
		say "  restore=${RESTORE_WHY:-not reached}"
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

# size_class_max_counts <snapshot>...
# Each snapshot is one line per live map instance, so multiplicity is
# preserved. Emit "size maxcount" using the highest count any single
# snapshot showed for that class. Snapshots are observations of the same
# areas at different times, so the known multiset is the per-class maximum,
# never the sum across snapshots: summing would "account for" a class that
# only ever appeared twice in total by crediting it with four.
size_class_max_counts() {
	awk '
		FNR == 1 { snap++ }
		{ key = snap SUBSEP $1; c[key]++ }
		END {
			for (key in c) {
				split(key, k, SUBSEP)
				if (c[key] > max[k[2]])
					max[k[2]] = c[key]
			}
			for (s in max) printf "%s %d\n", s, max[s]
		}
	' "$@"
}

# sizes_excess_after <known_counts> <after_instances>
# Multiset, never set membership. <known_counts> is "size maxcount" lines
# from size_class_max_counts; <after_instances> is one line per live
# map at the end. Print "size new" for a class no prior state held and
# "size excess N" when the end holds more of a known class than any prior
# state did.
#
# A duplicate of a known size is not owner identity: two 65536-byte areas
# are two areas, and a second map of a familiar size is exactly the
# retention a set-membership check accepts. Exit 0 when at least one class
# is unaccounted, 1 when the end multiset is covered.
sizes_excess_after() {
	awk '
		NR == FNR { known[$1] = $2 + 0; next }
		{ after[$1]++ }
		END {
			found = 0
			for (s in after) {
				k = (s in known) ? known[s] : 0
				if (after[s] > k) {
					if (k == 0)
						printf "%s new\n", s
					else
						printf "%s excess %d\n", s, after[s] - k
					found = 1
				}
			}
			exit(found ? 0 : 1)
		}
	' "$1" "$2"
}

# hold_ready_maps <path>
# Prints the maps= count from this path's MMAP_HOLD READY line, but only
# while that hold is still live. A READY line followed by a RELEASE line
# for the same path is a historical hold: those mappings were gone before
# teardown and must never be counted as an active one. That is the
# eight-second-hold-versus-ten-second-readiness race -- a stale message
# accepted as an active map.
#
# The path is compared as a whole field, never as a regex: a sysfs path is
# not a pattern. "released" is matched as a whole field for the same reason.
hold_ready_maps() {
	awk -v p="$1" '
		$1 == "MMAP_HOLD" {
			path = ""; maps = ""; released = 0
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^path=/) path = substr($i, 6)
				if ($i ~ /^maps=/) maps = substr($i, 6)
				if ($i == "released") released = 1
			}
			if (path == p) {
				if (released)
					last = ""
				else if (maps != "")
					last = maps
			}
		}
		END { if (last != "") print last }
	' "$LOG"
}

# hold_already_released <path>
# True when this path's RELEASE line is already in the log. Used right
# before the caller publishes its release signal: if the hold ended on its
# own before that point, it ended before the teardown finished and the
# surface did not span the window it claims to.
hold_already_released() {
	awk -v p="$1" '
		$1 == "MMAP_HOLD" {
			path = ""; released = 0
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^path=/) path = substr($i, 6)
				if ($i == "released") released = 1
			}
			if (path == p && released) found = 1
		}
		END { exit(found ? 0 : 1) }
	' "$LOG"
}

# Permitted page reads. Two of them, and they answer different questions.
# touch_ready is taken at establishment, while the caller's node still
# exists: it is the only read inside the window the hold claims to cover.
# touch is taken after the release signal and may legitimately fault on a
# surface whose node is gone. They must not be conflated: a scraper that
# takes whichever ok= it saw last would report the establishment read as
# if it were the post-teardown one.
hold_touch_ready() {
	awk -v p="$1" '
		$1 == "MMAP_HOLD" {
			path = ""; ok = ""; tag = ""
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^path=/) path = substr($i, 6)
				if ($i ~ /^ok=/) ok = substr($i, 4)
				if ($i == "touch_ready") tag = "ready"
			}
			if (path == p && tag == "ready" && ok != "") last = ok
		}
		END { if (last != "") print last }
	' "$LOG"
}
hold_touch_after() {
	awk -v p="$1" '
		$1 == "MMAP_HOLD" {
			path = ""; ok = ""; tag = ""
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^path=/) path = substr($i, 6)
				if ($i ~ /^ok=/) ok = substr($i, 4)
				if ($i == "touch") tag = "after"
			}
			if (path == p && tag == "after" && ok != "") last = ok
		}
		END { if (last != "") print last }
	' "$LOG"
}
hold_release_waited() {
	awk -v p="$1" '
		$1 == "MMAP_HOLD" && $2 == "release_wait" {
			path = ""
			for (i = 1; i <= NF; i++)
				if ($i ~ /^path=/) path = substr($i, 6)
			if (path == p) last = "yes"
		}
		END { if (last != "") print last }
	' "$LOG"
}

# derive_map_accounting_verdict <settle> <pre> <base> <rebind> <unknown_sizes>
# Sets MAP_ACCOUNTING_VERDICT and MAP_ACCOUNTING_WHY. This is the size-class
# ledger and the end-tuple band. It is explicitly scoped to what map
# accounting can observe and says nothing about whether a device returned.
derive_map_accounting_verdict() {
	_ma_settle="${1:-}"
	_ma_pre="${2:-}"
	_ma_base="${3:-}"
	_ma_rebind="${4:-no}"
	_ma_unknown="${5:-}"
	MAP_ACCOUNTING_VERDICT=PASS
	MAP_ACCOUNTING_WHY="end tuple in band, retained size classes identified"
	if [ -z "$_ma_settle" ]; then
		MAP_ACCOUNTING_VERDICT=PARTIAL
		MAP_ACCOUNTING_WHY="map accounting unavailable"
	elif ! BAND_WHY="$(tuple_within_end_band "$_ma_settle" "$_ma_pre" "$_ma_base" "$_ma_rebind")"; then
		MAP_ACCOUNTING_VERDICT=FAIL
		MAP_ACCOUNTING_WHY="outside the expected band: ${BAND_WHY:-unknown}"
	elif [ -n "$_ma_unknown" ]; then
		MAP_ACCOUNTING_VERDICT=FAIL
		MAP_ACCOUNTING_WHY="unknown_size_class_inside_retention_budget_is_not_complete_pass: $(printf '%s' "$_ma_unknown" | tr '\n' ' ')"
	fi
}

# derive_map_surface_verdict <launched> <status> <maps> <ready_published>
#   <released_early> <ready_ok> <after_ok> <release_waited> <sustain>
# Sets MAP_SURFACE_VERDICT and MAP_SURFACE_WHY for one mmap surface. One
# call per surface; the caller copies the result into MAP_UIO_* or
# MAP_SYSFS_*.
#
# Two contracts, because the two surfaces do not promise the same
# lifetime. The UIO char device keeps its pin until the VMA closes, so its
# pages must still be readable after teardown: sustain=yes. The sysfs
# "ring" node is a kernfs bin attribute and is removed by
# hv_remove_ring_sysfs() before vmbus_free_ring() runs; its mapping is
# withdrawn there by design, and kernfs then zaps the PTEs. On that
# surface a post-teardown SIGBUS is the withdraw-before-free ordering,
# not a freed-under-mapping: sustain=no. Requiring the sysfs read to
# succeed would be requiring a lifetime the surface never promised.
#
# Both contracts require the same hard floor: the mapping was live at
# establishment (ready_ok), the hold survived the window (not released
# early, reached the release signal), and the READY ack is real.
derive_map_surface_verdict() {
	_launched="${1:-no}"
	_status="${2:-absent}"
	_maps="${3:-0}"
	_ready="${4:-no}"
	_early="${5:-no}"
	_readyok="${6:-}"
	_afterok="${7:-}"
	_waited="${8:-no}"
	_sustain="${9:-yes}"
	if [ "$_launched" != yes ]; then
		MAP_SURFACE_VERDICT=SKIP
		MAP_SURFACE_WHY="surface not launched"
		return 0
	fi
	if [ "$_maps" -eq 0 ]; then
		MAP_SURFACE_VERDICT=FAIL
		MAP_SURFACE_WHY="published maps=0 (opened nothing)"
		return 0
	fi
	if [ "$_ready" != yes ]; then
		MAP_SURFACE_VERDICT=FAIL
		MAP_SURFACE_WHY="no READY ack within ${READY_BUDGET_S:-10}s"
		return 0
	fi
	if [ "$_early" = yes ]; then
		MAP_SURFACE_VERDICT=FAIL
		MAP_SURFACE_WHY="hold released before the teardown completed; $_maps maps claimed, none spanning the window"
		return 0
	fi
	if [ -z "$_readyok" ] || [ "$_readyok" != "$_maps" ]; then
		MAP_SURFACE_VERDICT=FAIL
		MAP_SURFACE_WHY="liveness at establishment did not cover the held maps (touch_ready=${_readyok:-none} maps=$_maps)"
		return 0
	fi
	if [ "$_sustain" = yes ]; then
		if [ "$_status" = ok ] && [ -n "$_afterok" ] && [ "$_afterok" = "$_maps" ]; then
			MAP_SURFACE_VERDICT=PASS
			MAP_SURFACE_WHY="maps=$_maps pinned across teardown, post-teardown reads=$_afterok"
		else
			MAP_SURFACE_VERDICT=FAIL
			MAP_SURFACE_WHY="pin contract: pages must stay readable after teardown (status=$_status touch_ready=$_readyok touch_after=${_afterok:-none} maps=$_maps)"
		fi
		return 0
	fi
	# sustain=no: the node goes away at teardown and takes the mapping
	# with it. The helper must have lived through the hold window to the
	# release signal. After that, either the mapping still reads, or the
	# helper died on the post-hold read because the PTEs were already
	# zapped -- both are the correct outcome. Death before the release
	# signal is not.
	if [ "$_waited" != yes ]; then
		MAP_SURFACE_VERDICT=FAIL
		MAP_SURFACE_WHY="helper did not reach the release signal (status=$_status); the hold window is unproven"
		return 0
	fi
	if [ -n "$_afterok" ] && [ "$_afterok" = "$_maps" ]; then
		MAP_SURFACE_VERDICT=PASS
		MAP_SURFACE_WHY="maps=$_maps live at establishment and still readable after teardown (touch_ready=$_readyok touch_after=$_afterok)"
	elif [ "$_status" != ok ]; then
		MAP_SURFACE_VERDICT=PASS
		MAP_SURFACE_WHY="maps=$_maps live at establishment, mapping withdrawn at node removal after a live hold (touch_ready=$_readyok, post-hold read took the helper: status=$_status)"
	else
		MAP_SURFACE_VERDICT=FAIL
		MAP_SURFACE_WHY="post-hold reads did not cover the held maps (touch_after=${_afterok:-none} maps=$_maps)"
	fi
}

# derive_restore_verdict <rebind>
# Sets RESTORE_VERDICT and RESTORE_WHY. This verdict is about one thing:
# did the selected NIC actually come back. Map accounting is somebody
# else's verdict. With rebind=no the device did not return, so this cannot
# be a complete PASS -- the hv_uio_remove() gap is pre-existing mainline and
# is disclosed, and a PARTIAL is the honest reading of a run that proved
# the maps and not the device.
derive_restore_verdict() {
	if [ "${1:-no}" = yes ]; then
		RESTORE_VERDICT=PASS
		RESTORE_WHY="hv_netvsc rebound onto the selected NIC"
	else
		RESTORE_VERDICT=PARTIAL
		RESTORE_WHY="rebind=no (hv_netvsc did not rebind; open channel is the known hv_uio_remove gap); device restoration not proven"
	fi
}

# derive_aggregate
# Sets LIFE and LIFE_CODE from the five independent verdicts. PASS requires
# every one of them to be PASS. A skipped or partial surface makes the
# aggregate PARTIAL and never PASS.
derive_aggregate() {
	LIFE=PASS
	LIFE_CODE=0
	for _v in "$CLEANUP_VERDICT" "$MAP_UIO_VERDICT" "$MAP_SYSFS_VERDICT" \
		"$MAP_ACCOUNTING_VERDICT" "$RESTORE_VERDICT"; do
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
}

# --- self-test fixtures ------------------------------------------------------
# Each fixture feeds the same decision functions the real run uses. A
# fixture that assigned the verdict by hand and then checked it would skip
# the very decision it exists to catch. Fixtures are validator
# demonstrations: they prove the scorer refuses a shape, and claim nothing
# about a reproduced kernel leak.
ST_PASS=0
ST_FAIL=0

st_ok() {
	ST_PASS=$((ST_PASS + 1))
	printf 'PASS %s\n' "$1"
}

st_no() {
	ST_FAIL=$((ST_FAIL + 1))
	printf 'FAIL %s\n' "$1"
}

st_check() {
	if "$@"; then
		return 0
	fi
	return 1
}

# Point 1. A balanced end tuple with rebind=no. Map accounting may pass;
# the device verdict may not, and the aggregate may not become a complete
# lifecycle PASS. Merely assigning RESTORE_VERDICT=FAIL in a fixture would
# skip the decision, so this calls the real derive_* bodies.
st_rebind_no_is_not_device_restore_pass() {
	derive_map_accounting_verdict "9 4517888 1094" "7 307200 68" "12 20279296 4939" no ""
	derive_restore_verdict no
	CLEANUP_VERDICT=PASS
	MAP_UIO_VERDICT=PASS
	MAP_SYSFS_VERDICT=PASS
	derive_aggregate
	if [ "$MAP_ACCOUNTING_VERDICT" != PASS ]; then
		echo "  map accounting should pass inside the band, got $MAP_ACCOUNTING_VERDICT"
		return 1
	fi
	if [ "$RESTORE_VERDICT" = PASS ]; then
		echo "  rebind=no must not be a device-restore PASS"
		return 1
	fi
	if [ "$LIFE" = PASS ]; then
		echo "  aggregate must not be a complete lifecycle PASS with rebind=no (got $LIFE/$LIFE_CODE)"
		return 1
	fi
	return 0
}

# Point 2. Set membership would accept a second map of a size that was
# already known. A multiset must not.
st_duplicate_known_size_is_not_owner_identity() {
	printf '65536\n' >"$LOG.known1"
	printf '65536 1\n' >"$LOG.knownc"
	printf '65536\n65536\n' >"$LOG.after"
	_out="$(sizes_excess_after "$LOG.knownc" "$LOG.after" || true)"
	if [ -z "$_out" ]; then
		echo "  a second 65536-byte map was accepted as a known size"
		return 1
	fi
	printf '%s\n' "$_out" | grep -q '65536 excess 1' || {
		echo "  expected '65536 excess 1', got '$_out'"
		return 1
	}
	return 0
}

# Point 2. The end holds three of a class no prior state held more than one
# of. Multiplicity must survive the comparison.
st_known_size_with_unexpected_multiplicity_is_not_complete_pass() {
	printf '4096 2\n' >"$LOG.knownc"
	printf '4096\n4096\n4096\n4096\n' >"$LOG.after"
	_out="$(sizes_excess_after "$LOG.knownc" "$LOG.after" || true)"
	if [ -z "$_out" ]; then
		echo "  multiplicity jump was folded into set membership"
		return 1
	fi
	printf '%s\n' "$_out" | grep -q '4096 excess 2' || {
		echo "  expected '4096 excess 2', got '$_out'"
		return 1
	}
	return 0
}

# Point 2. One 65536-byte area goes away and a different one arrives: the
# counts balance, so the multiset is clean. That is not owner identity, and
# the scorer must not claim it is. The qualification is narrowed to size
# classes and says so.
st_replacement_owner_same_size_is_not_complete_pass() {
	printf '65536 1\n' >"$LOG.knownc"
	printf '65536\n' >"$LOG.after"
	_out="$(sizes_excess_after "$LOG.knownc" "$LOG.after" || true)"
	if [ -n "$_out" ]; then
		echo "  a same-size replacement was reported as excess ($_out); counts balance"
		return 1
	fi
	derive_map_accounting_verdict "9 4517888 1094" "7 307200 68" "12 20279296 4939" no ""
	case "$MAP_ACCOUNTING_WHY" in
	*size\ class*)
		:
		;;
	*)
		echo "  the claim must be narrowed to size classes, got: $MAP_ACCOUNTING_WHY"
		return 1
		;;
	esac
	case "$MAP_ACCOUNTING_WHY" in
	*owner\ ident*)
		echo "  the claim must not assert owner identity: $MAP_ACCOUNTING_WHY"
		return 1
		;;
	esac
	return 0
}

# Point 2. The original refusal: a 64 KiB area present at the end and in no
# prior ledger, well inside the ring-retention budget.
st_unknown_64k_retention_is_refused() {
	printf '4096 1\n' >"$LOG.knownc"
	printf '4096\n65536\n' >"$LOG.after"
	_out="$(sizes_excess_after "$LOG.knownc" "$LOG.after" || true)"
	printf '%s\n' "$_out" | grep -q '65536 new' || {
		echo "  expected '65536 new', got '$_out'"
		return 1
	}
	derive_map_accounting_verdict "9 4583424 1109" "7 307200 68" "12 20279296 4939" no "$_out"
	if [ "$MAP_ACCOUNTING_VERDICT" != FAIL ]; then
		echo "  an unattributed 64 KiB retention must FAIL map accounting, got $MAP_ACCOUNTING_VERDICT"
		return 1
	fi
	return 0
}

# Point 3. The first helper released before the second was even ready. Its
# READY line is in the log and must not be accepted as an active hold.
st_first_helper_releases_before_second_ready() {
	cat >"$LOG" <<'LOGE'
MMAP_HOLD path=/dev/uio0 bytes=4096 maps=5 hold=8
MMAP_HOLD released path=/dev/uio0 maps=5
LOGE
	if [ -n "$(hold_ready_maps /dev/uio0)" ]; then
		echo "  a released hold was accepted as an active map"
		return 1
	fi
	cat >>"$LOG" <<'LOGE'
MMAP_HOLD path=/sys/devices/1/ring bytes=2097152 maps=1 hold=8
LOGE
	_r="$(hold_ready_maps /sys/devices/1/ring)"
	if [ "$_r" != 1 ]; then
		echo "  the still-live ring hold must be visible, got '${_r}'"
		return 1
	fi
	return 0
}

# Point 3. The helper died after publishing READY. A non-zero status is not
# a quiet skip and must not become a PASS on the strength of the READY line.
# Two shapes, one per contract. On the pin surface a dead helper is a FAIL
# however far it got. On the withdraw surface a death before the release
# signal leaves the claimed window unproven and is also a FAIL.
st_helper_dies_after_ready() {
	derive_map_surface_verdict yes failed 5 yes no 5 "" no yes
	if [ "$MAP_SURFACE_VERDICT" != FAIL ]; then
		echo "  a dead helper on the pin surface must not PASS, got $MAP_SURFACE_VERDICT"
		return 1
	fi
	derive_map_surface_verdict yes failed 5 yes no 5 "" no no
	if [ "$MAP_SURFACE_VERDICT" != FAIL ]; then
		echo "  a helper that died before the release signal must FAIL, got $MAP_SURFACE_VERDICT"
		return 1
	fi
	return 0
}

# Point 3. Teardown exceeded the hold: the helper released on its own before
# the caller published the release signal. That is the same fault on either
# contract -- the window was never covered.
st_teardown_exceeds_the_hold() {
	derive_map_surface_verdict yes ok 5 yes yes 5 5 yes yes
	if [ "$MAP_SURFACE_VERDICT" != FAIL ]; then
		echo "  a hold that ended before teardown must FAIL, got $MAP_SURFACE_VERDICT"
		return 1
	fi
	derive_map_surface_verdict yes ok 1 yes yes 1 1 yes no
	if [ "$MAP_SURFACE_VERDICT" != FAIL ]; then
		echo "  a sysfs hold that ended before teardown must FAIL too, got $MAP_SURFACE_VERDICT"
		return 1
	fi
	return 0
}

# Point 3. Both paths stayed alive until the caller released them, and both
# were still readable afterwards. That is the full outcome on either contract.
st_both_paths_alive_until_release() {
	derive_map_surface_verdict yes ok 5 yes no 5 5 yes yes
	if [ "$MAP_SURFACE_VERDICT" != PASS ]; then
		echo "  a hold that spanned teardown must PASS, got $MAP_SURFACE_VERDICT ($MAP_SURFACE_WHY)"
		return 1
	fi
	derive_map_surface_verdict yes ok 1 yes no 1 1 yes no
	if [ "$MAP_SURFACE_VERDICT" != PASS ]; then
		echo "  the sysfs ring hold must PASS too, got $MAP_SURFACE_VERDICT ($MAP_SURFACE_WHY)"
		return 1
	fi
	return 0
}

# Point 3. The post-hold reads must cover every held map when the surface
# promises to stay readable. A read that never happened is not evidence the
# mapping survived; a read that covered only part of the maps is a fault.
st_post_teardown_reads_cover_held_maps() {
	derive_map_surface_verdict yes ok 5 yes no 5 3 yes yes
	if [ "$MAP_SURFACE_VERDICT" != FAIL ]; then
		echo "  partial post-teardown coverage must FAIL on the pin surface, got $MAP_SURFACE_VERDICT"
		return 1
	fi
	derive_map_surface_verdict yes ok 5 yes no 5 "" yes yes
	if [ "$MAP_SURFACE_VERDICT" != FAIL ]; then
		echo "  missing post-teardown coverage must FAIL on the pin surface, got $MAP_SURFACE_VERDICT"
		return 1
	fi
	derive_map_surface_verdict yes ok 5 yes no 5 3 yes no
	if [ "$MAP_SURFACE_VERDICT" != FAIL ]; then
		echo "  partial post-hold coverage must FAIL even on the withdraw surface, got $MAP_SURFACE_VERDICT"
		return 1
	fi
	# Excess is as wrong as shortfall. ok=10 on maps=5 is what a shared
	# counter produces when one accumulator is used for both the
	# establishment read and the post-hold read; it is a reporting fault,
	# not extra coverage. The contract is equality, never >=.
	derive_map_surface_verdict yes ok 5 yes no 5 10 yes yes
	if [ "$MAP_SURFACE_VERDICT" != FAIL ]; then
		echo "  excess post-hold reads must FAIL (ok=10 maps=5), got $MAP_SURFACE_VERDICT"
		return 1
	fi
	derive_map_surface_verdict yes ok 5 yes no 5 10 yes no
	if [ "$MAP_SURFACE_VERDICT" != FAIL ]; then
		echo "  excess post-hold reads must FAIL on the withdraw surface too, got $MAP_SURFACE_VERDICT"
		return 1
	fi
	return 0
}

# The outcome drill 37170656270 produced on both legs: the sysfs "ring" map
# was live at establishment, the hold reached the release signal, and the
# post-hold read faulted because hv_remove_ring_sysfs() had already zapped
# the PTEs -- it runs before vmbus_free_ring(). That is the mapping being
# withdrawn at node removal, the surface's own lifetime, not a mapping
# freed under an active VMA. It must PASS on the withdraw contract and must
# still FAIL on the pin contract, where the pages are promised to hold.
st_withdrawn_at_node_removal_is_pass() {
	derive_map_surface_verdict yes failed 1 yes no 1 "" yes no
	if [ "$MAP_SURFACE_VERDICT" != PASS ]; then
		echo "  withdrawal at node removal must PASS on the withdraw contract, got $MAP_SURFACE_VERDICT ($MAP_SURFACE_WHY)"
		return 1
	fi
	derive_map_surface_verdict yes failed 5 yes no 5 "" yes yes
	if [ "$MAP_SURFACE_VERDICT" != FAIL ]; then
		echo "  the pin surface must not accept a dead helper, got $MAP_SURFACE_VERDICT"
		return 1
	fi
	return 0
}

# A helper that dies inside the hold window never prints release_wait. The
# window it claimed is then unproven, and no amount of establishment liveness
# can substitute for it -- that is the measurement hole this protocol closes.
st_death_before_release_is_fail() {
	derive_map_surface_verdict yes failed 1 yes no 1 "" no no
	if [ "$MAP_SURFACE_VERDICT" != FAIL ]; then
		echo "  death before the release signal must FAIL on the withdraw contract, got $MAP_SURFACE_VERDICT ($MAP_SURFACE_WHY)"
		return 1
	fi
	derive_map_surface_verdict yes failed 5 yes no 5 "" no yes
	if [ "$MAP_SURFACE_VERDICT" != FAIL ]; then
		echo "  death before the release signal must FAIL on the pin contract, got $MAP_SURFACE_VERDICT"
		return 1
	fi
	derive_map_surface_verdict yes ok 1 yes no 1 1 no no
	if [ "$MAP_SURFACE_VERDICT" != FAIL ]; then
		echo "  an unproven hold window must FAIL even with a live helper, got $MAP_SURFACE_VERDICT ($MAP_SURFACE_WHY)"
		return 1
	fi
	return 0
}

# The two reads are different questions and the scrapers must not collapse
# them. A scraper that takes whichever ok= it saw last would report the
# establishment read as if it were the post-teardown one, and a surface that
# withdrew at node removal would look like it sustained. This fixture pins
# the emit strings the helper actually prints against the scrapers.
st_touch_scrapers_separate_ready_from_after() {
	cat >"$LOG" <<'LOGE'
MMAP_HOLD path=/dev/uio0 bytes=4096 maps=5 hold=8
MMAP_HOLD touch_ready path=/dev/uio0 ok=5 fail=0 maps=5
MMAP_HOLD release_wait path=/dev/uio0 waited_ms=200 cap_ms=60000
MMAP_HOLD touch path=/dev/uio0 ok=5 fail=0 maps=5
MMAP_HOLD released path=/dev/uio0 maps=5
LOGE
	_r="$(hold_touch_ready /dev/uio0)"
	_a="$(hold_touch_after /dev/uio0)"
	_w="$(hold_release_waited /dev/uio0)"
	if [ "$_r" != 5 ] || [ "$_a" != 5 ] || [ "$_w" != yes ]; then
		echo "  UIO scrape mismatch: ready=$_r after=$_a waited=$_w (want 5 5 yes)"
		return 1
	fi
	# The withdraw shape: establishment read is there, the post-hold read
	# never lands because the helper faulted on it.
	cat >"$LOG" <<'LOGE'
MMAP_HOLD path=/sys/devices/1/ring bytes=2097152 maps=1 hold=60
MMAP_HOLD touch_ready path=/sys/devices/1/ring ok=1 fail=0 maps=1
MMAP_HOLD release_wait path=/sys/devices/1/ring waited_ms=200 cap_ms=60000
LOGE
	_r="$(hold_touch_ready /sys/devices/1/ring)"
	_a="$(hold_touch_after /sys/devices/1/ring)"
	_w="$(hold_release_waited /sys/devices/1/ring)"
	if [ "$_r" != 1 ]; then
		echo "  ring touch_ready lost, got '${_r}'"
		return 1
	fi
	if [ -n "$_a" ]; then
		echo "  a missing post-hold read must stay empty, got '$_a' (the scrapers conflated the two reads)"
		return 1
	fi
	if [ "$_w" != yes ]; then
		echo "  release_wait not seen, got '${_w}'"
		return 1
	fi
	return 0
}

# Aggregate conjunction, carried forward: a FAIL anywhere is a FAIL, and a
# skipped surface is never folded into PASS.
st_aggregate_is_an_explicit_conjunction() {
	CLEANUP_VERDICT=PASS
	MAP_UIO_VERDICT=PASS
	MAP_SYSFS_VERDICT=FAIL
	MAP_ACCOUNTING_VERDICT=PASS
	RESTORE_VERDICT=FAIL
	derive_aggregate
	if [ "$LIFE" != FAIL ] || [ "$LIFE_CODE" -ne 1 ]; then
		echo "  expected FAIL/1, got $LIFE/$LIFE_CODE"
		return 1
	fi
	MAP_SYSFS_VERDICT=SKIP
	RESTORE_VERDICT=PASS
	derive_aggregate
	if [ "$LIFE" != PARTIAL ] || [ "$LIFE_CODE" -ne 3 ]; then
		echo "  expected PARTIAL/3 for a skipped surface, got $LIFE/$LIFE_CODE"
		return 1
	fi
	return 0
}

# Band refusals, carried forward from the register's counterexamples.
st_band_refuses_growth_and_overfree() {
	if tuple_within_end_band "999 999999999 99999" "7 307200 68" "12 20279296 4939" no >/dev/null; then
		echo "  growth above the boot baseline was accepted"
		return 1
	fi
	if tuple_within_end_band "3 1000 10" "7 307200 68" "12 20279296 4939" no >/dev/null; then
		echo "  an over-free below the settled pre-UIO tuple was accepted"
		return 1
	fi
	if tuple_within_end_band "20 60000000 14000" "7 307200 68" "12 20279296 4939" no >/dev/null; then
		echo "  a ring retention over budget was accepted"
		return 1
	fi
	return 0
}

run_self_test() {
	echo "scope: synthetic validator fixtures, not reproduced kernel leaks."
	for _f in \
		st_rebind_no_is_not_device_restore_pass \
		st_duplicate_known_size_is_not_owner_identity \
		st_known_size_with_unexpected_multiplicity_is_not_complete_pass \
		st_replacement_owner_same_size_is_not_complete_pass \
		st_unknown_64k_retention_is_refused \
		st_first_helper_releases_before_second_ready \
		st_helper_dies_after_ready \
		st_teardown_exceeds_the_hold \
		st_both_paths_alive_until_release \
		st_post_teardown_reads_cover_held_maps \
		st_withdrawn_at_node_removal_is_pass \
		st_death_before_release_is_fail \
		st_touch_scrapers_separate_ready_from_after \
		st_aggregate_is_an_explicit_conjunction \
		st_band_refuses_growth_and_overfree; do
		if "$_f"; then
			st_ok "$_f"
		else
			st_no "$_f"
		fi
	done
	echo "self-test: $ST_PASS passed, $ST_FAIL failed"
	rm -f "$LOG" "$LOG.knownc" "$LOG.known1" "$LOG.after"
	if [ "$ST_FAIL" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

if [ "$SELF_TEST" -eq 1 ]; then
	run_self_test
fi

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
	CLEANUP_VERDICT=PARTIAL
	CLEANUP_WHY="pre-UIO tuple did not settle (instant='$PRE_UIO_INSTANT' last='$PRE_UIO_MAPS' run=$PRE_UIO_RUN)"
	MAP_ACCOUNTING_VERDICT=PARTIAL
	MAP_ACCOUNTING_WHY="the expected end tuple is unreadable while the unbind is still freeing"
	RESTORE_VERDICT=SKIP
	RESTORE_WHY="not reached (phase 2 teardown has not run)"
	say "  instant='$PRE_UIO_INSTANT'"
	say "  last='$PRE_UIO_MAPS' run=$PRE_UIO_RUN"
	LIFE=PARTIAL
	LIFE_CODE=3
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

# mmap-hold must run CONCURRENTLY with the teardown. Running it in the
# foreground mapped, held, released, and only then let restore_nic run --
# the mapping was already gone when the ring was freed, so the BUG-3 window
# was never open and a green run proved nothing about mmap-versus-release.
#
# A fixed sleep cannot span a teardown it does not know about. Each helper
# is therefore given a release file: it holds until that path exists, or
# until HOLD_CAP_S elapses as a hard cap, whichever comes first. This run
# writes the release files only after restore_nic returns, so the mappings
# are alive for the whole window by construction rather than by luck. The
# cap bounds the guest; the release file bounds the window.
#
# Two surfaces, two helpers, two verdicts. A sysfs ring map that never
# opened is not cured by a UIO map that did, and the reverse. Each helper
# publishes its own READY line (MMAP_HOLD path=... maps=N) after the maps
# exist and before the hold, and its RELEASE line (MMAP_HOLD released
# path=... maps=N) after munmap. Those are the barriers. A blind sleep is
# not: it scores a closed window as open whenever the helper is slower than
# the nap, and a READY line whose RELEASE has already landed is history,
# not an active hold.
HOLD_PID_UIO=""
HOLD_PID_RING=""
UIO_MAPS_HELD=0
RING_MAPS_HELD=0
UIO_HOLD_STATUS=absent
RING_HOLD_STATUS=absent
UIO_TOUCH_READY=""
RING_TOUCH_READY=""
UIO_TOUCH_AFTER=""
RING_TOUCH_AFTER=""
UIO_WAITED=no
RING_WAITED=no
UIO_RELEASED_EARLY=no
RING_RELEASED_EARLY=no
HOLD_CAP_S=60
RELEASE_UIO="$LOG.release-uio"
RELEASE_RING="$LOG.release-ring"
rm -f "$RELEASE_UIO" "$RELEASE_RING"

if [ -n "$UIO_DEV" ] && [ -e "$UIO_DEV" ] && [ -n "$HELPER" ]; then
	say "PHASE2 mmap all maps of $UIO_DEV (held across teardown)"
	# UIO map N lives at offset N * pagesize. 8 maps of 4 KiB covers every
	# map the driver advertises.
	"$HELPER" mmap-hold "$UIO_DEV" 4096 "$HOLD_CAP_S" 8 "$RELEASE_UIO" >>"$LOG" 2>&1 &
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
		"$HELPER" mmap-hold "$RING" 2097152 "$HOLD_CAP_S" 1 "$RELEASE_RING" >>"$LOG" 2>&1 &
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

# Snapshot the sizes the teardown is allowed to leave behind, before it
# runs. This is the SIZE-CLASS ledger, not an owner ledger: /proc/vmallocinfo
# names the allocating symbol for every one of these, so one kernel owner
# cannot be told from another. What can be told is whether the end holds
# more of a size class than any prior state did, with multiplicity.
: >"$LOG.sizes-before"
vmbus_map_sizes >>"$LOG.sizes-before" 2>/dev/null || true

say "=== PHASE 2 teardown while maps held (BUG-3 window) ==="
PHASE2_MAPS="$(vmbus_maps || echo 'MAPS unavailable')"
say "PHASE2-BEFORE-TEARDOWN $PHASE2_MAPS"
restore_nic
say "PHASE2-AFTER-TEARDOWN $(vmbus_maps || echo 'MAPS unavailable')"

# The hold ends now, and only now. If a helper already released on its own,
# its maps were gone before this point and the surface did not span the
# window it would otherwise claim. Record that rather than discovering it
# from a READY line that outlived its hold.
if [ -n "$HOLD_PID_UIO" ] && hold_already_released "$UIO_DEV"; then
	UIO_RELEASED_EARLY=yes
	say "RELEASE UIO early: hold ended before the teardown completed"
fi
if [ -n "$HOLD_PID_RING" ] && hold_already_released "$RING"; then
	RING_RELEASED_EARLY=yes
	say "RELEASE SYSFS early: hold ended before the teardown completed"
fi
: >"$RELEASE_UIO" 2>/dev/null || true
: >"$RELEASE_RING" 2>/dev/null || true
say "RELEASE signal published (post-teardown)"

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

UIO_TOUCH_READY="$(hold_touch_ready "$UIO_DEV" || true)"
RING_TOUCH_READY="$(hold_touch_ready "$RING" || true)"
UIO_TOUCH_AFTER="$(hold_touch_after "$UIO_DEV" || true)"
RING_TOUCH_AFTER="$(hold_touch_after "$RING" || true)"
UIO_WAITED="$(hold_release_waited "$UIO_DEV" || true)"
RING_WAITED="$(hold_release_waited "$RING" || true)"
say "TOUCH UIO ready=${UIO_TOUCH_READY:-none} after=${UIO_TOUCH_AFTER:-none} maps=$UIO_MAPS_HELD waited=${UIO_WAITED:-no}"
say "TOUCH SYSFS ready=${RING_TOUCH_READY:-none} after=${RING_TOUCH_AFTER:-none} maps=$RING_MAPS_HELD waited=${RING_WAITED:-no}"

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
BASE_TUPLE="$(maps_tuple "$BASE_MAPS")" || BASE_TUPLE=""
PRE_TUPLE="$(maps_tuple "${PRE_UIO_MAPS:-}")" || PRE_TUPLE=""
if [ -z "$BASE_TUPLE" ] || [ -z "$PRE_TUPLE" ]; then
	CLEANUP_VERDICT=PARTIAL
	CLEANUP_WHY="map accounting unavailable, release unprovable"
	MAP_ACCOUNTING_VERDICT=PARTIAL
	MAP_ACCOUNTING_WHY="a phase-2 verdict needs the boot tuple and the tuple phase 2 started from"
	derive_restore_verdict "${REBIND_OK:-no}"
	say "  baseline='$BASE_MAPS'"
	say "  pre_uio='${PRE_UIO_MAPS:-}'"
	say "  final='$FINAL_MAPS'"
	derive_aggregate
	emit_verdicts_and_exit "$LIFE_CODE"
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
		CLEANUP_VERDICT=FAIL
		CLEANUP_WHY="the unbind grew the accounting (baseline=$BASE_TUPLE pre_uio=$PRE_TUPLE); not a reachable end state"
		MAP_ACCOUNTING_VERDICT=FAIL
		MAP_ACCOUNTING_WHY="pre-UIO tuple exceeds the boot baseline"
		derive_restore_verdict "${REBIND_OK:-no}"
		say "  baseline=$BASE_TUPLE"
		say "  pre_uio=$PRE_TUPLE"
		say "  the unbind grew the accounting; that is not a reachable end state"
		derive_aggregate
		emit_verdicts_and_exit "$LIFE_CODE"
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

# Size-class ledger, with multiplicity. Anything the end holds more of than
# any prior state showed, or of a class no prior state ever held, is a
# retention this run cannot attribute. Set membership is not enough: a
# second map of a size that was already known is exactly the retention a
# size-only match accepts, and two 65536-byte areas are two areas.
: >"$LOG.sizes-after"
vmbus_map_sizes >>"$LOG.sizes-after" 2>/dev/null || true
UNKNOWN_SIZES=""
if [ -s "$LOG.sizes-before" ] && [ -s "$LOG.sizes-base" ]; then
	size_class_max_counts "$LOG.sizes-base" "$LOG.sizes-before" >"$LOG.sizes-known" 2>/dev/null || true
	if [ -s "$LOG.sizes-after" ] && [ -s "$LOG.sizes-known" ]; then
		UNKNOWN_SIZES="$(sizes_excess_after "$LOG.sizes-known" "$LOG.sizes-after" || true)"
	fi
elif [ -s "$LOG.sizes-before" ]; then
	size_class_max_counts "$LOG.sizes-before" >"$LOG.sizes-known" 2>/dev/null || true
	if [ -s "$LOG.sizes-after" ] && [ -s "$LOG.sizes-known" ]; then
		UNKNOWN_SIZES="$(sizes_excess_after "$LOG.sizes-known" "$LOG.sizes-after" || true)"
	fi
elif [ -s "$LOG.sizes-after" ]; then
	# No prior ledger: every retained class is unattributed, with its count.
	UNKNOWN_SIZES="$(awk '{ c[$1]++ } END { for (s in c) printf "%s new x%d\n", s, c[s] }' "$LOG.sizes-after")"
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
# ack, its own exit status, its own early-release check and its own
# post-teardown read count. One path's success is not the other's.
# UIO sustain=yes: hv_uio_pin_vm_ops holds the pin until the VMA closes,
# so the pages must still read after teardown.
derive_map_surface_verdict 	"$([ -n "$HOLD_PID_UIO" ] && echo yes || echo no)" 	"$UIO_HOLD_STATUS" 	"${UIO_MAPS_HELD:-0}" 	"$READY_UIO_PUBLISHED" 	"$UIO_RELEASED_EARLY" 	"${UIO_TOUCH_READY:-}" 	"${UIO_TOUCH_AFTER:-}" 	"${UIO_WAITED:-no}" 	yes
MAP_UIO_VERDICT="$MAP_SURFACE_VERDICT"
MAP_UIO_WHY="$MAP_SURFACE_WHY"

# sysfs sustain=no: kernfs removes the node at teardown and zaps the
# mapping before vmbus_free_ring() runs. The surface never promised to
# outlive its node.
derive_map_surface_verdict 	"$([ -n "$HOLD_PID_RING" ] && echo yes || echo no)" 	"$RING_HOLD_STATUS" 	"${RING_MAPS_HELD:-0}" 	"$READY_RING_PUBLISHED" 	"$RING_RELEASED_EARLY" 	"${RING_TOUCH_READY:-}" 	"${RING_TOUCH_AFTER:-}" 	"${RING_WAITED:-no}" 	no
MAP_SYSFS_VERDICT="$MAP_SURFACE_VERDICT"
MAP_SYSFS_WHY="$MAP_SURFACE_WHY"

# --- MAP_ACCOUNTING_VERDICT -------------------------------------------------
# The end-tuple band and the size-class ledger. Explicitly scoped to what
# map accounting can observe, and it says so: this is size classes with
# multiplicity, never owner identity.
derive_map_accounting_verdict "$SETTLE_TUPLE" "$PRE_TUPLE" "$BASE_TUPLE" 	"${REBIND_OK:-no}" "$UNKNOWN_SIZES"

# --- RESTORE_VERDICT --------------------------------------------------------
# One question only: did the selected NIC come back. Map accounting is the
# verdict above. With rebind=no the device did not return, so this cannot be
# a complete PASS: the hv_uio_remove() gap is pre-existing mainline, it is
# disclosed, and a PARTIAL is the honest reading of a run that proved the
# maps and not the device.
derive_restore_verdict "${REBIND_OK:-no}"

# --- aggregate --------------------------------------------------------------
# PASS requires every verdict to be PASS. A skipped or partial surface makes
# the aggregate PARTIAL, never PASS: a green line that silently omitted a
# mapping path, or that called a non-returning device a restore, is the
# exact failure this scorer exists to refuse.
derive_aggregate

emit_verdicts_and_exit "$LIFE_CODE"
