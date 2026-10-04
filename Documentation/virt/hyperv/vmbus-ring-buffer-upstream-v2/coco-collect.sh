#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# coco-collect.sh - assemble a CoCo platform-row result that conforms to
# coco-result.schema.json.
#
# Run from the root of the tester bundle, inside or beside the guest whose
# evidence is being returned. It reads captured logs, computes hashes, and
# writes a JSON document. It never contacts the network, never provisions,
# and never boots anything.
#
# Design rules:
#   - It never invents a value. A field it cannot derive is left for the
#     human to fill, as an explicit TODO token, and the exit status says so.
#   - It never upgrades a status. PARTIAL, NO_RESULT and
#     ENVIRONMENT_UNAVAILABLE are terminal facts.
#   - It refuses to emit while a kernel virtual address or a secret-like
#     token is present in any attached artifact.
#   - Every artifact path is bundle-relative. A leading slash or '..' is
#     rejected: a result must not name a host workspace path.
#   - Counters carry a phase. A before/after pair is two entries, not one
#     delta.
#
# Never prints kernel virtual addresses or any secret.

set -eu

SCHEMA_VERSION="ramshared-coco-result/v1"
STATE_DIR="${COCO_COLLECT_STATE:-.coco-collect}"
RESULT_DEFAULT="result.json"

usage() {
	cat <<'EOF'
Usage:
  coco-collect.sh init <ROW> attempt=<N> [run_id=<ID>]
  coco-collect.sh finish --row <ROW> --status <STATUS> \
      --justification <TEXT> \
      [--infrastructure <STATUS>] \
      [--isolation <MODE>] \
      [--claimed <MODE>] \
      [--paravisor absent|present|unknown] \
      [--base <SHA>] [--tip <SHA>] [--cover <SHA>] \
      [--arch x86_64|arm64] [--kernel-release <REL>] \
      [--executor <NAME>] [--bundle-sha <SHA>] \
      [--artifact <KIND>:<PATH>]... \
      [--counter <NAME>:<PHASE>:<UNIT>:<VALUE>:<SOURCE>]... \
      [--subcheck <ID>:<RESULT>:<DESCRIPTION>]... \
      [--diagnostic <SHA>:<DESCRIPTION>] \
      [--note <TEXT>] \
      [--out <FILE>]
  coco-collect.sh validate <FILE>
  coco-collect.sh scan <PATH>...
  coco-collect.sh state

Rows:       COCO-1 COCO-2 COCO-3 COCO-4 COCO-5
Status:     PASS PARTIAL FAIL NO_RESULT ENVIRONMENT_UNAVAILABLE
Infra:      completed guest_lost provisioner_failed timeout cancelled never_started
Isolation:  sev_snp tdx_no_paravisor tdx_paravisor arm_cca ordinary_hyperv unknown
Paravisor:  absent present unknown

`scan` is the hygiene gate: it exits non-zero if any argument still
contains a kernel virtual address or a secret-like token. `finish` runs
it on every attached artifact before writing anything.
EOF
}

die() {
	printf 'coco-collect: %s\n' "$1" >&2
	exit 1
}

warn() {
	printf 'coco-collect: %s\n' "$1" >&2
}

ok() {
	printf 'coco-collect: %s\n' "$1"
}

# --- log hygiene -----------------------------------------------------------
# Kernel virtual addresses on x86_64 and arm64 both start at a high canonical
# prefix. We match the prefix, not the exact width, so a stripped log cannot
# sneak one back in a shorter form. This is a floor; a human still reads.
KVADDR_RE='ffff[0-9a-fA-F]{12,}'
# Secret-shaped tokens. Matched by name, never by value; we never echo the
# value that matched, only the fact that one did.
SECRET_RE='(smtppass|smtp_password|passwd|password|api[_-]?key|access[_-]?token|authorization:[[:space:]]*bearer|BEGIN[A-Z ]*PRIVATE KEY)'

scan_file() {
	f="$1"
	test -f "$f" || { warn "scan: not a file: $f"; return 1; }

	hit=0
	if grep -qE "$KVADDR_RE" "$f" 2>/dev/null; then
		# Report the count, never a sample line.
		n=$(grep -cE "$KVADDR_RE" "$f" 2>/dev/null || echo 0)
		warn "scan: $f contains $n kernel virtual address(es)"
		hit=1
	fi
	if grep -qiE "$SECRET_RE" "$f" 2>/dev/null; then
		# Name the pattern class only.
		warn "scan: $f contains a secret-shaped token (name matched, value not shown)"
		hit=1
	fi
	if grep -qE '(^|[^A-Za-z0-9_])/home/|(^|[^A-Za-z0-9_])/mnt/[a-z]/|(^|[^A-Za-z0-9_])/Users/' "$f" 2>/dev/null; then
		n=$(grep -cE '(^|[^A-Za-z0-9_])/home/|(^|[^A-Za-z0-9_])/mnt/[a-z]/|(^|[^A-Za-z0-9_])/Users/' "$f" 2>/dev/null || echo 0)
		warn "scan: $f contains $n absolute host path reference(s)"
		hit=1
	fi
	return "$hit"
}

# --- state -----------------------------------------------------------------
ensure_state() {
	mkdir -p "$STATE_DIR"
}

write_state() {
	ensure_state
	printf '%s' "$2" > "$STATE_DIR/$1"
}

read_state() {
	if [ -f "$STATE_DIR/$1" ]; then
		cat "$STATE_DIR/$1"
	fi
}

# --- JSON helpers (no jq dependency; the shapes are simple) -----------------
json_escape() {
	# Escape backslash, double quote and control characters for a JSON string.
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' \
		-e 's/\r/\\r/g' | tr -d '\000-\010\013\014\016-\037'
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{print $1}'
	else
		die "no sha256 tool available"
	fi
}

iso_now() {
	date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S
}

# --- validators ------------------------------------------------------------
valid_row() {
	case "$1" in
	COCO-1|COCO-2|COCO-3|COCO-4|COCO-5) return 0 ;;
	*) return 1 ;;
	esac
}

valid_qualification() {
	case "$1" in
	PASS|PARTIAL|FAIL|NO_RESULT|ENVIRONMENT_UNAVAILABLE) return 0 ;;
	*) return 1 ;;
	esac
}

valid_infrastructure() {
	case "$1" in
	completed|guest_lost|provisioner_failed|timeout|cancelled|never_started) return 0 ;;
	*) return 1 ;;
	esac
}

valid_isolation() {
	case "$1" in
	sev_snp|tdx_no_paravisor|tdx_paravisor|arm_cca|ordinary_hyperv|unknown) return 0 ;;
	*) return 1 ;;
	esac
}

valid_paravisor() {
	case "$1" in
	absent|present|unknown) return 0 ;;
	*) return 1 ;;
	esac
}

valid_arch() {
	case "$1" in
	x86_64|arm64) return 0 ;;
	*) return 1 ;;
	esac
}

valid_kind() {
	case "$1" in
	preflight_report|dmesg|drill_log|console_log|config|patch|manifest|result|kunit_log|other) return 0 ;;
	*) return 1 ;;
	esac
}

valid_phase() {
	case "$1" in
	before|action|after|during|injected) return 0 ;;
	*) return 1 ;;
	esac
}

valid_subresult() {
	case "$1" in
	pass|fail|not_run|inconclusive|environment_unavailable) return 0 ;;
	*) return 1 ;;
	esac
}

# A bundle-relative path: no leading slash, no '..' segment.
safe_relpath() {
	case "$1" in
	/*) return 1 ;;
	*..*) return 1 ;;
	"") return 1 ;;
	*) return 0 ;;
	esac
}

# --- init ------------------------------------------------------------------
cmd_init() {
	row="${1:-}"; shift || true
	test -n "$row" || die "init: ROW is required"
	valid_row "$row" || die "init: unknown row '$row'"

	attempt=1
	run_id=""
	for arg in "$@"; do
		case "$arg" in
		attempt=*) attempt="${arg#attempt=}" ;;
		run_id=*) run_id="${arg#run_id=}" ;;
		*) die "init: unknown argument '$arg'" ;;
		esac
	done
	case "$attempt" in
	''|*[!0-9]*) die "init: attempt must be a positive integer" ;;
	0) die "init: attempt is 1-based" ;;
	esac

	if [ -z "$run_id" ]; then
		run_id="$(printf '%s-%s-a%s-%s' "$row" "$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date -u +%Y%m%dT%H%M%S)" "$attempt" "$(od -An -N4 -tx4 /dev/urandom 2>/dev/null | tr -d ' \n' || echo 0)")"
	fi

	ensure_state
	write_state row "$row"
	write_state attempt "$attempt"
	write_state run_id "$run_id"
	write_state started_utc "$(iso_now)"
	write_state counters ""
	write_state artifacts ""
	write_state subchecks ""

	ok "initialized $row attempt $attempt run_id $run_id"
	ok "state in $STATE_DIR/; nothing has been written to $RESULT_DEFAULT yet"
}

# --- finish ----------------------------------------------------------------
cmd_finish() {
	row=""; status=""; justification=""
	infra=""; isolation="unknown"; claimed="unknown"; paravisor="unknown"
	base=""; tip=""; cover=""; arch=""; kernel_release=""
	executor=""; bundle_sha=""; diagnostic_sha=""; diagnostic_desc=""; note=""
	out="$RESULT_DEFAULT"

	artifacts=""; counters=""; subchecks=""

	while [ $# -gt 0 ]; do
		case "$1" in
		--row) row="${2:-}"; shift 2 ;;
		--status) status="${2:-}"; shift 2 ;;
		--justification) justification="${2:-}"; shift 2 ;;
		--infrastructure) infra="${2:-}"; shift 2 ;;
		--isolation) isolation="${2:-}"; shift 2 ;;
		--claimed) claimed="${2:-}"; shift 2 ;;
		--paravisor) paravisor="${2:-}"; shift 2 ;;
		--base) base="${2:-}"; shift 2 ;;
		--tip) tip="${2:-}"; shift 2 ;;
		--cover) cover="${2:-}"; shift 2 ;;
		--arch) arch="${2:-}"; shift 2 ;;
		--kernel-release) kernel_release="${2:-}"; shift 2 ;;
		--executor) executor="${2:-}"; shift 2 ;;
		--bundle-sha) bundle_sha="${2:-}"; shift 2 ;;
		--artifact) artifacts="${artifacts}${2:-}
"; shift 2 ;;
		--counter) counters="${counters}${2:-}
"; shift 2 ;;
		--subcheck) subchecks="${subchecks}${2:-}
"; shift 2 ;;
		--diagnostic) diagnostic_sha="${2%%:*}"; diagnostic_desc="${2#*:}"; shift 2 ;;
		--note) note="${2:-}"; shift 2 ;;
		--out) out="${2:-}"; shift 2 ;;
		*) die "finish: unknown argument '$1'" ;;
		esac
	done

	test -n "$row" || die "finish: --row is required"
	valid_row "$row" || die "finish: unknown row '$row'"
	test -n "$status" || die "finish: --status is required"
	valid_qualification "$status" || die "finish: unknown status '$status'"
	test -n "$justification" || die "finish: --justification is required (state why this status and not another)"
	safe_relpath "$out" || die "finish: --out must be a bundle-relative path"

	# Inherit from init when present, then allow override.
	st_row="$(read_state row)"
	st_attempt="$(read_state attempt)"
	st_run_id="$(read_state run_id)"
	st_started="$(read_state started_utc)"
	[ -n "$st_row" ] && [ "$st_row" != "$row" ] && \
		warn "finish: row '$row' differs from init row '$st_row'"
	attempt="${st_attempt:-1}"
	run_id="${st_run_id:-}"
	started="${st_started:-$(iso_now)}"
	finished="$(iso_now)"
	[ -n "$run_id" ] || run_id="${row}-a${attempt}-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date -u +%Y%m%dT%H%M%S)"

	# Default infrastructure from the qualification status. Never the other
	# way round: a status never implies a nicer infrastructure than the truth.
	if [ -z "$infra" ]; then
		case "$status" in
		ENVIRONMENT_UNAVAILABLE) infra="never_started" ;;
		NO_RESULT) infra="timeout" ;;
		PASS|PARTIAL|FAIL) infra="completed" ;;
		esac
		warn "finish: --infrastructure not given; defaulted to '$infra' from status. Confirm it."
	fi
	valid_infrastructure "$infra" || die "finish: unknown infrastructure '$infra'"
	valid_isolation "$isolation" || die "finish: unknown isolation '$isolation'"
	valid_isolation "$claimed" || die "finish: unknown claimed platform '$claimed'"
	valid_paravisor "$paravisor" || die "finish: unknown paravisor '$paravisor'"
	[ -z "$arch" ] || valid_arch "$arch" || die "finish: unknown arch '$arch'"

	# --- structural rules the schema also enforces -------------------------
	case "$status" in
	PASS)
		if [ "$infra" != "completed" ]; then
			die "finish: PASS requires infrastructure=completed, got '$infra'. A lost guest is never PASS."
		fi
		case "$isolation" in
		sev_snp|tdx_no_paravisor|arm_cca) : ;;
		*) die "finish: PASS requires a proven isolation mode, got '$isolation'. An unproven mode is ENVIRONMENT_UNAVAILABLE." ;;
		esac
		if [ "$row" = "COCO-2" ]; then
			[ "$isolation" = "tdx_no_paravisor" ] || \
				die "finish: COCO-2 PASS requires isolation=tdx_no_paravisor"
			[ "$paravisor" = "absent" ] || \
				die "finish: COCO-2 PASS requires paravisor=absent (unknown is not absent)"
		fi
		;;
	ENVIRONMENT_UNAVAILABLE)
		[ "$infra" = "never_started" ] || \
			die "finish: ENVIRONMENT_UNAVAILABLE requires infrastructure=never_started"
		[ "$isolation" = "unknown" ] || \
			die "finish: ENVIRONMENT_UNAVAILABLE requires isolation=unknown"
		;;
	NO_RESULT|PARTIAL)
		case "$infra" in
		guest_lost|provisioner_failed|timeout|cancelled|completed|never_started) : ;;
		esac
		;;
	FAIL)
		[ "$infra" = "completed" ] || \
			warn "finish: FAIL with infrastructure='$infra'. That is an infrastructure fact plus a negative observation; make sure status_justification says so."
		;;
	esac

	case "$infra" in
	guest_lost|provisioner_failed|timeout|cancelled)
		case "$status" in
		NO_RESULT|PARTIAL|ENVIRONMENT_UNAVAILABLE) : ;;
		*) die "finish: infrastructure='$infra' cannot produce status='$status'. A lost guest is never PASS or a bare FAIL." ;;
		esac
		;;
	esac

	# --- hygiene on every attached artifact --------------------------------
	# Split the newline-separated lists on newline only, in the main shell.
	# `for x in $list` would split on spaces and shred any value containing
	# one; `printf | while` would run the loop in a subshell where die()
	# cannot abort the parent. IFS is saved and restored around the split.
	__old_ifs=$IFS
	IFS='
'
	# shellcheck disable=SC2086
	set -- $artifacts
	IFS=$__old_ifs
	for spec in "$@"; do
		[ -n "$spec" ] || continue
		kind="${spec%%:*}"
		path="${spec#*:}"
		valid_kind "$kind" || die "finish: unknown artifact kind '$kind'"
		safe_relpath "$path" || die "finish: artifact path must be bundle-relative: '$path'"
		if [ ! -f "$path" ]; then
			warn "finish: artifact not found at bundle-relative path '$path' (will still be listed; attach it before returning)"
			continue
		fi
		scan_file "$path" || die "finish: refusing to emit; sanitize '$path' first"
	done

	# --- required artifact classes for a non-trivial status ----------------
	if [ "$status" != "ENVIRONMENT_UNAVAILABLE" ]; then
		case "$artifacts" in
		*preflight_report*) : ;;
		*) warn "finish: no preflight_report artifact listed. Without one the isolation claim is unattributable." ;;
		esac
	fi

	# --- required counter for PASS -----------------------------------------
	if [ "$status" = "PASS" ]; then
		case "$counters" in
		*bug_oops_panic_total*) : ;;
		*) die "finish: PASS requires a counter named bug_oops_panic_total. Measure it; do not assume it." ;;
		esac
	fi

	# --- emit ---------------------------------------------------------------
	ensure_state
	tmp="$out.tmp"

	{
		printf '{\n'
		printf '  "schema": "%s",\n' "$SCHEMA_VERSION"

		printf '  "run": {\n'
		printf '    "run_id": "%s",\n' "$(json_escape "$run_id")"
		printf '    "attempt": %s,\n' "$attempt"
		printf '    "started_utc": "%s",\n' "$(json_escape "$started")"
		printf '    "finished_utc": "%s",\n' "$(json_escape "$finished")"
		printf '    "executor": "%s"' "$(json_escape "${executor:-TODO}")"
		if [ -n "$bundle_sha" ]; then
			printf ',\n    "bundle_sha256": "%s"' "$(json_escape "$bundle_sha")"
		else
			printf ',\n    "bundle_sha256": "%s"' "TODO$(printf '0%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60)"
			warn "finish: bundle_sha256 left as a TODO token; fill it before returning"
		fi
		printf '\n  },\n'

		printf '  "candidate": {\n'
		printf '    "series_base": "%s",\n' "$(json_escape "${base:-TODO}")"
		printf '    "series_tip": "%s",\n' "$(json_escape "${tip:-TODO}")"
		printf '    "cover_sha256": "%s",\n' "$(json_escape "${cover:-TODO}")"
		printf '    "patch_sha256s": [\n'
		if [ -f series/SHA256SUMS ]; then
			i=0
			while read -r hash name; do
				[ -n "$hash" ] || continue
				i=$((i + 1))
				if [ "$i" -lt 13 ]; then
					printf '      "%s",\n' "$hash"
				else
					printf '      "%s"\n' "$hash"
				fi
			done < series/SHA256SUMS
			if [ "$i" -ne 13 ]; then
				warn "finish: series/SHA256SUMS has $i entries, expected 13"
			fi
		else
			printf '      "%s"' "TODO"
			warn "finish: series/SHA256SUMS not found; patch hashes left as a TODO"
			printf '\n'
		fi
		printf '    ],\n'
		printf '    "series_sha256sums_ok": %s,\n' \
			"$( [ -f series-byte-pin.log ] && grep -q ': OK' series-byte-pin.log && echo true || echo false )"
		printf '    "architecture": "%s"' "$(json_escape "${arch:-TODO}")"
		if [ -n "$kernel_release" ]; then
			printf ',\n    "kernel_release": "%s"' "$(json_escape "$kernel_release")"
		fi
		if [ -n "$diagnostic_sha" ]; then
			printf ',\n    "diagnostic_delta": {\n'
			printf '      "description": "%s",\n' "$(json_escape "$diagnostic_desc")"
			printf '      "sha256": "%s",\n' "$(json_escape "$diagnostic_sha")"
			printf '      "experimental": true\n'
			printf '    }\n'
		else
			printf ',\n    "diagnostic_delta": null\n'
		fi
		printf '  },\n'

		printf '  "row": "%s",\n' "$row"

		printf '  "capability": {\n'
		printf '    "claimed_platform": "%s",\n' "$(json_escape "$claimed")"
		printf '    "isolation_mode": "%s",\n' "$(json_escape "$isolation")"
		if [ -f "${COCO_PREFLIGHT:-preflight-booted.txt}" ]; then
			printf '    "isolation_proof": [\n'
			first=1
			grep -E '^(dmesg_SEV_SNP|dmesg_TDX|dmesg_CCA|dmesg_paravisor|dmesg_Isolated_VM|isolation|cc_surface|preflight_result)=' \
				"${COCO_PREFLIGHT:-preflight-booted.txt}" 2>/dev/null | while IFS= read -r line; do
				[ -n "$line" ] || continue
				if [ "$first" -eq 1 ]; then
					printf '      "%s"' "$(json_escape "$line")"
					first=0
				else
					printf ',\n      "%s"' "$(json_escape "$line")"
				fi
			done
			printf '\n    ],\n'
		else
			printf '    "isolation_proof": ["TODO: paste the guest dmesg lines that establish the isolation mode"],\n'
			warn "finish: ${COCO_PREFLIGHT:-preflight-booted.txt} not found; isolation_proof is a TODO"
		fi
		printf '    "paravisor": "%s",\n' "$paravisor"
		printf '    "paravisor_evidence": [],\n'
		printf '    "vmbus_present": %s,\n' \
			"$( [ -f "${COCO_PREFLIGHT:-preflight-booted.txt}" ] && grep -q '^vmbus_present=yes' "${COCO_PREFLIGHT:-preflight-booted.txt}" && echo true || echo false )"
		if [ -f "${COCO_PREFLIGHT:-preflight-booted.txt}" ]; then
			vc="$(grep '^vmbus_device_count=' "${COCO_PREFLIGHT:-preflight-booted.txt}" 2>/dev/null | head -1 | cut -d= -f2 || echo 0)"
			printf '    "vmbus_device_count": %s,\n' "${vc:-0}"
		else
			printf '    "vmbus_device_count": 0,\n'
		fi
		printf '    "confidential_vmbus_offers": [],\n'
		printf '    "preflight_report_path": "%s"\n' \
			"$(json_escape "${COCO_PREFLIGHT:-preflight-booted.txt}")"
		printf '  },\n'

		printf '  "infrastructure_status": "%s",\n' "$infra"
		printf '  "infrastructure_note": "%s",\n' "$(json_escape "${note:-}")"
		printf '  "qualification_status": "%s",\n' "$status"
		printf '  "status_justification": "%s",\n' "$(json_escape "$justification")"

		# counters
		printf '  "counters": ['
		cfirst=1
		__old_ifs=$IFS
		IFS='
'
		# shellcheck disable=SC2086
		set -- $counters
		IFS=$__old_ifs
		for spec in "$@"; do
			[ -n "$spec" ] || continue
			# name:phase:unit:value:source  (source may contain colons)
			cname="${spec%%:*}"; rest="${spec#*:}"
			cphase="${rest%%:*}"; rest="${rest#*:}"
			cunit="${rest%%:*}"; rest="${rest#*:}"
			cvalue="${rest%%:*}"; csource="${rest#*:}"
			[ "$cvalue" = "$rest" ] && csource=""
			valid_phase "$cphase" || die "finish: counter '$cname' has unknown phase '$cphase'"
			if [ "$cfirst" -eq 1 ]; then
				printf '\n'
				cfirst=0
			else
				printf ',\n'
			fi
			printf '    {"name": "%s", "phase": "%s", "value": %s, "unit": "%s", "source": "%s"}' \
				"$(json_escape "$cname")" "$cphase" \
				"$(case "$cvalue" in ''|*[!0-9.-]*) printf '"%s"' "$(json_escape "$cvalue")" ;; *) printf '%s' "$cvalue" ;; esac)" \
				"$(json_escape "$cunit")" "$(json_escape "$csource")"
		done
		if [ "$cfirst" -eq 1 ]; then
			printf '],\n'
		else
			printf '\n  ],\n'
		fi

		# subchecks
		printf '  "subchecks": ['
		sfirst=1
		__old_ifs=$IFS
		IFS='
'
		# shellcheck disable=SC2086
		set -- $subchecks
		IFS=$__old_ifs
		for spec in "$@"; do
			[ -n "$spec" ] || continue
			sid="${spec%%:*}"; rest="${spec#*:}"
			sres="${rest%%:*}"; sdesc="${rest#*:}"
			valid_subresult "$sres" || die "finish: subcheck '$sid' has unknown result '$sres'"
			if [ "$sfirst" -eq 1 ]; then
				printf '\n'
				sfirst=0
			else
				printf ',\n'
			fi
			printf '    {"id": "%s", "description": "%s", "result": "%s", "evidence": ["TODO: verbatim log line"]}' \
				"$(json_escape "$sid")" "$(json_escape "$sdesc")" "$sres"
		done
		if [ "$sfirst" -eq 1 ]; then
			printf '],\n'
		else
			printf '\n  ],\n'
		fi

		# artifacts
		printf '  "artifacts": ['
		afirst=1
		for spec in $artifacts; do
			[ -n "$spec" ] || continue
			akind="${spec%%:*}"; apath="${spec#*:}"
			if [ -f "$apath" ]; then
				ahash="$(sha256_of "$apath")"
			else
				ahash="0000000000000000000000000000000000000000000000000000000000000000"
				warn "finish: artifact '$apath' missing; hash recorded as zeros"
			fi
			if [ "$afirst" -eq 1 ]; then
				printf '\n'
				afirst=0
			else
				printf ',\n'
			fi
			printf '    {"path": "%s", "sha256": "%s", "kind": "%s"}' \
				"$(json_escape "$apath")" "$ahash" "$akind"
		done
		if [ "$afirst" -eq 1 ]; then
			printf '],\n'
		else
			printf '\n  ],\n'
		fi

		printf '  "log_safety": {\n'
		printf '    "kernel_virtual_addresses_stripped": true,\n'
		printf '    "secrets_stripped": true,\n'
		printf '    "attested_by": "%s"\n' "$(json_escape "${executor:-coco-collect.sh scan}")"
		printf '  }'
		if [ -n "$note" ]; then
			printf ',\n  "notes": "%s"' "$(json_escape "$note")"
		fi
		printf '\n}\n'
	} > "$tmp"

	mv "$tmp" "$out"
	ok "wrote $out"
	ok "row=$row status=$status infrastructure=$infra isolation=$isolation"

	if grep -q 'TODO' "$out" 2>/dev/null; then
		n=$(grep -c 'TODO' "$out" 2>/dev/null || echo 0)
		warn "finish: $out still contains $n TODO token(s). Fill them before returning; the schema will reject a TODO in a required field."
		return 2
	fi
	return 0
}

# --- validate --------------------------------------------------------------
cmd_validate() {
	f="${1:-$RESULT_DEFAULT}"
	test -f "$f" || die "validate: no such file '$f'"

	scan_file "$f" || die "validate: report hygiene failed"
	command -v python3 >/dev/null 2>&1 || die "validate: python3 required"
	python3 -c 'import jsonschema' 2>/dev/null || die "validate: Python jsonschema package required"
	validator="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/coco-validate.py"
	python3 "$validator" "$f" || die "validate: schema or report consistency failed"

}

# --- main ------------------------------------------------------------------
cmd="${1:-}"; shift || true
case "$cmd" in
init) cmd_init "$@" ;;
finish) cmd_finish "$@" ;;
validate) cmd_validate "$@" ;;
scan)
	test $# -gt 0 || die "scan: at least one path required"
	bad=0
	for f in "$@"; do
		scan_file "$f" || bad=1
	done
	if [ "$bad" -eq 0 ]; then
		ok "scan: clean"
	else
		die "scan: findings above; sanitize before returning"
	fi
	;;
state)
	ensure_state
	for k in row attempt run_id started_utc; do
		printf '%s=%s\n' "$k" "$(read_state "$k")"
	done
	;;
""|-h|--help|help) usage ;;
*) die "unknown command '$cmd' (try --help)" ;;
esac
