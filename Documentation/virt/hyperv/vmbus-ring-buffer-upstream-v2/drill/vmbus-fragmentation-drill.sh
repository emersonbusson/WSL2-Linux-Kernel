#!/usr/bin/env bash
# Guest-side buddy-fragmentation drill for the ring-buffer upstream v2 series.
#
# Breaks high-order contiguity for real (KUnit fault injection is not this
# evidence) and then forces a fresh ring allocation. What that proves depends
# on the guest, and the verdict says which:
#
#   Ordinary x86_64 Hyper-V (this drill's home on a hosted runner):
#     vmbus_alloc_buffer() takes the vzalloc() path, because
#     vmbus_uses_shared_page_chunks() is only true for host-visible buffers in
#     an isolated VM or on ARM64. So the claim here is the historical one --
#     channel open survives buddy fragmentation -- and NOT that the CoCo
#     chunked order-N -> order-0 fallback ran. That path is unreachable on
#     this guest and is covered by KUnit fault injection instead; its runtime
#     proof stays with COCO-1..5.
#
#   Confidential guest (SEV-SNP / TDX / arm64 CCA):
#     the chunked path runs and this same drill is what would exercise the
#     order-7 -> order-0 degrade. That is exactly why COCO is still open.
#
# Runs INSIDE a disposable guest only. It is memory pressure, so it is
# forbidden on the daily WSL2 host and is guarded against it.
#
# Host-safety contract (vmbus-ring-buffer-upstream-v2/SPEC.md): never on the
# daily WSL2 environment. Swap is never activated here.
#
# usage: vmbus-fragmentation-drill.sh [hog_mib] [logfile]
#   hog_mib  ceiling in MiB; default MemTotal. The helper allocates and pins
#            64 KiB chunks, leaving at most 256 measured high-order pages as
#            a safety reserve, then unmaps proven physical buddy pairs.
#
# Depends on vmbus_drill_helper (static, see hyperv-drill-initramfs/) for the
# fragment-buddy primitive. The guest has no CPython and this is a Day-0
# dependency, not a shim.
set -euo pipefail

LOG="${2:-/var/tmp/vmbus-fragmentation-drill.log}"
: >"$LOG"
FRAG_RELEASE="${LOG}.release.$$"
FRAG_PID_FILE="${LOG}.helper.pid"
HOGPID=
HOG_EXIT_STATUS=unknown
FRAG_RESTORE_OK=no
FRAG_RESTORE_SOURCE=unknown
FRAG_SAVED_MAX_MAP_COUNT=
FRAG_SAVED_MIN_FREE_KB=
FRAG_SAVED_BOOST_FACTOR=
NIC=${NIC:-}
TRACE_DIR=/sys/kernel/tracing
OWNER_CHANNEL_IDS_FILE="${LOG}.channels.$$"
OWNER_CHANNEL_COUNT=0
OWNER_TRACE_FROZEN=no
OWNER_TRACE_AVAILABLE=no
OWNER_TRACE_WAS_ENABLED=no
OWNER_TRACE_RESTORED=yes
OWNER_CHANNEL_CAPTURE_OK=no
OWNER_QUIESCE_RESULT=
OWNER_QUIESCE_STATS=
OWNER_POST_OPEN_RESULT=
OWNER_POST_OPEN_STATS=

release_fragment_helper() {
	if [ -n "${HOGPID:-}" ]; then
		: >"$FRAG_RELEASE" 2>/dev/null || kill -TERM "$HOGPID" 2>/dev/null || true
		if wait "$HOGPID" 2>/dev/null; then
			HOG_EXIT_STATUS=0
		else
			HOG_EXIT_STATUS=$?
		fi
		HOGPID=
		rm -f "$FRAG_RELEASE" "$FRAG_PID_FILE" 2>/dev/null || true
	fi
}

HELPER="${HELPER:-$(command -v vmbus_drill_helper || true)}"

# --- guards ------------------------------------------------------------------
guard() {
	if grep -qiE 'microsoft-standard-WSL2' /proc/version 2>/dev/null; then
		echo "REFUSE: daily WSL2 host. Fragmentation pressure is never run here." >&2
		exit 2
	fi
	if [ ! -d /sys/bus/vmbus ]; then
		echo "REFUSE: no VMBus; requires a Hyper-V guest." >&2
		exit 2
	fi
	# Refuse if RamShared cascade is present and active — SPEC forbids changing
	# its lifecycle state, and pressure would interact with it.
	if command -v ramshared >/dev/null 2>&1; then
		if ramshared status 2>/dev/null | grep -qiE 'phase *: *(On|ACTIVE)'; then
			echo "REFUSE: RamShared cascade is active. SPEC forbids host lifecycle change." >&2
			exit 2
		fi
	fi
	if [ -r /proc/swaps ] && [ "$(grep -c . /proc/swaps)" -gt 1 ]; then
		echo "REFUSE: swap is active. This drill never runs with swap." >&2
		exit 2
	fi
}
guard

# Builtins only. After the pattern is built the buddy has no order-2 block
# left for a shell stack -- copy_process wants THREAD_SIZE_ORDER=2 on this
# x86_64 drill kernel -- and a `echo | tee` here is exactly the fork that
# panicked the guest on run 36934739215 ("System is deadlocked on memory").
# ash's echo is a builtin, so this writes the log and the console with zero
# forks.
say() {
	printf '%s\n' "$*" >>"$LOG"
	printf '%s\n' "$*"
}

hog_mib() {
	local total
	# MemTotal, not MemAvailable. The helper treats this as a ceiling the
	# allocation loop must never reach. The loop keeps at most 256 high-order
	# pages after removing at least 99% of the initial order-7-and-higher pages.
	# Passing a share of MemAvailable (the previous default) stopped the loop
	# at the ceiling with untouched order-10 blocks and reported INCONCLUSIVE.
	total="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
	echo "$total"
}

HOGB="${1:-$(hog_mib)}"
say "=== BEGIN vmbus-fragmentation-drill hog_mib=$HOGB ==="
say "kernel=$(uname -r)"
say "MemTotal=$(awk '/MemTotal/{print $2}' /proc/meminfo)kB MemAvailable=$(awk '/MemAvailable/{print $2}' /proc/meminfo)kB"

# --- buddy state before ------------------------------------------------------
buddy() {
	# Same rule as say(): cat|tee forks at the one moment the shell can
	# least afford it. read is a builtin.
	if [ -r /proc/buddyinfo ]; then
		while read -r _bline; do
			printf '%s\n' "$_bline" >>"$LOG"
			printf '%s\n' "$_bline"
		done < /proc/buddyinfo
	else
		say "buddyinfo unavailable"
	fi
}

discover_nic() {
	for _dn_d in /sys/bus/vmbus/drivers/hv_netvsc/*; do
		[ -e "$_dn_d" ] || continue
		_dn_n="${_dn_d##*/}"
		case "$_dn_n" in
		bind | unbind | uevent | module | new_id | remove_id) continue ;;
		esac
		[ -d "$_dn_d" ] || continue
		NIC="$_dn_n"
		return 0
	done
	return 1
}

count_vmbus_maps() {
	MAP_COUNT=0
	if [ -r /proc/vmallocinfo ]; then
		while read -r _vline; do
			case "$_vline" in
			*vmbus_alloc_buffer*) MAP_COUNT=$((MAP_COUNT + 1)) ;;
			esac
		done < /proc/vmallocinfo
	fi
}

capture_owner_channels() {
	_channel_dir="/sys/bus/vmbus/devices/$NIC/channels"
	OWNER_CHANNEL_COUNT=0
	: >"$OWNER_CHANNEL_IDS_FILE" || return 1
	if [ ! -d "$_channel_dir" ]; then
		return 1
	fi
	for _channel_path in "$_channel_dir"/*; do
		[ -d "$_channel_path" ] || continue
		_channel_id="${_channel_path##*/}"
		case "$_channel_id" in
		'' | *[!0-9]*) return 1 ;;
		esac
		printf '%s\n' "$_channel_id" >>"$OWNER_CHANNEL_IDS_FILE" || return 1
		OWNER_CHANNEL_COUNT=$((OWNER_CHANNEL_COUNT + 1))
	done
	[ "$OWNER_CHANNEL_COUNT" -gt 0 ]
}

owner_trace_stats_clean() {
	OWNER_TRACE_STATS=$(awk '
		$1 == "overrun:" { n += $2; cpus++ }
		$1 == "commit" && $2 == "overrun:" { n += $3 }
		$1 == "dropped" && $2 == "events:" { d += $3; dc++ }
		END {
			if (!cpus || cpus != dc || n || d) exit 1
			printf "overruns=%d dropped=%d stats_cpus=%d", n, d, cpus
		}' "$TRACE_DIR"/per_cpu/cpu*/stats 2>/dev/null) || return 1
}

restore_nic_binding() {
	if [ -z "$NIC" ] || [ ! -d /sys/bus/vmbus ]; then
		return 0
	fi
	if [ -d "/sys/bus/vmbus/drivers/hv_netvsc/$NIC" ]; then
		return 0
	fi
	echo "$NIC" >/sys/bus/vmbus/drivers/hv_netvsc/bind 2>>"$LOG" || return 1
	_bind_wait=0
	while [ ! -d "/sys/bus/vmbus/drivers/hv_netvsc/$NIC" ] &&
		[ "$_bind_wait" -lt 10 ]; do
		sleep 1
		_bind_wait=$((_bind_wait + 1))
	done
	[ -d "/sys/bus/vmbus/drivers/hv_netvsc/$NIC" ]
}

fragmentation_exit_cleanup() {
	release_fragment_helper
	rm -f "$OWNER_CHANNEL_IDS_FILE" 2>/dev/null || true
	if ! restore_nic_binding; then
		printf '%s\n' 'FRAGMENT_NIC_RESTORE verified=no' >>"$LOG"
	fi
}
trap fragmentation_exit_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

quiesce_nic_before_pressure() {
	_owner_event_enable=
	_owner_trace_on=
	if [ -z "$NIC" ]; then
		say "FAIL: no NIC identity available before pressure"
		return 1
	fi
	if [ ! -x "$HELPER" ] || [ ! -r "$TRACE_DIR/trace" ]; then
		say "FAIL: trace buffer or static drill helper is unavailable"
		return 1
	fi
	_owner_event_enable=$(cat "$TRACE_DIR/events/hyperv/vmbus_buffer_owner/enable" 2>/dev/null || true)
	_owner_trace_on=$(cat "$TRACE_DIR/tracing_on" 2>/dev/null || true)
	if [ "$_owner_trace_on" = 1 ]; then
		OWNER_TRACE_WAS_ENABLED=yes
	fi
	if [ "$_owner_event_enable" = 1 ] && [ "$_owner_trace_on" = 1 ]; then
		if ! capture_owner_channels; then
			say "FAIL: no channel IDs captured for NIC owner accounting"
			return 1
		fi
		OWNER_TRACE_AVAILABLE=yes
		OWNER_CHANNEL_CAPTURE_OK=yes
		say "OWNER_CHANNELS target_capture=verified channels=$OWNER_CHANNEL_COUNT"
	else
		# The unpatched negative-control kernel has no owner tracepoint. Keep
		# that limitation explicit; the candidate still must prove live owners
		# after the open or its RequirePass policy rejects the run.
		OWNER_TRACE_AVAILABLE=no
		say "OWNER_TRACE_QUIESCE verified=no reason=event-unavailable"
	fi
	_nic_path="/sys/bus/vmbus/drivers/hv_netvsc/$NIC"
	count_vmbus_maps
	PRE_PRESSURE_MAPS=$MAP_COUNT
	if [ -d "$_nic_path" ]; then
		echo "$NIC" >/sys/bus/vmbus/drivers/hv_netvsc/unbind 2>>"$LOG" || return 1
	fi
	_unbind_wait=0
	while [ "$_unbind_wait" -lt 10 ]; do
		count_vmbus_maps
		if [ ! -d "$_nic_path" ] && [ "$OWNER_TRACE_AVAILABLE" = no ]; then
			say "NIC_QUIESCE verified=no reason=owner-trace-unavailable previous_maps=$PRE_PRESSURE_MAPS remaining_maps=$MAP_COUNT"
			return 0
		fi
		if [ ! -d "$_nic_path" ] &&
			[ "$OWNER_TRACE_AVAILABLE" = yes ] &&
			"$HELPER" owner-channel-check "$TRACE_DIR/trace" \
				"$OWNER_CHANNEL_IDS_FILE" reclaimed >/dev/null 2>&1; then
			printf '0\n' >"$TRACE_DIR/tracing_on" 2>>"$LOG" || return 1
			if ! owner_trace_stats_clean; then
				say "NIC_QUIESCE verified=no reason=owner-trace-loss"
				return 1
			fi
			if OWNER_QUIESCE_RESULT=$("$HELPER" owner-channel-check \
				"$TRACE_DIR/trace" "$OWNER_CHANNEL_IDS_FILE" reclaimed 2>&1); then
				OWNER_QUIESCE_STATS=$OWNER_TRACE_STATS
				OWNER_TRACE_FROZEN=yes
				say "$OWNER_QUIESCE_RESULT"
				say "OWNER_TRACE_QUIESCE verified=yes $OWNER_QUIESCE_STATS"
				say "NIC_QUIESCE verified=yes previous_maps=$PRE_PRESSURE_MAPS remaining_maps=$MAP_COUNT target_channels=$OWNER_CHANNEL_COUNT"
				return 0
			fi
			say "$OWNER_QUIESCE_RESULT"
			printf '1\n' >"$TRACE_DIR/tracing_on" 2>>"$LOG" || true
			return 1
		fi
		sleep 1
		_unbind_wait=$((_unbind_wait + 1))
	done
	if [ "$OWNER_TRACE_AVAILABLE" = no ]; then
		say "NIC_QUIESCE verified=no reason=owner-trace-unavailable previous_maps=$PRE_PRESSURE_MAPS remaining_maps=$MAP_COUNT"
		return 1
	fi
	OWNER_QUIESCE_RESULT=$("$HELPER" owner-channel-check "$TRACE_DIR/trace" \
		"$OWNER_CHANNEL_IDS_FILE" reclaimed 2>&1 || true)
	say "$OWNER_QUIESCE_RESULT"
	say "NIC_QUIESCE verified=no previous_maps=$PRE_PRESSURE_MAPS remaining_maps=$MAP_COUNT"
	return 1
}

if [ -z "$NIC" ] && ! discover_nic; then
	say "FAIL: no synthetic NIC bound to hv_netvsc before pressure"
	exit 1
fi
say "NIC=$NIC (captured before pressure unbind)"

if ! quiesce_nic_before_pressure; then
	exit 1
fi
say "--- BUDDY BEFORE PRESSURE ---"
buddy

# --- fragment: break high-order contiguity, leave order-0 available ---------
# A single large mlock hog only splits the buddy as far as it must and leaves
# the untouched remainder as order-10 blocks. fragment-buddy instead removes
# at least 99% of the initial order-7-and-higher pages while retaining at
# most 256 measured high-order pages, then unmaps physical buddy pairs so
# nothing above order-0 can coalesce and the survivors still serve order-0.
say "=== FRAGMENT ${HOGB} MiB as 64 KiB chunks ==="
if [ -z "$HELPER" ]; then
	say "REFUSE: vmbus_drill_helper not found; cannot fragment without fragment-buddy"
	exit 2
fi
# The channel-open exercise and buddy snapshots must finish while the pattern
# is held; the explicit release below ends that hold before lifecycle starts.
#
# Tick source first. read -t on a closed or EOF fd returns immediately, so a
# 180-iteration wait loop would burn through in milliseconds and report the
# pattern missing while the helper is still allocating. init leaves fd 0 alone
# and only redirects 1 and 2, so stdin is already the console; reopen it from
# /dev/console when it is not a tty. exec is a redirection, not a fork, and
# forks are exactly what this section must avoid. The [ -r ] test is load
# bearing: under set -e a failed exec redirection is fatal and `|| true`
# does not catch it in busybox ash, so the path must be proven readable
# before it is opened.
if [ ! -t 0 ] && [ -r /dev/console ]; then
	exec 0</dev/console
fi
# The helper holds the pattern until the shell publishes the release file.
# The 180s cap is a recovery bound if the shell disappears before teardown.
# Its stdin is closed so it cannot race the tick below for console input.
rm -f "$FRAG_RELEASE"
rm -f "$FRAG_PID_FILE"
"$HELPER" fragment-buddy "$HOGB" 180 "$FRAG_RELEASE" "$FRAG_PID_FILE" >>"$LOG" 2>&1 </dev/null &
HOGPID=$!
# Wait for ready=1 using shell builtins only -- no seq, no grep, no
# sleep, no kill. Every fork needs a compound page from the buddy the
# pattern is busy draining, and run 36927495556 w25 lost the shell to
# `page allocation failure: order:1` at exactly that moment, taking the
# console with it: neither ready=1 nor RESULT survived into the
# artifact. The log is the state, so read it with the read builtin and
# use `read -t` as the tick. The harness timeout_sec is the backstop.
FRAG_READY=no
FRAG_STOPPED=no
_ticks=0
while [ "$FRAG_READY" = no ] && [ "$FRAG_STOPPED" = no ] && [ "$_ticks" -lt 180 ]; do
	while read -r _line; do
		case "$_line" in
		*"FRAGMENT_BUDDY ready=1"*) FRAG_READY=yes ;;
		*"FRAGMENT_BUDDY ready=0"*) FRAG_STOPPED=yes ;;
		esac
	done < "$LOG" 2>/dev/null || true
	if [ "$FRAG_READY" = yes ] || [ "$FRAG_STOPPED" = yes ]; then
		break
	fi
	read -t 1 _junk 2>/dev/null || true
	_ticks=$((_ticks + 1))
done
# The helper already wrote its lines to $LOG. Replay every FRAGMENT_BUDDY line
# to the console so the uploaded artifact carries them, and capture the
# decisive ready=1 line, with one builtin read pass. The old `grep | tail | tee`
# was three forks in the window where the buddy holds no order-2 block: that
# is what panicked run 36934739215. Replaying all of them (not just tail -8)
# is a superset of the old evidence -- min_free_kbytes, start, allocated,
# chase, order2_reserve and ready=1 all come through.
FRAG_LINE=
while read -r _line; do
	case "$_line" in
	*"FRAGMENT_BUDDY "*)
		printf '%s\n' "$_line"
		;;
	esac
	case "$_line" in
	*"FRAGMENT_BUDDY ready="*)
		FRAG_LINE="$_line"
		;;
	esac
done < "$LOG" 2>/dev/null || true
if [ "$FRAG_READY" != yes ]; then
	say "FRAGMENT did not reach a ready state"
elif [ -z "$FRAG_LINE" ]; then
	say "FRAGMENT refused to build the pattern (see FRAGMENT_BUDDY line above)"
else
	say "FRAGMENT pattern in place"
fi

say "--- BUDDY AFTER FRAGMENT ---"
buddy

# --- post-ready: builtins only, no fork ---------------------------------
# From here until the helper teardown below there must be zero forks.
# copy_process() wants THREAD_SIZE_ORDER (order-2) for a shell stack, and
# the buddy at this moment has none: every freed page of the pattern is an
# order-0 whose partner is pinned, and the order-2 reserve the helper
# munmap'd landed in the per-cpu page cache -- /proc/buddyinfo does not
# count it and the alloc slowpath will not drain it, because
# drain_all_pages() runs only after direct reclaim makes progress and the
# pattern is all mlocked so it never does. Run 36940519876 read ready=1
# stacks=504 while buddyinfo held 1459*4kB 0*8kB 0*16kB, the first $(sed)
# died with "Killed", init's next clone panicked the guest and both the
# RESULT and VERDICT lines were lost. $(...), pipelines, sed, awk, grep,
# readlink, dmesg and sleep are all forks; parameters, case, read, set --
# and redirections are not.

# Parse `key=value` out of the helper's ready=1 line into $1 (the caller's
# variable name). Values are single tokens; `stop=` carries hyphens and
# `unsplit=` may carry a leading dash, neither of which contains a space.
kv() {
	_kv_rest="${FRAG_LINE#*"$2"}"
	if [ "$_kv_rest" = "$FRAG_LINE" ]; then
		return 1
	fi
	_kv_val="${_kv_rest%% *}"
	_kv_val="${_kv_val%%;*}"
	eval "$1=\$_kv_val"
	return 0
}

HIGH_ORDER_HELPER=
HIGH_ORDER_BLOCKS_BEFORE=
_p="${FRAG_LINE#*high_order_7plus=}"
if [ "$_p" != "$FRAG_LINE" ]; then
	_t="${_p%% *}"
	_t="${_t%%;*}"
	HIGH_ORDER_BLOCKS_BEFORE="${_t%%->*}"
	# _t is before->locked->after; the third value is measured with the
	# pattern pinned and is the authoritative count.
	HIGH_ORDER_HELPER="${_t##*->}"
fi
HIGH_ORDER_PAGES_HELPER=
HIGH_ORDER_PAGES_BEFORE=
_p="${FRAG_LINE#*high_order_7plus_pages=}"
if [ "$_p" != "$FRAG_LINE" ]; then
	_t="${_p%% *}"
	_t="${_t%%;*}"
	HIGH_ORDER_PAGES_BEFORE="${_t%%->*}"
	HIGH_ORDER_PAGES_HELPER="${_t##*->}"
fi
BOUNDED=
kv BOUNDED 'bounded=' || true
CHUNKS_HELPER=
kv CHUNKS_HELPER 'chunks=' || true
EXHAUSTED=
kv EXHAUSTED 'exhausted=' || true
PAGEMAP=
kv PAGEMAP 'pagemap=' || true
STOPREASON=
kv STOPREASON 'stop=' || true
UNSPLIT=
kv UNSPLIT 'unsplit=' || true

# Reread order-7-and-up from buddyinfo. buddyinfo is `Node <n>, zone
# <name>` followed by one count per order, so order-0 is the 5th token and
# order-7 the 12th; drop the four header fields and count from order 7.
HIGH_ORDER=unknown
HIGH_ORDER_PAGES=unknown
if [ -r /proc/buddyinfo ]; then
	HIGH_ORDER=0
	HIGH_ORDER_PAGES=0
	while read -r _bline; do
		set -- $_bline
		shift 4 2>/dev/null || continue
		_ord=0
		for _c in "$@"; do
			if [ "$_ord" -ge 7 ]; then
				case "$_c" in
				'' | *[!0-9]*) ;;
				*)
					HIGH_ORDER=$((HIGH_ORDER + _c))
					HIGH_ORDER_PAGES=$((HIGH_ORDER_PAGES + _c * (1 << _ord)))
					;;
				esac
			fi
			_ord=$((_ord + 1))
		done
	done < /proc/buddyinfo
fi
say "high_order_7plus_blocks_helper=${HIGH_ORDER_HELPER:-unknown} high_order_7plus_pages_helper=${HIGH_ORDER_PAGES_HELPER:-unknown} high_order_7plus_blocks_reread=$HIGH_ORDER high_order_7plus_pages_reread=$HIGH_ORDER_PAGES bounded=${BOUNDED:-unknown}"

read_high_orders() {
	HIGH_ORDER=unknown
	HIGH_ORDER_PAGES=unknown
	BUDDYINFO_VALID=no
	if [ -r /proc/buddyinfo ]; then
		HIGH_ORDER=0
		HIGH_ORDER_PAGES=0
		BUDDYINFO_VALID=yes
		BUDDYINFO_ROWS=0
		while read -r _bline; do
			[ -n "$_bline" ] || continue
			BUDDYINFO_ROWS=$((BUDDYINFO_ROWS + 1))
			set -- $_bline
			if [ "$#" -lt 12 ]; then
				BUDDYINFO_VALID=no
				continue
			fi
			shift 4
			_ord=0
			for _c in "$@"; do
				if [ "$_ord" -ge 7 ]; then
					case "$_c" in
					'' | *[!0-9]*) BUDDYINFO_VALID=no ;;
					*)
						HIGH_ORDER=$((HIGH_ORDER + _c))
						HIGH_ORDER_PAGES=$((HIGH_ORDER_PAGES + _c * (1 << $_ord)))
						;;
					esac
				fi
				_ord=$((_ord + 1))
			done
		done < /proc/buddyinfo
		if [ "$BUDDYINFO_ROWS" -eq 0 ] || [ "$BUDDYINFO_VALID" != yes ]; then
			HIGH_ORDER=unknown
			HIGH_ORDER_PAGES=unknown
		fi
	fi
}

# Reparse strictly before the ring open; malformed or absent telemetry fails closed.
read_high_orders
HIGH_ORDER_REREAD="$HIGH_ORDER"
HIGH_ORDER_PAGES_REREAD="$HIGH_ORDER_PAGES"

# --- exercise channel open under fragmentation ------------------------------
say "=== CHANNEL OPEN UNDER FRAGMENTATION ==="

if [ -z "${NIC:-}" ]; then
	say "REFUSE: synthetic NIC identity was lost before channel reopen"
	release_fragment_helper
	exit 2
fi
DRIVER_DIR="/sys/bus/vmbus/drivers"

count_vmbus_maps
PRE_OPEN_MAP_COUNT=$MAP_COUNT
# /proc/vmallocinfo is global: maps from unrelated VMBus channels remain
# live. The target channel's frozen owner trace is the quiescence gate.
say "PRE-OPEN global_vmbus_maps=$PRE_OPEN_MAP_COUNT target_owner_check=$OWNER_TRACE_FROZEN trace_available=$OWNER_TRACE_AVAILABLE"
if [ "$OWNER_TRACE_AVAILABLE" = yes ] && [ "$OWNER_TRACE_FROZEN" != yes ]; then
	say "VERDICT=FAIL target-channel owners were not proven reclaimed before pressure"
	exit 1
fi

# The old ring was released before pressure. A single bind now forces fresh
# allocations against the held fragmented pattern without freeing old rings.
printf '1\n' >"$TRACE_DIR/tracing_on" 2>>"$LOG" || {
	say "VERDICT=FAIL owner trace could not resume for channel open"
	exit 1
}
OWNER_TRACE_FROZEN=no
echo "$NIC" >"$DRIVER_DIR/hv_netvsc/bind" 2>>"$LOG" || say "rebind_fail"
read -t 2 _junk 2>/dev/null || true

count_vmbus_maps
POST_OPEN_MAP_COUNT=$MAP_COUNT
say "POST-OPEN $POST_OPEN_MAP_COUNT maps"

# Did the NIC come back under hv_netvsc? Test the driver directory with a
# glob instead of readlink -f, which forks.
REBOUND=no
for _d in /sys/bus/vmbus/drivers/hv_netvsc/*; do
	[ "${_d##*/}" = "$NIC" ] && REBOUND=yes
done
say "nic_rebound=$REBOUND"
if [ "$REBOUND" = yes ] && [ "$OWNER_CHANNEL_CAPTURE_OK" = yes ]; then
	say "OWNER_CHANNELS rebound_check=using_pre_unbind_capture channels=$OWNER_CHANNEL_COUNT"
else
	say "OWNER_CHANNELS rebound_check=unavailable"
fi

# --- verdict ----------------------------------------------------------------
# What this drill can and cannot claim on an ordinary x86_64 Hyper-V guest:
#
#   vmbus_alloc_buffer() takes its chunked order-N -> order-0 path only when
#   vmbus_uses_shared_page_chunks() is true, i.e. host-visible buffer AND
#   (Hyper-V isolation OR CONFIG_ARM64). A hosted runner is neither, so every
#   ring here is allocated with vzalloc() and the CoCo chunked fallback is
#   unreachable. It also cannot be forced: that path uses __GFP_NOWARN, so an
#   order-7 failure would not print 'order:7' even where the path ran.
#
#   What IS exercisable here is the historical failure mode: channel open
#   dying under buddy fragmentation (the accept4 110 incidents). The candidate
#   answers that with vzalloc(). So the claim is "fragmentation does not break
#   ring allocation", not "the CoCo order-0 fallback executed".
#
#   The chunked fallback itself is covered by the KUnit fault-injection test
#   in 0005-order-zero-fallback-injection.patch and remains runtime-open on
#   CoCo hardware (COCO-1..5).

# Buddy while the pattern is still pinned, after the channel-open attempt.
# The reread is secondary evidence to the helper's own post-hole measurement.
read_high_orders
HIGH_ORDER_AFTER_CHANNEL="$HIGH_ORDER"
HIGH_ORDER_PAGES_AFTER_CHANNEL="$HIGH_ORDER_PAGES"
say "--- BUDDY FINAL ---"
buddy

# --- teardown hog -----------------------------------------------------------
# The helper must unmap the pressure pattern and restore every changed setting
# before init starts its lifecycle phase. The sentinel is an orderly release;
# wait confirms that the helper completed its own teardown.
release_fragment_helper
while read -r _line; do
	case "$_line" in
	*"FRAGMENT_BUDDY saved_state "*)
		_state="${_line#*saved_state }"
		for _field in $_state; do
			case "$_field" in
			max_map_count=*) FRAG_SAVED_MAX_MAP_COUNT="${_field#*=}" ;;
			min_free_kbytes=*) FRAG_SAVED_MIN_FREE_KB="${_field#*=}" ;;
			watermark_boost_factor=*) FRAG_SAVED_BOOST_FACTOR="${_field#*=}" ;;
			esac
		done
		;;
	*"FRAGMENT_BUDDY teardown "*"restored=yes"*)
		FRAG_RESTORE_OK=yes
		FRAG_RESTORE_SOURCE=helper
		;;
	*"FRAGMENT_BUDDY teardown "*"restored=no"*) FRAG_RESTORE_OK=no ;;
	esac
done < "$LOG"

# If the helper was killed before its cleanup path, its pre-mutation snapshot
# lets this parent restore the global sysctls after wait proves the helper is
# gone. Keep this recovery visible in the evidence and verify every write.
if [ "$FRAG_RESTORE_OK" != yes ] &&
	[ -n "$FRAG_SAVED_MAX_MAP_COUNT" ] &&
	[ -n "$FRAG_SAVED_MIN_FREE_KB" ] &&
	[ -n "$FRAG_SAVED_BOOST_FACTOR" ]; then
	case "$FRAG_SAVED_MAX_MAP_COUNT$FRAG_SAVED_MIN_FREE_KB$FRAG_SAVED_BOOST_FACTOR" in
	'' | *[!0-9]*) ;;
	*)
		printf '%s\n' "$FRAG_SAVED_MAX_MAP_COUNT" >/proc/sys/vm/max_map_count 2>>"$LOG" || true
		printf '%s\n' "$FRAG_SAVED_MIN_FREE_KB" >/proc/sys/vm/min_free_kbytes 2>>"$LOG" || true
		printf '%s\n' "$FRAG_SAVED_BOOST_FACTOR" >/proc/sys/vm/watermark_boost_factor 2>>"$LOG" || true
		FRAG_CURRENT_MAX_MAP_COUNT=unknown
		FRAG_CURRENT_MIN_FREE_KB=unknown
		FRAG_CURRENT_BOOST_FACTOR=unknown
		FRAG_CURRENT_MAX_MAP_COUNT=$(cat /proc/sys/vm/max_map_count 2>/dev/null) || FRAG_CURRENT_MAX_MAP_COUNT=unknown
		FRAG_CURRENT_MIN_FREE_KB=$(cat /proc/sys/vm/min_free_kbytes 2>/dev/null) || FRAG_CURRENT_MIN_FREE_KB=unknown
		FRAG_CURRENT_BOOST_FACTOR=$(cat /proc/sys/vm/watermark_boost_factor 2>/dev/null) || FRAG_CURRENT_BOOST_FACTOR=unknown
		if [ "$FRAG_CURRENT_MAX_MAP_COUNT" = "$FRAG_SAVED_MAX_MAP_COUNT" ] &&
			[ "$FRAG_CURRENT_MIN_FREE_KB" = "$FRAG_SAVED_MIN_FREE_KB" ] &&
			[ "$FRAG_CURRENT_BOOST_FACTOR" = "$FRAG_SAVED_BOOST_FACTOR" ]; then
			FRAG_RESTORE_OK=yes
			FRAG_RESTORE_SOURCE=parent-fallback
			say "FRAGMENT_BUDDY parent_restore max_map_count=$FRAG_CURRENT_MAX_MAP_COUNT min_free_kbytes=$FRAG_CURRENT_MIN_FREE_KB watermark_boost_factor=$FRAG_CURRENT_BOOST_FACTOR verified=yes"
		fi
		;;
	esac
fi

# The parser runs after the pressure helper has exited and restored memory.
# Running it while the pattern is pinned would fork with little order-2
# headroom. The trace records the channel open during the pressure window.
OWNER_POST_OPEN_VERIFIED=no
if printf '0\n' >"$TRACE_DIR/tracing_on" 2>>"$LOG"; then
	OWNER_TRACE_FROZEN=yes
else
	OWNER_TRACE_FROZEN=no
fi
if [ "$REBOUND" = yes ] && [ "$OWNER_CHANNEL_CAPTURE_OK" = yes ] &&
	[ "$OWNER_TRACE_FROZEN" = yes ]; then
	if OWNER_POST_OPEN_RESULT=$("$HELPER" owner-channel-check "$TRACE_DIR/trace" \
		"$OWNER_CHANNEL_IDS_FILE" active 2>&1) && owner_trace_stats_clean; then
		OWNER_POST_OPEN_STATS=$OWNER_TRACE_STATS
		OWNER_POST_OPEN_VERIFIED=yes
		say "$OWNER_POST_OPEN_RESULT"
		say "OWNER_TRACE_POST_OPEN verified=yes $OWNER_POST_OPEN_STATS"
	else
		say "${OWNER_POST_OPEN_RESULT:-OWNER_CHANNEL_CHECK verified=no reason=not-run}"
		say "OWNER_TRACE_POST_OPEN verified=no reason=trace-or-owner-check"
	fi
elif [ "$REBOUND" != yes ]; then
	say "OWNER_TRACE_POST_OPEN verified=no reason=NIC-not-rebound-or-channels-missing"
elif [ "$OWNER_CHANNEL_CAPTURE_OK" != yes ]; then
	say "OWNER_TRACE_POST_OPEN verified=no reason=owner-trace-unavailable"
else
	say "OWNER_TRACE_POST_OPEN verified=no reason=trace-not-frozen"
fi

# The lifecycle drill runs after fragmentation and also needs boot-to-end owner
# capture. Restore tracefs to its original state after taking the stable check.
if [ "$OWNER_TRACE_WAS_ENABLED" = yes ]; then
	if printf '1\n' >"$TRACE_DIR/tracing_on" 2>>"$LOG"; then
		OWNER_TRACE_FROZEN=no
		say "OWNER_TRACE_RESUME verified=yes for=lifecycle"
	else
		OWNER_TRACE_RESTORED=no
		say "OWNER_TRACE_RESUME verified=no for=lifecycle"
	fi
else
	OWNER_TRACE_FROZEN=yes
	say "OWNER_TRACE_RESUME verified=yes prior_state=off"
fi

# --- dmesg scan -------------------------------------------------------------
# After the teardown the buddy is whole again and forks are safe. The scan
# needs dmesg, tail and grep, all binaries. init's HYPERV_DRILL_SPLATS and
# HYPERV_DRILL_FAULTS count the same events independently; this scan is
# what feeds accept4_failures= and oops= on the RESULT line.
say "--- DMESG SCAN ---"
DM="$(dmesg 2>/dev/null | tail -500)"
ORDER7="$(printf '%s\n' "$DM" | grep -c 'order:7' || true)"
ACCEPT="$(printf '%s\n' "$DM" | grep -c 'accept4 failed' || true)"
OOPS="$(printf '%s\n' "$DM" | grep -vF 'Warning: unable to open an initial console.' | grep -ciE 'BUG:|Oops:|WARNING:|hung task|out of memory|oom-kill|kernel panic' || true)"

# exhausted= is the strict raw-count result. Only the bounded ordinary-path
# result is accepted: at least 99% removed, at most 256 measured high-order
# pages kept, and the exact count reread after the channel exercise. Reread both the
# block count and its page size after the hole pattern so neither can grow
# between the helper's sample and the channel-open exercise.
HIGH_ORDER="${HIGH_ORDER_HELPER:-$HIGH_ORDER_REREAD}"
HIGH_ORDER_PAGES="${HIGH_ORDER_PAGES_HELPER:-$HIGH_ORDER_PAGES_REREAD}"
say "RESULT high_order_7plus_blocks=$HIGH_ORDER (after_holes=$HIGH_ORDER_REREAD after_channel=$HIGH_ORDER_AFTER_CHANNEL) high_order_7plus_pages=$HIGH_ORDER_PAGES (after_holes=$HIGH_ORDER_PAGES_REREAD after_channel=$HIGH_ORDER_PAGES_AFTER_CHANNEL) exhausted=${EXHAUSTED:-unknown} bounded=${BOUNDED:-unknown} pagemap=${PAGEMAP:-unknown} unsplit=${UNSPLIT:-unknown} stop=${STOPREASON:-unknown} restore=$FRAG_RESTORE_OK restore_source=$FRAG_RESTORE_SOURCE helper_status=$HOG_EXIT_STATUS order7_dmesg=$ORDER7 accept4_failures=$ACCEPT oops=$OOPS rebind=$REBOUND"

# Exit codes for init:
#   0  PASS            pressure achieved and ring allocation survived it
#   3  INCONCLUSIVE    measurement ran but the test condition was not met
#   1  FAIL            candidate damage, or the channel would not reopen
#   2  REFUSE          guard tripped (see top of file)
RC=0
is_uint() {
	case "$1" in
	'' | *[!0-9]*) return 1 ;;
	*) return 0 ;;
	esac
}
NUMERIC_EVIDENCE=yes
for _number in "$HIGH_ORDER_BLOCKS_BEFORE" "$HIGH_ORDER_PAGES_BEFORE" \
	"$HIGH_ORDER_HELPER" "$HIGH_ORDER_PAGES_HELPER" "$CHUNKS_HELPER" \
	"$HIGH_ORDER_REREAD" "$HIGH_ORDER_PAGES_REREAD" \
	"$HIGH_ORDER_AFTER_CHANNEL" "$HIGH_ORDER_PAGES_AFTER_CHANNEL" \
	"$EXHAUSTED" "$BOUNDED" "$PAGEMAP"; do
	if ! is_uint "$_number"; then
		NUMERIC_EVIDENCE=no
	fi
done
if [ "$FRAG_RESTORE_OK" != yes ]; then
	say "VERDICT=FAIL helper teardown did not prove all changed state restored"
	RC=1
elif [ "$FRAG_READY" = yes ] && [ "$HOG_EXIT_STATUS" != 0 ]; then
	say "VERDICT=FAIL helper exited unsuccessfully after publishing its pattern status=$HOG_EXIT_STATUS"
	RC=1
elif [ "$ACCEPT" -gt 0 ] || [ "$OOPS" -gt 0 ]; then
	say "VERDICT=FAIL accept4=$ACCEPT oops=$OOPS"
	RC=1
elif [ -z "$FRAG_LINE" ]; then
	say "VERDICT=INCONCLUSIVE_NO_PATTERN (fragment-buddy never reported ready=1)"
	RC=3
elif [ "$REBOUND" != yes ]; then
	say "VERDICT=FAIL channel did not rebind after fragmentation"
	RC=1
elif [ "$OWNER_POST_OPEN_VERIFIED" != yes ]; then
	say "VERDICT=FAIL target channel owner was not proven live after fragmented open"
	RC=1
elif [ "$OWNER_TRACE_RESTORED" != yes ]; then
	say "VERDICT=FAIL tracing state could not be restored for lifecycle evidence"
	RC=1
elif [ "$POST_OPEN_MAP_COUNT" -le "$PRE_OPEN_MAP_COUNT" ]; then
	say "VERDICT=FAIL fresh channel open produced no VMBus ring mappings"
	RC=1

elif [ "${PAGEMAP:-0}" != 1 ]; then
	say "VERDICT=INCONCLUSIVE_NO_PAGEMAP (holes were virtual, not physical buddy pairs)"
	RC=3
elif [ "$HIGH_ORDER_HELPER" = 0 ] || [ "$HIGH_ORDER_REREAD" = 0 ] ||
	[ "$HIGH_ORDER_AFTER_CHANNEL" = 0 ]; then
	say "VERDICT=FAIL_UNSAFE_ORDER7_SATURATION (the drill must retain its measured safety block)"
	RC=1
elif [ "$NUMERIC_EVIDENCE" = yes ] && [ "$CHUNKS_HELPER" -gt 0 ] &&
	[ "$HIGH_ORDER_BLOCKS_BEFORE" -gt 0 ] &&
	[ "$HIGH_ORDER_PAGES_BEFORE" -ge 12800 ] && [ "$BOUNDED" = 1 ] &&
	{ [ "$STOPREASON" = chase-memfree-margin ] ||
	  [ "$STOPREASON" = order7-reserve ] ||
	  [ "$STOPREASON" = chase-order7-reserve ]; } &&
	[ "$HIGH_ORDER_HELPER" -gt 0 ] && [ "$HIGH_ORDER_HELPER" -le 2 ] &&
	[ "$HIGH_ORDER_PAGES_HELPER" -le 256 ] &&
	[ "$HIGH_ORDER_REREAD" = "$HIGH_ORDER_HELPER" ] &&
	[ "$HIGH_ORDER_PAGES_REREAD" = "$HIGH_ORDER_PAGES_HELPER" ] &&
	[ "$HIGH_ORDER_REREAD" -le 2 ] && [ "$HIGH_ORDER_PAGES_REREAD" -le 256 ]; then
	if [ "$HIGH_ORDER_AFTER_CHANNEL" -gt "$HIGH_ORDER_HELPER" ] ||
		[ "$HIGH_ORDER_PAGES_AFTER_CHANNEL" -gt "$HIGH_ORDER_PAGES_HELPER" ]; then
		say "VERDICT=INCONCLUSIVE_PATTERN_CHANGED (after_channel=$HIGH_ORDER_PAGES_AFTER_CHANNEL helper=$HIGH_ORDER_PAGES_HELPER)"
		RC=3
	else
		say "VERDICT=PASS_RING_ALLOCATION_UNDER_BOUNDED_FRAGMENTATION"
		say "VERDICT_SCOPE ordinary-x86_64-vzalloc-path; helper_residual_pages=$HIGH_ORDER_PAGES_HELPER after_channel_pages=$HIGH_ORDER_PAGES_AFTER_CHANNEL; high_order_safety_reserve_pages=256; full_saturation=not_proven; CoCo_chunked_fallback=not_proven"
		RC=0
	fi
else
	say "VERDICT=INCONCLUSIVE_PRESSURE_BOUNDARY (exhausted=${EXHAUSTED:-unknown} bounded=${BOUNDED:-unknown} high_order_pages=${HIGH_ORDER_PAGES:-unknown} stop=${STOPREASON:-unknown})"
	RC=3
fi
say "=== END vmbus-fragmentation-drill ==="
say "log=$LOG"
exit "$RC"
