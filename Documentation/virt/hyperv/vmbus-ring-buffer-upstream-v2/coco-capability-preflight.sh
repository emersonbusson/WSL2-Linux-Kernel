#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# coco-capability-preflight.sh - report what isolation mode a guest is
# actually running, before any CoCo verdict is attempted.
#
# Run inside the guest that will host the candidate kernel. Reads only.
# Never provisions, never contacts the network, never changes state.
#
# Output is a key=value report on stdout. Exit 0 always: a missing
# capability is a reported fact, not a script failure. The caller maps
# the report to ENVIRONMENT_UNAVAILABLE / PARTIAL / a named COCO row.
#
# Design rules (plan section 9.1):
#   - A CPU flag alone does not prove absence: a paravisor can filter it.
#   - An unknown mode is unqualified, never "probably fine".
#   - A self-hosted label or cloud SKU name is not proof of capability.
#   - An ordinary nested Hyper-V guest is not confidential just by nesting.
#
# Never prints kernel virtual addresses or any secret.

set -eu

report() {
	printf '%s=%s\n' "$1" "$2"
}

# --- identity -----------------------------------------------------------
report host_name "$(uname -n 2>/dev/null || echo unknown)"
report kernel_release "$(uname -r 2>/dev/null || echo unknown)"
report kernel_version "$(uname -v 2>/dev/null || echo unknown)"
report arch "$(uname -m 2>/dev/null || echo unknown)"
report date_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"

# --- hypervisor / bus ---------------------------------------------------
if [ -d /sys/bus/vmbus ]; then
	report vmbus_present yes
	report vmbus_device_count "$(find /sys/bus/vmbus/devices -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
else
	report vmbus_present no
fi

if [ -r /sys/hypervisor/type ]; then
	report hypervisor_type "$(cat /sys/hypervisor/type 2>/dev/null || echo unknown)"
else
	report hypervisor_type unknown
fi

# --- CPU identity (never a capability proof on its own) ------------------
if [ -r /proc/cpuinfo ]; then
	report cpu_vendor "$(awk -F: '/^vendor_id/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo unknown)"
	report cpu_family "$(awk -F: '/^cpu family/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo unknown)"
	report cpu_model "$(awk -F: '/^model[ \t]/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo unknown)"
	flags="$(awk -F: '/^flags/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || echo '')"
	for f in sev sev_es sev_snp tme tdx; do
		case " $flags " in
		*" $f "*) report "cpu_flag_$f" present ;;
		*) report "cpu_flag_$f" absent ;;
		esac
	done
	# Presence of a flag is weak evidence; absence can be a paravisor filter.
	report cpu_flags_are_definitive no
fi

# --- guest-declared isolation state -------------------------------------
# cc_platform_has() is what the kernel uses; the guest-visible surface for
# it is arch-specific. Probe what exists and say so when nothing does.
found_cc=0
for f in /sys/devices/system/cpu/sev /sys/module/cc_platform/parameters \
	 /sys/kernel/debug/x86/tdx; do
	if [ -e "$f" ]; then
		found_cc=1
		report cc_surface "$(basename "$f")"
	fi
done
if [ "$found_cc" -eq 0 ]; then
	report cc_surface none_visible
fi

# dmesg isolation markers (read-only; no addresses grepped).
if command -v dmesg >/dev/null 2>&1; then
	dm="$(dmesg 2>/dev/null || true)"
	for pat in 'SEV-' 'SEV-ES' 'SEV-SNP' 'TDX' 'CCA' 'Hyper-V isolation' \
		   'paravisor' 'Isolated VM'; do
		if printf '%s\n' "$dm" | grep -q "$pat"; then
			report "dmesg_$(printf '%s' "$pat" | tr -c 'A-Za-z0-9' '_')" present
		else
			report "dmesg_$(printf '%s' "$pat" | tr -c 'A-Za-z0-9' '_')" absent
		fi
	done
else
	report dmesg_readable no
fi

# --- kernel config that the candidate path depends on -------------------
if [ -r /proc/config.gz ]; then
	for opt in CONFIG_HYPERV CONFIG_HYPERV_VMBUS CONFIG_UIO_HV_GENERIC \
		   CONFIG_AMD_MEM_ENCRYPT CONFIG_INTEL_TDX_GUEST \
		   CONFIG_ARM64_CCA_GUEST CONFIG_KUNIT CONFIG_DEBUG_KMEMLEAK; do
		if zcat /proc/config.gz 2>/dev/null | grep -q "^${opt}=y"; then
			report "$opt" y
		elif zcat /proc/config.gz 2>/dev/null | grep -q "^${opt}=m"; then
			report "$opt" m
		elif zcat /proc/config.gz 2>/dev/null | grep -q "^# ${opt} is not set"; then
			report "$opt" n
		else
			report "$opt" unknown
		fi
	done
else
	report proc_config_gz unreadable
fi

# --- the allocation path that would actually run ------------------------
# vmbus_needs_shared_pages() is !confidential && (hv_isolation ||
# cc_platform_has(CC_ATTR_GUEST_MEM_ENCRYPT)). This probe cannot evaluate
# that predicate from userspace. It reports the inputs it can see and
# names the predicate so the caller never guesses.
report shared_pages_predicate 'vmbus_needs_shared_pages(!confidential && (hv_isolation || guest_mem_encrypted))'
report predicate_evaluable_from_userspace no

# --- verdict mapping, explicit -----------------------------------------
# The caller must not promote this report to a COCO row on its own. Print
# the mapping so a human reading the log sees the rule.
report verdict_mapping 'coconut_row_requires_measured_transition;this_report_only_describes_the_environment'
report isolation_mode_confirmed no

# The one thing this script can conclude: whether the environment is even
# a candidate. Everything else is the drill's job.
if [ -d /sys/bus/vmbus ]; then
	report preflight_result VMBUS_PRESENT_MODE_UNKNOWN
else
	report preflight_result NO_VMBUS_UNUSABLE
fi

exit 0
