// SPDX-License-Identifier: GPL-2.0
/*
 * vmbus_drill_helper.c - static helper for the VMBus runtime drills.
 *
 * The drills used to embed python3 heredocs for two primitives: holding a UIO
 * mapping alive while the caller tears the channel down, and locking a large
 * anonymous region to fragment the buddy allocator. A disposable drill guest
 * has no CPython and must not grow one, so both live here as one statically
 * linked binary. This is a Day-0 replacement, not a shim: the drills take a
 * single dependency and the initramfs stays free of an interpreter.
 *
 * Usage:
 *   vmbus_drill_helper mmap-hold <path> <bytes> <hold_seconds> [count] [release_file]
 *   vmbus_drill_helper mlock-hog <mib> <hold_seconds>
 *   vmbus_drill_helper fragment-buddy <mib> <hold_seconds> [release_file] [pid_file]
 *
 * mmap-hold maps <count> regions of <bytes> at sequential page-aligned
 * offsets and keeps them alive. UIO map N lives at offset N * pagesize, so
 * this is exactly the UIO ABI. Count defaults to 1 and is how the sysfs ring
 * file is mapped whole.
 *
 * The hold is bounded by <hold_seconds> in every case. When <release_file>
 * is given it is the explicit release signal: the mappings are released the
 * moment that path exists, or when <hold_seconds> elapses as a hard cap,
 * whichever comes first. That is what lets the caller keep the maps alive
 * across a teardown it controls and release them only afterwards. Without a
 * release file the hold is a plain sleep of <hold_seconds>, which cannot
 * prove the maps were still alive when the caller's teardown ran.
 *
 * mlock-hog allocates <mib> MiB anonymously, populates every page, locks it
 * with mlock(2) and holds for <hold_seconds>. Locked pages resist compaction
 * and drain high-order free blocks. It prints MLOCK_HOG ready=1 only after
 * the lock succeeds.
 *
 * fragment-buddy is the one the order-zero drill actually needs. It takes
 * <mib> as a ceiling the loop must not reach and allocates 64 KiB chunks
 * until at least 99% of initially free order-7-and-higher pages are gone,
 * while retaining at least one order-7 block as a safety reserve. The
 * condition is measured from /proc/buddyinfo, not inferred. It then punches
 * a bounded set of physical buddy holes: one member of every (pfn, pfn^1)
 * pair whose buddy is also ours has its resident backing discarded without
 * splitting the VMA.
 * A freed page's buddy is always held, so nothing above order-0 can
 * coalesce, order-7 cannot reappear, and the survivors still satisfy
 * order-0 fallback. The discarded-page count is capped: the property is
 * what matters, not the density. Earlier munmap-based punches split VMAs
 * and drained the Unmovable slab through vm_area_dup() until out_of_memory()
 * panicked an unkillable guest. The reserve also has to fund reopening
 * hv_netvsc: its default receive buffer is
 * 16 MiB and its send buffer can be 15 MiB. If refine consumes pages from
 * the initial hole reserve, the helper recovers verified order-0 pages from
 * still-mapped locked ranges with MADV_DONTNEED_LOCKED. This does not split
 * VMAs, and each discarded page has a live held buddy. The helper requires
 * at least 64 MiB of measured free memory above the live watermark and an
 * order-2 stack reserve before it pins the pattern or reports ready=1. A
 * smaller reserve fails closed before the channel-open attempt.
 *
 * The loop stops on the measured condition, not on hard refusal, and keeps
 * a real free-memory margin while doing it: pagefault_out_of_memory() only
 * warns and retries the fault, so touching into true exhaustion is how a
 * drill turns into either a hang or -- with an unkillable process -- "System
 * is deadlocked on memory" and a guest panic.
 *
 * Freeing every other virtual chunk does not give that guarantee: adjacent
 * virtual chunks are not necessarily physical buddies, so freed chunks can
 * reassemble into order-7 blocks and the drill reports INCONCLUSIVE. The
 * pagemap PFN check is what makes the claim airtight. It needs
 * CAP_SYS_ADMIN (init runs this inside the disposable guest) and
 * CONFIG_PROC_PAGE_MONITOR (enabled in the drill kernel); without both the
 * pattern cannot be built and this mode fails closed instead of reporting a
 * pattern it never created.
 *
 * The allocation loop also lowers vm.min_free_kbytes and keeps it low
 * through the punch, the chase and the channel-open exercise. The min
 * watermark hides free high-order blocks from userspace faults: buddyinfo
 * still lists them, but a fault cannot cross the reserve to split them, so
 * the loop stops with the test condition unmet however much room the floor
 * leaves. The read-back in the report is the value actually in force, not
 * the value asked for. The helper restores and verifies all three changed
 * global settings and its process OOM score after release, handled signals,
 * and setup errors.
 *
 * The OOM pin is on only while the finished pattern is being held, never
 * while this process is allocating. Both wrong windows have been tried and
 * both are recorded. Pinning the allocation let out_of_memory() find no
 * killable victim once the drill shell had been reclaimed and the guest
 * panicked with "System is deadlocked on memory". Dropping the pin the
 * moment ready=1 printed let the drill shell's next fork reclaim this
 * process instead -- 2 GiB of locked pages came back, the high orders
 * reassembled, and the script measured 356 blocks where the helper had
 * just measured 1. So: allocate, punch and chase with the pin off (a kill
 * there is an honest INCONCLUSIVE_NO_PATTERN and the guest survives), pin
 * once ready=1 has been printed, and hold that pin for the whole hold so
 * the channel-open exercise runs against a pattern that is still in force.
 *
 * Never prints addresses or PFNs. Evidence must not carry KASLR material.
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <unistd.h>

/* Linux 7.3 UAPI; some build hosts ship older userspace headers. */
#ifndef MADV_DONTNEED_LOCKED
#define MADV_DONTNEED_LOCKED 24
#endif

static long parse_long(const char *s, const char *what)
{
	char *end = NULL;
	long v;

	errno = 0;
	v = strtol(s, &end, 10);
	if (errno || end == s || *end != '\0' || v < 0) {
		fprintf(stderr, "HELPER bad %s: '%s'\n", what, s);
		exit(2);
	}
	return v;
}

enum owner_action {
	OWNER_CREATED,
	OWNER_RELEASED,
	OWNER_RETAINED,
	OWNER_RECLAIMED,
	OWNER_DISCARDED,
};

struct owner_event {
	uint64_t owner_id;
	uint64_t channel_id;
	size_t sequence;
	uint32_t size;
	uint32_t pages;
	uint8_t state;
	enum owner_action action;
};

struct owner_check_stats {
	size_t channels;
	size_t events;
	size_t created;
	size_t released;
	size_t retained;
	size_t reclaimed;
	size_t discarded;
	size_t active;
	size_t live;
};

#define OWNER_TRACE_MARKER "vmbus_buffer_owner: "

static int owner_channel_is_target(uint64_t channel_id,
				   const uint64_t *channels,
				   size_t channel_count)
{
	size_t i;

	for (i = 0; i < channel_count; i++) {
		if (channels[i] == channel_id)
			return 1;
	}
	return 0;
}

static int owner_parse_number(const char **cursor, const char *field,
			      uint64_t *value)
{
	char *end;

	if (strncmp(*cursor, field, strlen(field)))
		return -1;
	*cursor += strlen(field);
	if (!isdigit((unsigned char)**cursor))
		return -1;
	errno = 0;
	*value = strtoull(*cursor, &end, 10);
	if (errno || end == *cursor || (*end && !isspace((unsigned char)*end)))
		return -1;
	*cursor = end;
	while (isspace((unsigned char)**cursor))
		(*cursor)++;
	return 0;
}

static int owner_parse_action(const char **cursor, enum owner_action *action)
{
	static const struct {
		const char *name;
		enum owner_action action;
	} actions[] = {
		{ "created", OWNER_CREATED },
		{ "released", OWNER_RELEASED },
		{ "retained", OWNER_RETAINED },
		{ "reclaimed", OWNER_RECLAIMED },
		{ "discarded", OWNER_DISCARDED },
	};
	size_t i, len;

	if (strncmp(*cursor, "action=", 7))
		return -1;
	*cursor += 7;
	for (i = 0; i < sizeof(actions) / sizeof(actions[0]); i++) {
		len = strlen(actions[i].name);
		if (!strncmp(*cursor, actions[i].name, len) &&
		    ((*cursor)[len] == '\0' ||
		     isspace((unsigned char)(*cursor)[len]))) {
			*cursor += len;
			while (isspace((unsigned char)**cursor))
				(*cursor)++;
			*action = actions[i].action;
			return 0;
		}
	}
	return -1;
}

static int owner_parse_trace_line(const char *line, struct owner_event *event)
{
	const char *cursor = strstr(line, OWNER_TRACE_MARKER);
	uint64_t size, pages, state;

	if (!cursor)
		return 0;
	cursor += strlen(OWNER_TRACE_MARKER);
	if (owner_parse_number(&cursor, "owner_id=", &event->owner_id) ||
	    owner_parse_number(&cursor, "channel_id=", &event->channel_id) ||
	    owner_parse_action(&cursor, &event->action) ||
	    owner_parse_number(&cursor, "size=", &size) || size > UINT32_MAX ||
	    owner_parse_number(&cursor, "pages=", &pages) || pages > UINT32_MAX ||
	    owner_parse_number(&cursor, "state=", &state) || state > 7)
		return -1;
	if (!event->owner_id || !event->channel_id)
		return -1;
	event->size = (uint32_t)size;
	event->pages = (uint32_t)pages;
	event->state = (uint8_t)state;
	while (*cursor == '\n' || *cursor == '\r')
		cursor++;
	return *cursor ? -1 : 1;
}

static int owner_event_compare(const void *left, const void *right)
{
	const struct owner_event *a = left;
	const struct owner_event *b = right;

	if (a->owner_id < b->owner_id)
		return -1;
	if (a->owner_id > b->owner_id)
		return 1;
	if (a->sequence < b->sequence)
		return -1;
	if (a->sequence > b->sequence)
		return 1;
	return 0;
}

static int owner_transition_valid(enum owner_action previous,
				  enum owner_action next)
{
	switch (previous) {
	case OWNER_CREATED:
		return next == OWNER_RELEASED || next == OWNER_DISCARDED;
	case OWNER_RELEASED:
		return next == OWNER_RETAINED || next == OWNER_RECLAIMED;
	case OWNER_RETAINED:
		return next == OWNER_RECLAIMED;
	case OWNER_RECLAIMED:
	case OWNER_DISCARDED:
		return 0;
	}
	return 0;
}

static int owner_event_data_valid(const struct owner_event *event)
{
	switch (event->action) {
	case OWNER_CREATED:
		return !event->size && !event->pages && !event->state;
	case OWNER_RELEASED:
		return event->size && event->pages;
	case OWNER_RETAINED:
		return event->size && event->pages && event->state;
	case OWNER_RECLAIMED:
		return event->size && event->pages && !event->state;
	case OWNER_DISCARDED:
		return !event->size && !event->pages && !event->state;
	}
	return 0;
}

/* Validate every target-channel owner and fail closed on incomplete traces. */
static int owner_check_stream(FILE *trace, const uint64_t *channels,
			      size_t channel_count, int require_active,
			      struct owner_check_stats *stats,
			      const char **reason)
{
	struct owner_event *events = NULL;
	size_t capacity = 0, event_count = 0, sequence = 0, i;
	char line[1024];

	memset(stats, 0, sizeof(*stats));
	stats->channels = channel_count;
	if (!channel_count) {
		*reason = "no-target-channels";
		return -1;
	}
	while (fgets(line, sizeof(line), trace)) {
		struct owner_event event = { 0 };
		int parsed = owner_parse_trace_line(line, &event);

		if (parsed < 0) {
			*reason = "malformed-owner-event";
			goto fail;
		}
		if (!parsed)
			continue;
		sequence++;
		if (!owner_channel_is_target(event.channel_id, channels,
					     channel_count))
			continue;
		if (event_count == capacity) {
			size_t next = capacity ? capacity * 2 : 64;
			struct owner_event *grown;

			if (next < capacity || next > SIZE_MAX / sizeof(*events)) {
				*reason = "owner-event-overflow";
				goto fail;
			}
			grown = realloc(events, next * sizeof(*events));
			if (!grown) {
				*reason = "owner-event-allocation-failed";
				goto fail;
			}
			events = grown;
			capacity = next;
		}
		event.sequence = sequence;
		events[event_count++] = event;
	}
	if (ferror(trace)) {
		*reason = "owner-trace-read-failed";
		goto fail;
	}
	if (!event_count) {
		*reason = "no-target-owner-events";
		goto fail;
	}
	qsort(events, event_count, sizeof(*events), owner_event_compare);
	stats->events = event_count;
	for (i = 0; i < event_count;) {
		size_t end = i + 1, j;
		enum owner_action last;
		uint64_t channel_id = events[i].channel_id;

		if (events[i].action != OWNER_CREATED) {
			*reason = "owner-created-event-missing";
			goto fail;
		}
		if (!owner_event_data_valid(&events[i])) {
			*reason = "invalid-owner-created-payload";
			goto fail;
		}
		stats->created++;
		last = OWNER_CREATED;
		while (end < event_count &&
		       events[end].owner_id == events[i].owner_id)
			end++;
		for (j = i + 1; j < end; j++) {
			if (events[j].channel_id != channel_id ||
			    !owner_transition_valid(last, events[j].action) ||
			    !owner_event_data_valid(&events[j])) {
				*reason = "invalid-owner-transition";
				goto fail;
			}
			last = events[j].action;
			switch (last) {
			case OWNER_RELEASED:
				stats->released++;
				break;
			case OWNER_RETAINED:
				break;
			case OWNER_RECLAIMED:
				stats->reclaimed++;
				break;
			case OWNER_DISCARDED:
				stats->discarded++;
				break;
			case OWNER_CREATED:
				*reason = "duplicate-owner-created-event";
				goto fail;
			}
		}
		if (last != OWNER_RECLAIMED && last != OWNER_DISCARDED) {
			stats->active++;
			if (last == OWNER_CREATED)
				stats->live++;
			else if (last == OWNER_RETAINED)
				stats->retained++;
		}
		i = end;
	}
	if ((require_active && (!stats->live || stats->active != stats->live ||
				stats->retained)) ||
	    (!require_active && stats->active)) {
		*reason = require_active ? "no-open-target-owner" :
						  "target-owner-not-reclaimed";
		goto fail;
	}
	free(events);
	return 0;

fail:
	free(events);
	return -1;
}

static int owner_read_channel_ids(const char *path, uint64_t **channels_out,
				  size_t *count_out)
{
	FILE *file;
	uint64_t *channels = NULL;
	size_t count = 0, capacity = 0;
	char line[128];
	int rc = -1;

	file = fopen(path, "r");
	if (!file)
		return -1;
	while (fgets(line, sizeof(line), file)) {
		char *end;
		unsigned long long value;
		size_t i;

		if (!isdigit((unsigned char)line[0]))
			goto out;
		errno = 0;
		value = strtoull(line, &end, 10);
		if (errno || end == line ||
		    (*end != '\n' && *end != '\r' && *end != '\0'))
			goto out;
		for (i = 0; i < count; i++) {
			if (channels[i] == (uint64_t)value)
				goto out;
		}
		if (count == capacity) {
			size_t next = capacity ? capacity * 2 : 8;
			uint64_t *grown;

			if (next < capacity || next > SIZE_MAX / sizeof(*channels))
				goto out;
			grown = realloc(channels, next * sizeof(*channels));
			if (!grown)
				goto out;
			channels = grown;
			capacity = next;
		}
		channels[count++] = (uint64_t)value;
	}
	if (!ferror(file) && count) {
		*channels_out = channels;
		*count_out = count;
		channels = NULL;
		rc = 0;
	}
out:
	free(channels);
	fclose(file);
	return rc;
}

static int do_owner_channel_check(int argc, char **argv)
{
	struct owner_check_stats stats;
	const char *reason = "invalid-arguments";
	uint64_t *channels = NULL;
	size_t channel_count = 0;
	FILE *trace;
	int require_active, rc;

	if (argc != 4 || (strcmp(argv[3], "reclaimed") &&
			   strcmp(argv[3], "active"))) {
		fprintf(stderr, "usage: owner-channel-check <trace> <channel-ids> <reclaimed|active>\n");
		return 2;
	}
	require_active = !strcmp(argv[3], "active");
	if (owner_read_channel_ids(argv[2], &channels, &channel_count)) {
		fprintf(stderr, "OWNER_CHANNEL_CHECK verified=no reason=invalid-channel-file\n");
		return 1;
	}
	trace = fopen(argv[1], "r");
	if (!trace) {
		free(channels);
		fprintf(stderr, "OWNER_CHANNEL_CHECK verified=no reason=trace-unavailable\n");
		return 1;
	}
	rc = owner_check_stream(trace, channels, channel_count, require_active,
				&stats, &reason);
	fclose(trace);
	free(channels);
	if (rc) {
		fprintf(stderr, "OWNER_CHANNEL_CHECK verified=no reason=%s\n", reason);
		return 1;
	}
	printf("OWNER_CHANNEL_CHECK verified=yes mode=%s channels=%zu events=%zu created=%zu released=%zu reclaimed=%zu discarded=%zu retained=%zu active=%zu live=%zu\n",
	       require_active ? "active" : "reclaimed", stats.channels,
	       stats.events, stats.created, stats.released, stats.reclaimed,
	       stats.discarded, stats.retained, stats.active, stats.live);
	return 0;
}

static volatile sig_atomic_t frag_stop_signal;

static void frag_request_stop(int signo)
{
	frag_stop_signal = signo;
}

static int frag_install_signal_handlers(void)
{
	struct sigaction action = { .sa_handler = frag_request_stop };

	sigemptyset(&action.sa_mask);
	return sigaction(SIGTERM, &action, NULL) ||
	       sigaction(SIGHUP, &action, NULL) ||
	       sigaction(SIGINT, &action, NULL) ? -1 : 0;
}

static int frag_release_requested(const char *release_file)
{
	return frag_stop_signal ||
	       (release_file && access(release_file, F_OK) == 0);
}

static int frag_write_pid_file(const char *pid_file)
{
	char buf[32];
	int fd, n, rc = -1;

	if (!pid_file)
		return 0;
	fd = open(pid_file, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
	if (fd < 0)
		return -1;
	n = snprintf(buf, sizeof(buf), "%ld\n", (long)getpid());
	if (n > 0 && write(fd, buf, (size_t)n) == n)
		rc = 0;
	close(fd);
	return rc;
}

static int do_mmap_hold(int argc, char **argv)
{
	const char *path, *release_file = NULL;
	long bytes, hold, count, i, mapped = 0;
	long page, ready_ok = 0, after_ok = 0, waited_ms = 0;
	int fd;
	void **maps;

	if (argc < 4) {
		fprintf(stderr,
			"usage: mmap-hold <path> <bytes> <hold_seconds> [count] [release_file]\n");
		return 2;
	}
	path = argv[1];
	bytes = parse_long(argv[2], "bytes");
	hold = parse_long(argv[3], "hold_seconds");
	count = (argc > 4) ? parse_long(argv[4], "count") : 1;
	if (argc > 5 && argv[5][0] != '\0')
		release_file = argv[5];
	if (release_file && hold <= 0) {
		fprintf(stderr,
			"HELPER release_file requires a positive hold_seconds hard cap\n");
		return 2;
	}

	page = sysconf(_SC_PAGESIZE);
	if (page <= 0)
		page = 4096;
	if (bytes <= 0 || bytes > (64L * 1024 * 1024)) {
		fprintf(stderr, "HELPER bytes out of range\n");
		return 2;
	}
	if (count <= 0 || count > 64) {
		fprintf(stderr, "HELPER count out of range\n");
		return 2;
	}

	/*
	 * MAP_SHARED on an O_RDONLY fd gets VM_SHARED cleared by do_mmap()
	 * (mm/mmap.c: `if (!(file->f_mode & FMODE_WRITE)) vm_flags &=
	 * ~(VM_MAYWRITE | VM_SHARED)`), and hv_uio_mmap_validate() rejects
	 * any mapping without VM_SHARED. Open read-write so the mapping is
	 * actually shared; both the UIO device and the channel "ring" sysfs
	 * attribute are 0600 and writable here.
	 */
	fd = open(path, O_RDWR);
	if (fd < 0) {
		/* stdout: the guest console is the evidence channel */
		printf("HELPER open %s: %s\n", path, strerror(errno));
		fflush(stdout);
		return 1;
	}

	maps = calloc((size_t)count, sizeof(*maps));
	if (!maps) {
		printf("HELPER calloc: %s\n", strerror(errno));
		fflush(stdout);
		close(fd);
		return 1;
	}

	for (i = 0; i < count; i++) {
		off_t off = (off_t)(i * page);
		void *m = mmap(NULL, (size_t)bytes, PROT_READ, MAP_SHARED, fd, off);

		if (m == MAP_FAILED) {
			printf("HELPER mmap %s[%ld] off=%lld: %s\n",
			       path, i, (long long)off, strerror(errno));
			fflush(stdout);
			break;
		}
		maps[i] = m;
		mapped++;
	}

	printf("MMAP_HOLD path=%s bytes=%ld maps=%ld hold=%ld\n",
	       path, bytes, mapped, hold);
	fflush(stdout);

	/*
	 * Liveness at establishment, before any hold. The window this hold
	 * covers is only as real as the mapping is at its start: a map that
	 * is already dead here is not a hold. This is the read taken while
	 * the caller's node still exists; the post-hold read below is a
	 * separate question and is scored per surface.
	 */
	ready_ok = 0;
	for (i = 0; i < mapped; i++) {
		volatile unsigned char *b = maps[i];
		unsigned char v = *b;

		(void)v;
		ready_ok++;
	}
	printf("MMAP_HOLD touch_ready path=%s ok=%ld fail=0 maps=%ld\n",
	       path, ready_ok, mapped);
	fflush(stdout);

	/*
	 * Hold the mappings alive across the caller's teardown. This is the
	 * BUG-3 window: the ring is freed while a userspace mapping still
	 * references it. The unbind races this hold on purpose.
	 *
	 * With a release_file the hold lasts until the caller publishes that
	 * path -- an explicit release it issues after its own teardown -- or
	 * until <hold_seconds> elapses as a hard cap, whichever comes first.
	 * A bounded hold cannot hang the guest; an explicit release cannot
	 * end the window before the teardown it is meant to cover. Without a
	 * release file the hold is the plain sleep, kept for callers that
	 * have no teardown to span.
	 */
	if (release_file) {
		while (waited_ms < hold * 1000L) {
			struct stat st;

			if (stat(release_file, &st) == 0)
				break;
			usleep(100 * 1000);
			waited_ms += 100;
		}
		printf("MMAP_HOLD release_wait path=%s waited_ms=%ld cap_ms=%ld\n",
		       path, waited_ms, hold * 1000L);
		fflush(stdout);
	} else if (hold > 0) {
		sleep((unsigned int)hold);
	}

	/*
	 * Permitted reads of the retained mappings, taken after the hold
	 * window and before munmap. Reads only: nothing is written back to
	 * the device. The read is a probe that the mapping still has a
	 * present page after the caller's teardown. A mapping whose pages
	 * were revoked underneath faults here and takes this process with
	 * it, so the non-zero exit status is the evidence that the hold did
	 * not survive; the scorer already turns that into a FAIL rather than
	 * swallowing it.
	 */
	after_ok = 0;
	for (i = 0; i < mapped; i++) {
		volatile unsigned char *b = maps[i];
		unsigned char v = *b;

		(void)v;
		after_ok++;
	}
	printf("MMAP_HOLD touch path=%s ok=%ld fail=0 maps=%ld\n",
	       path, after_ok, mapped);
	fflush(stdout);

	for (i = 0; i < mapped; i++)
		munmap(maps[i], (size_t)bytes);
	free(maps);
	close(fd);
	/*
	 * The RELEASE line carries the path so the caller can tell which
	 * hold ended. Without it a release is indistinguishable from another
	 * path's READY line and a stale hold is accepted as a live one.
	 */
	printf("MMAP_HOLD released path=%s maps=%ld\n", path, mapped);
	fflush(stdout);
	return mapped > 0 ? 0 : 1;
}

static int do_mlock_hog(int argc, char **argv)
{
	long mib, hold;
	size_t len, off;
	char *buf;

	if (argc < 3) {
		fprintf(stderr, "usage: mlock-hog <mib> <hold_seconds>\n");
		return 2;
	}
	mib = parse_long(argv[1], "mib");
	hold = parse_long(argv[2], "hold_seconds");
	if (mib <= 0 || mib > (long)(16 * 1024)) {
		fprintf(stderr, "HELPER mib out of range\n");
		return 2;
	}

	len = (size_t)mib * 1024UL * 1024UL;
	buf = mmap(NULL, len, PROT_READ | PROT_WRITE,
		   MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
	if (buf == MAP_FAILED) {
		fprintf(stderr, "HELPER mmap %ld MiB: %s\n",
			mib, strerror(errno));
		return 1;
	}

	/* Touch every page so none of it stays unpopulated and lazily faulted. */
	for (off = 0; off < len; off += 4096)
		buf[off] = 1;

	if (mlock(buf, len) != 0) {
		fprintf(stderr, "HELPER mlock: %s\n", strerror(errno));
		munmap(buf, len);
		return 1;
	}

	printf("MLOCK_HOG ready=1 mib=%ld\n", mib);
	fflush(stdout);

	if (hold > 0)
		sleep((unsigned int)hold);

	munlock(buf, len);
	munmap(buf, len);
	printf("MLOCK_HOG released mib=%ld\n", mib);
	fflush(stdout);
	return 0;
}

/*
 * 64 KiB chunks: large enough that the allocation phase stays well under
 * max_map_count, small enough that the buddy splits them out of high-order
 * blocks one at a time.
 */
#define FRAG_CHUNK (64L * 1024)
#define FRAG_MAX_CHUNKS 48000
#define FRAG_PAGE 4096L
/* Recovery can surface one block above the 12-block chase target. */
#define FRAG_BOUNDED_TARGET_REMAINING_PAGES (12L << 7)
#define FRAG_BOUNDED_MAX_REMAINING_PAGES (13L << 7)
/*
 * Allocation-phase floor, measured against MemFree and only consulted while
 * order-7 remains: the test condition itself is the stop once it is met, so
 * a floor has nothing left to guard.
 *
 * MemFree, not MemAvailable. MemAvailable is a conservative estimate that
 * subtracts the watermark and unreclaimable state, so it reads ~0 while
 * buddyinfo still lists allocatable high-order blocks. A floor on that
 * estimate stops the loop with the test condition unmet -- which is what
 * runs 36798464398 and 36800977305 both did, at 2 MiB and at 256 kB. The
 * 256 kB figure then drove the remaining faults into
 * pagefault_out_of_memory() with this process pinned, and the guest panicked
 * instead of failing the drill.
 *
 * 96 MiB is the margin the rest of the run needs to stay alive: the chase,
 * the punch, the drill shell's forks, and the ring allocation the
 * channel-open exercise is about to make. Anything the main loop leaves
 * above that is still holding high-order blocks, and the chase below is what
 * splits them.
 *
 * The level matters because the chase's peak RSS is main_pattern + held.
 * Run 36813796538 stopped at a 32 MiB margin and the OOM killer took the
 * helper at anon-rss 1950 MiB on a 2048 MiB guest: the main pattern held
 * 1920 MiB after the punch, the chase needed ~48 MiB more to drain the
 * 16 MiB of punch fuel and split the remaining high-order blocks, and there
 * was not 48 MiB left. Raising the margin shrinks the main pattern by
 * exactly the amount it grows the high-order residue, so the margin alone
 * does not create headroom -- the chase recycle below does. The margin is
 * the room the recycle works in, not a reserve the chase is kept out of.
 *
 * Run 36823337153 measured the residue that recycle has to pay for:
 * buddyinfo at the chase stop read 0 1 0 1 0 1 1 2 0 1 10, so the 13
 * remaining high-order blocks are ten order-10, one order-9 and two
 * order-7 -- 11008 free pages, 43 MiB, of which 40 MiB sit in order-10.
 * At full hold that is 43 MiB of chase RSS on top of a 1853 MiB main
 * pattern, past the 1950 MiB ceiling. Recycle halves the net cost.
 */
#define FRAG_HARD_KB 98304L
/*
 * Hole-phase caps. Earlier munmap-based punches allocated one
 * vm_area_struct per surviving run. On a 2 GiB guest that is ~250k slab
 * objects; once the Unmovable free pool is exhausted, vm_area_dup() fails
 * into out_of_memory() and -- with this process unkillable -- the kernel
 * panics with "System is deadlocked on memory". That is exactly what run
 * 36794687025 did on windows-2025. MADV_DONTNEED_LOCKED now drops page
 * backing without splitting the VMA; the cap still bounds the memory reserve
 * and preserves the physical buddy invariant.
 */
#define FRAG_HOLE_MIN_BYTES (128L * 1024 * 1024)
#define FRAG_HOLE_MAX_BYTES (128L * 1024 * 1024)
#define FRAG_HOLE_CAP (FRAG_HOLE_MIN_BYTES / FRAG_PAGE)
#define FRAG_HOLE_MAX_CAP (FRAG_HOLE_MAX_BYTES / FRAG_PAGE)
/*
 * hv_netvsc may allocate a 16 MiB receive buffer and a 15 MiB send buffer
 * while this pattern is held. Require 64 MiB of real MemFree above the live
 * watermark before opening the channel so those buffers retain 33 MiB of
 * guest headroom. The 128 MiB hole cap funds that reserve without creating
 * VMA splits. A temporary small PCP high limit makes
 * the released pages visible in buddy accounting before the reserve check.
 */
#define FRAG_RUNTIME_MIN_FREE_KB (64L * 1024)
#define FRAG_RUNTIME_MIN_HOLE_PAGES \
	((FRAG_RUNTIME_MIN_FREE_KB * 1024L) / FRAG_PAGE)
/* Recovery never frees more than the reserve we are trying to establish. */
#define FRAG_RUNTIME_RECOVERY_MAX_PAGES FRAG_RUNTIME_MIN_HOLE_PAGES
#define FRAG_RUNTIME_MIN_ORDER2_BLOCKS 1792L
/* Drive page frees from PCP into buddy lists during the held drill window. */
#define FRAG_PCP_HIGH_FRACTION_MIN 8L
#define FRAG_PCP_HIGH_FRACTION 65536L
/*
 * The chase spends the remaining safe headroom after the main fragmentation
 * pass. MemFree is the kernel's buddy-free count; min_free_kbytes is reduced
 * only inside this disposable guest, and watermark boost is disabled and
 * read back before pressure starts. The chase keeps the 1 MiB buddy-free
 * floor, a 1536-page chase target, a 1664-page recovery ceiling, and a
 * 4096-chunk hard cap.
 * Crossing any of them to force raw high-order count to zero would weaken
 * the safety contract that kept earlier guests from OOM and panic.
 *
 * A hosted runner can stop the chase with up to twelve minimum order-7 blocks
 * while still meeting the safe stress target. Free-memory recovery may return
 * one additional order-7 block, so the final pre-open ceiling is thirteen
 * blocks. The shell separately requires at least one minimum order-7 block
 * and no more than 512 pages to survive channel open. That result qualifies
 * only as bounded ordinary-path pressure:
 * at least 99% of the initial order-7-and-higher free pages were removed, no
 * more than 1664 pages remain before channel open, a measured safety boundary
 * caused the stop, and pagemap verified physical pages. It is
 * reported separately from full exhaustion and does not qualify the CoCo
 * chunked allocator, which an ordinary Hyper-V guest never executes.
 *
 * Keep the exact residue in the report. The bounded result says that the
 * ordinary vzalloc ring path survived a severe measured pattern; it does not
 * claim full saturation or that a high-order allocation would fail after
 * the later hole-punch phase.
 */
#define FRAG_CHASE_CAP 4096L
#define FRAG_CHASE_UNSPLIT 128L
#define FRAG_CHASE_HARD_KB 1024L
#define FRAG_CHASE_WMARK_MARGIN 256L
/*
 * Order-2 reserve. Taken before the pattern is built, while the buddy
 * still hands out contiguous runs, and released as verified order-2
 * groups just before ready=1 is printed.
 *
 * Run 36911059487 is what a fully starved buddy costs. The pattern
 * emptied every free block of order 2 and above along with order 7 --
 * the OOM dump read `1451*4kB (UM) 0*8kB 0*16kB` -- so copy_process()
 * could not get its order-2 stack, the OOM killer took the drill shell
 * (this process is pinned at -1000 and unkillable), init then found no
 * killable process and the guest panicked on "System is deadlocked on
 * memory". windows-2025 died the same way and lost its FRAGMENT_BUDDY
 * lines to the panic.
 *
 * The measured claim is order-7-and-up, not order-2. Leaving a few
 * order-2 blocks does not weaken it and does not help the ring path:
 * on ordinary x86_64 vmbus_alloc_buffer() takes vzalloc() anyway.
 *
 * IMPORTANT -- these groups are NOT forkable stacks. A single
 * MADV_DONTNEED_LOCKED of 16 KiB frees four order-0 folios into the per-cpu
 * page cache; it does not guarantee an order-2 buddy block. /proc/buddyinfo
 * does not count the PCP, and the alloc slowpath will not drain it:
 * drain_all_pages() runs only after direct reclaim reports progress, and
 * against this fully mlocked pattern it never does. Run 36940519876 reported
 * stacks=504 while buddyinfo held 1459*4kB 0*8kB 0*16kB and the next shell
 * fork was OOM-killed. Keep the shell fork-free from ready=1 until teardown;
 * buddy_order2 is the measured buddyinfo count, not the discarded-group
 * count, and remains only a conservative reserve for compound allocations.
 *
 * mmap faults order-0, so held pages are physically scattered and an
 * order-2 candidate run is found by PFN, not assumed from a virtual
 * run. Each released group is eight consecutive PFNs aligned to an
 * order-3 boundary: the first four pages lose their resident backing, and
 * the last four stay held. A 4-page-aligned group can straddle that boundary
 * and leave the freed half's order-2 buddy free, allowing coalescing above
 * order-2. The 8-page alignment keeps the held half as the exact buddy, so
 * the order-7 safety reserve just measured is not undone. Cap the groups
 * like the holes; discarded pages are not touched again before cleanup.
 *
 * Two properties make the runs findable. The per-cpu page cache is
 * drained first: it serves recycled, physically scattered order-0 pages
 * before the buddy splits anything, so a reserve taken against a warm
 * PCP comes back scattered and holds no 8-consecutive-PFN run at all --
 * run 36921241614 reported order2_reserve groups=0 pages=0 with
 * reserve=48 of 64 KiB chunks and the guest then died on a shell fork
 * that had no order-2 stack to allocate. After the drain, a refill
 * splits a high-order block and hands out sequential PFNs. The reserve
 * chunks are then 2 MiB, not 64 KiB, and are scanned wholesale: a
 * 16-page window almost never contains an 8-run even when the pages
 * are contiguous but misaligned, while a 512-page window does.
 */
#define FRAG_PCP_SOAK_CHUNK (2L * 1024 * 1024)
#define FRAG_PCP_SOAK_CHUNKS 4
#define FRAG_RESERVE_CHUNK (2L * 1024 * 1024)
#define FRAG_RESERVE_CHUNKS 32
#define FRAG_ORDER2_GROUPS 2048

/*
 * Punching one hole per freed page needs one VMA per surviving run. Save the
 * host value before raising it, then restore and verify it after all mappings
 * are gone.
 */
static long max_map_count_read(void)
{
	FILE *f = fopen("/proc/sys/vm/max_map_count", "r");
	char buf[64];
	long count = -1;

	if (!f)
		return -1;
	if (fgets(buf, sizeof(buf), f))
		count = strtol(buf, NULL, 10);
	fclose(f);
	return count;
}

static void max_map_count_write(long count)
{
	char buf[32];
	int fd, n;

	fd = open("/proc/sys/vm/max_map_count", O_WRONLY);
	if (fd < 0)
		return;
	n = snprintf(buf, sizeof(buf), "%ld\n", count);
	if (n > 0 && write(fd, buf, (size_t)n) < 0) {
		/* Readback at the call site detects a failed write. */
	}
	close(fd);
}

/*
 * min_free_kbytes sets the per-zone min watermark. On a 2 GiB guest the
 * default is ~20 MiB, so MemAvailable reads 2 MiB while /proc/buddyinfo
 * still shows 15 MiB of free pages -- those pages are free but reserved,
 * and a userspace page fault cannot cross the watermark to split the
 * high-order blocks hidden behind it. That is why the allocation loop kept
 * stopping with order-7 supply left no matter how low the MemAvailable
 * floor went: the floor was fine, the watermark was the wall.
 *
 * This is a disposable drill guest. Lowering the reserve is the only lever
 * userspace has to reach those pages. The original value is restored after
 * the channel-open exercise and verified before lifecycle starts.
 */
static long min_free_kb_read(void)
{
	FILE *f = fopen("/proc/sys/vm/min_free_kbytes", "r");
	char buf[64];
	long kb = -1;

	if (!f)
		return -1;
	if (fgets(buf, sizeof(buf), f))
		kb = strtol(buf, NULL, 10);
	fclose(f);
	return kb;
}

static void min_free_kb_write(long kb)
{
	char buf[32];
	int fd, n;

	fd = open("/proc/sys/vm/min_free_kbytes", O_WRONLY);
	if (fd < 0)
		return;
	n = snprintf(buf, sizeof(buf), "%ld\n", kb);
	if (n > 0 && write(fd, buf, (size_t)n) < 0) {
		/* best effort */
	}
	close(fd);
}

/*
 * watermark_boost_factor scales zone->_watermark_boost. Every free that
 * cannot coalesce raises the watermark by that factor of the fragmented
 * gap, which is precisely the pattern this drill builds: run 36899458556
 * measured boost:6924kB on a guest whose min_free_kbytes was 512, so the
 * effective watermark sat at 7436 kB and an order-0 fault OOMed the
 * helper mid-chase. 0 disables the boost entirely and is the only way a
 * floor below the boosted watermark is reachable. Its original value is
 * restored and verified after the parent releases the completed ring test.
 */
static long boost_factor_read(void)
{
	FILE *f = fopen("/proc/sys/vm/watermark_boost_factor", "r");
	char buf[64];
	long v = -1;

	if (!f)
		return -1;
	if (fgets(buf, sizeof(buf), f))
		v = strtol(buf, NULL, 10);
	fclose(f);
	return v;
}

static void boost_factor_write(long v)
{
	char buf[32];
	int fd, n;

	fd = open("/proc/sys/vm/watermark_boost_factor", O_WRONLY);
	if (fd < 0)
		return;
	n = snprintf(buf, sizeof(buf), "%ld\n", v);
	if (n > 0 && write(fd, buf, (size_t)n) < 0) {
		/* best effort */
	}
	close(fd);
}

static long pcp_high_fraction_read(void)
{
	FILE *f = fopen("/proc/sys/vm/percpu_pagelist_high_fraction", "r");
	char buf[64];
	long v = -1;

	if (!f)
		return -1;
	if (fgets(buf, sizeof(buf), f))
		v = strtol(buf, NULL, 10);
	fclose(f);
	return v;
}

static void pcp_high_fraction_write(long v)
{
	char buf[32];
	int fd, n;

	fd = open("/proc/sys/vm/percpu_pagelist_high_fraction", O_WRONLY);
	if (fd < 0)
		return;
	n = snprintf(buf, sizeof(buf), "%ld\n", v);
	if (n <= 0 || write(fd, buf, (size_t)n) != n) {
		close(fd);
		return;
	}
	close(fd);
}

/*
 * Free blocks at or above `min_order`, across all zones. min_order 7 is the
 * condition the fragmentation drill is actually about: while any remain, the
 * buddy can still satisfy an order-7 request outright and the fallback is not
 * under test. min_order 2 measures the compound-page reserve available to
 * task stacks and slab allocations. It is a conservative proxy, not a clone
 * guarantee; discarding four order-0 pages does not make one order-2 buddy
 * block until the PCP drains.
 *
 * buddyinfo layout is `Node <n>, zone <name>` followed by one count per
 * order, so order-0 is field 5 and order-k is field 5+k.
 */
static long buddy_blocks_at_or_above(int min_order)
{
	FILE *f = fopen("/proc/buddyinfo", "r");
	char line[512];
	long sum = 0;

	if (!f)
		return -1;
	while (fgets(line, sizeof(line), f)) {
		char *save = NULL;
		char *tok = strtok_r(line, " \t\n", &save);
		int field = 0;

		while (tok) {
			field++;
			if (field > 4 && field - 5 >= min_order) {
				char *end = NULL;
				long v = strtol(tok, &end, 10);

				if (end != tok)
					sum += v;
			}
			tok = strtok_r(NULL, " \t\n", &save);
		}
	}
	fclose(f);
	return sum;
}

static long buddy_pages_at_or_above(int min_order)
{
	FILE *f = fopen("/proc/buddyinfo", "r");
	char line[512];
	long sum = 0;

	if (!f)
		return -1;
	while (fgets(line, sizeof(line), f)) {
		char *save = NULL;
		char *tok = strtok_r(line, " \t\n", &save);
		int field = 0;

		while (tok) {
			field++;
			if (field > 4 && field - 5 >= min_order) {
				char *end = NULL;
				long blocks = strtol(tok, &end, 10);
				int order = field - 5;
				long pages;

				if (end == tok || *end || blocks < 0 ||
				    order >= (int)(sizeof(long) * CHAR_BIT - 1)) {
					fclose(f);
					return -1;
				}
				pages = 1L << order;
				if (blocks > (LONG_MAX - sum) / pages) {
					fclose(f);
					return -1;
				}
				sum += blocks * pages;
			}
			tok = strtok_r(NULL, " \t\n", &save);
		}
	}
	fclose(f);
	return sum;
}

static int frag_bounded_pressure_qualified(long before_pages,
						  long after_pages,
						  const char *stop_reason,
						  int pagemap,
						  int watermark_safe)
{
	if (before_pages <= 0 || after_pages <= 0 || pagemap != 1 ||
	    !watermark_safe)
		return 0;
	if (after_pages > FRAG_BOUNDED_MAX_REMAINING_PAGES || !stop_reason ||
	    (strcmp(stop_reason, "chase-memfree-margin") &&
	     strcmp(stop_reason, "order7-reserve") &&
	     strcmp(stop_reason, "chase-order7-reserve")) ||
	    after_pages >= before_pages)
		return 0;

	return after_pages <= before_pages / 100L;
}

static int frag_should_preserve_order7(long blocks, long pages)
{
	return blocks > 0 && pages >= (1L << 7) &&
	       blocks <= pages / (1L << 7) &&
	       pages <= FRAG_BOUNDED_TARGET_REMAINING_PAGES;
}

static int frag_should_refine_order7(long blocks, long pages)
{
	return blocks > 0 && pages > FRAG_BOUNDED_TARGET_REMAINING_PAGES;
}

static int frag_recovered_order7_qualified(long blocks, long pages)
{
	return blocks > 0 && pages >= (1L << 7) &&
	       blocks <= pages / (1L << 7) &&
	       pages <= FRAG_BOUNDED_MAX_REMAINING_PAGES;
}

static int frag_pcp_high_fraction_qualified(long requested, long current)
{
	return requested >= FRAG_PCP_HIGH_FRACTION_MIN && current == requested;
}

static int frag_runtime_reserve_qualified(long hole_cap, long freed_pages,
					  long free_above_wmark_kb,
					  long order2_blocks)
{
	return hole_cap >= 0 && FRAG_HOLE_MAX_CAP >= hole_cap &&
	       hole_cap * FRAG_PAGE >= FRAG_HOLE_MIN_BYTES &&
	       freed_pages >= FRAG_RUNTIME_MIN_HOLE_PAGES &&
	       free_above_wmark_kb >= FRAG_RUNTIME_MIN_FREE_KB &&
	       order2_blocks >= FRAG_RUNTIME_MIN_ORDER2_BLOCKS;
}

static void frag_wait_for_release(const char *release_file, long hold)
{
	long waited = 0;

	while (waited < hold && !frag_release_requested(release_file)) {
		sleep(1);
		waited++;
	}
	printf("FRAGMENT_BUDDY hold_end waited_seconds=%ld limit_seconds=%ld release_file=%s signal=%d\n",
	       waited, hold, release_file ? "set" : "none",
	       (int)frag_stop_signal);
	fflush(stdout);
}

/*
 * Free memory as the kernel counts it, not as MemAvailable estimates it.
 * MemAvailable subtracts the watermark and unreclaimable state and so reads
 * near zero while buddyinfo still holds allocatable high-order blocks; a
 * floor on it stops the loop with the test condition unmet.
 *
 * MemFree is not the pcp either: it tracks the buddy free lists only, the
 * same set buddyinfo reports, and both omit the per-cpu page cache. That is
 * why the chase floor is computed in unsplit_free_pages() rather than read
 * straight off this file.
 */
static long mem_free_kb(void)
{
	FILE *f = fopen("/proc/meminfo", "r");
	char line[256];
	long kb = -1;

	if (!f)
		return -1;
	while (fgets(line, sizeof(line), f)) {
		if (strncmp(line, "MemFree:", 8) == 0) {
			kb = strtol(line + 8, NULL, 10);
			break;
		}
	}
	fclose(f);
	return kb;
}

/*
 * The watermark the allocator will actually refuse below, in kB: every
 * zone's `min` plus its `boost`, from /proc/zoneinfo. Both are in pages.
 *
 * `boost` is the number to watch. boost_watermark() raises it under
 * fragmentation -- which is the whole point of this drill -- so the
 * watermark is not a fixed multiple of min_free_kbytes. Run 36879744347
 * saw it go 0 -> 4096 kB (windows-latest) and 0 -> 12288 kB
 * (windows-2025) after the first OOM. A floor that ignores boost is the
 * same class of mistake as a floor below min_free_kbytes.
 */
static long live_min_watermark_kb(void)
{
	FILE *f = fopen("/proc/zoneinfo", "r");
	char line[256];
	long min_pages = 0, boost_pages = 0, saw = 0;

	if (!f)
		return -1;
	while (fgets(line, sizeof(line), f)) {
		char *p = line;

		while (*p == ' ' || *p == '\t')
			p++;
		if (strncmp(p, "min", 3) == 0 &&
		    (p[3] == ' ' || p[3] == '\t')) {
			min_pages += strtol(p + 3, NULL, 10);
			saw++;
		} else if (strncmp(p, "boost", 5) == 0 &&
			   (p[5] == ' ' || p[5] == '\t')) {
			boost_pages += strtol(p + 5, NULL, 10);
		}
	}
	fclose(f);
	if (!saw)
		return -1;
	return (min_pages + boost_pages) * 4;
}

/*
 * Free pages sitting in the per-cpu page cache, summed over every cpu and
 * zone. Reported by /proc/zoneinfo's `pagesets` block as pcp->count.
 *
 * This is the quantity neither MemFree nor buddyinfo reports. A freed page
 * goes to the pcp first -- free_frozen_page_commit() adds it to pcp->count
 * and never calls account_freepages() -- and NR_FREE_PAGES is bumped only
 * when the pcp drains into the buddy. So a page freed by munmap is free,
 * and invisible to both /proc files, until something else drains it.
 */
static long pcp_free_pages(void)
{
	FILE *f = fopen("/proc/zoneinfo", "r");
	char line[256];
	long sum = 0;
	int in_pagesets = 0;

	if (!f)
		return -1;
	while (fgets(line, sizeof(line), f)) {
		char *p = line;

		if (strncmp(line, "Node ", 5) == 0) {
			in_pagesets = 0;
			continue;
		}
		if (strncmp(line, "  pagesets", 10) == 0) {
			in_pagesets = 1;
			continue;
		}
		if (!in_pagesets)
			continue;
		while (*p == ' ' || *p == '\t')
			p++;
		if (strncmp(p, "count:", 6) == 0) {
			char *end = NULL;
			long v = strtol(p + 6, &end, 10);

			if (end != p + 6 && v > 0)
				sum += v;
		}
	}
	fclose(f);
	return sum;
}

/*
 * Free pages a fault can take without splitting a higher-order block: the
 * order-0 buddy lists plus the per-cpu page cache. This is the floor the
 * chase is allowed to leave behind.
 *
 * A fault tries the pcp first and then the order-0 buddy lists; only when
 * both are empty does the allocator split a higher-order block. So this sum
 * is exactly the no-split budget, and it is not what any single /proc file
 * reports. MemFree equals the buddy lists and omits the pcp entirely;
 * buddyinfo's own order-0 count omits the pcp as well. Run 36806229800
 * punched 4096 isolated pages, which went to the pcp, and buddyinfo still
 * read 1 -- a floor on either raw figure fires right after the punch that is
 * supposed to make room. Run 36808657969 repeated that with a
 * "MemFree minus the high orders" floor, which is algebraically just
 * buddyinfo's order-0 again, and got chase=0 for the same reason.
 *
 * Orders 0 through 6, not order-0 alone. Run 36927495556 wl is why: the
 * chase stopped at chase-unsplit-floor with unsplit=114 while 25
 * high-order blocks, 88.5 MiB, were still free, and high_order_7plus
 * never moved across the whole chase (26->26). Counting order-0 plus the
 * pcp reads near zero whenever the leftover free memory is parked in
 * orders 1..6 and above, which is exactly the state the main loop's
 * margin leaves behind, so the floor fires before a single high order is
 * split. The older claim that the number rises on a split and therefore
 * cannot fire while high orders remain is true only after a split has
 * happened; with the wrong measure no split is ever forced.
 *
 * This sum is the no-split budget: pages the allocator can still hand out
 * by serving or splitting below order 7. It is a starvation guard;
 * high==0 is what ends the chase.
 */
static long low_order_free_pages(void)
{
	FILE *f = fopen("/proc/buddyinfo", "r");
	char line[512];
	long sum = 0;

	if (!f)
		return -1;
	while (fgets(line, sizeof(line), f)) {
		char *save = NULL;
		char *tok = strtok_r(line, " \t\n", &save);
		int field = 0;

		while (tok) {
			field++;
			if (field >= 5 && field - 5 <= 6) {
				char *end = NULL;
				long v = strtol(tok, &end, 10);

				if (end != tok && v > 0)
					sum += v * (1L << (field - 5));
			}
			tok = strtok_r(NULL, " \t\n", &save);
		}
	}
	fclose(f);
	return sum;
}

static long unsplit_free_pages(void)
{
	long low = low_order_free_pages();
	long pcp = pcp_free_pages();

	if (low < 0 || pcp < 0)
		return -1;
	return low + pcp;
}

/*
 * Pin or unpin this process against the OOM killer. The pin covers exactly
 * the hold: the window in which a finished pattern must survive the drill
 * shell's measurement and the channel-open exercise. It is deliberately off
 * before that -- while this process allocates -- because an unkillable fault
 * in a guest with nothing else left to reclaim is how out_of_memory() reaches
 * "no killable processes" and panics. It is dropped when the hold ends, so
 * the teardown can be reclaimed like any other process.
 */
static long oom_score_adj_read(void)
{
	FILE *f = fopen("/proc/self/oom_score_adj", "r");
	char buf[64];
	char *end = NULL;
	long value = LONG_MIN;

	if (!f)
		return LONG_MIN;
	if (fgets(buf, sizeof(buf), f)) {
		errno = 0;
		value = strtol(buf, &end, 10);
		if (errno || end == buf)
			value = LONG_MIN;
	}
	fclose(f);
	return value;
}

static int set_oom_adj(long value)
{
	char buf[32];
	int fd, n, rc = -1;

	fd = open("/proc/self/oom_score_adj", O_WRONLY);
	if (fd < 0)
		return -1;
	n = snprintf(buf, sizeof(buf), "%ld\n", value);
	if (n > 0 && write(fd, buf, (size_t)n) == n)
		rc = 0;
	close(fd);
	return rc;
}

/*
 * PFN of a populated page. Returns 0 and stores the PFN, or -1 when the
 * entry is absent, swapped out, or pagemap is withholding PFNs (no
 * CAP_SYS_ADMIN). PFNs are used only to choose which pages to unmap and
 * are never printed.
 */
static int pagemap_pfn(int fd, void *addr, unsigned long *pfn)
{
	uint64_t ent;
	unsigned long idx = (unsigned long)addr / (unsigned long)FRAG_PAGE;

	if (pread(fd, &ent, sizeof(ent),
		  (off_t)idx * (off_t)sizeof(ent)) != (ssize_t)sizeof(ent))
		return -1;
	if (!(ent & (1ULL << 63)))
		return -1;
	*pfn = (unsigned long)(ent & ((1ULL << 55) - 1));
	return *pfn ? 0 : -1;
}

/*
 * Drop backing from already-locked anonymous pages without splitting the VMA.
 * Return -1 for a failed madvise and -2 if any page is still resident.
 */
static int frag_discard_locked_pages(int pmfd, void *addr, size_t bytes)
{
	size_t off;

	if (!bytes || bytes % FRAG_PAGE ||
	    madvise(addr, bytes, MADV_DONTNEED_LOCKED) != 0)
		return -1;

	for (off = 0; off < bytes; off += FRAG_PAGE) {
		unsigned long pfn;

		if (pagemap_pfn(pmfd, (char *)addr + off, &pfn) == 0)
			return -2;
	}
	return 0;
}

static int pfn_bitmap_set(unsigned long **bits, size_t *words,
		  unsigned long pfn)
{
	const unsigned long bits_per_word = sizeof(**bits) * CHAR_BIT;
	unsigned long word = pfn / bits_per_word;
	size_t needed, capacity;
	unsigned long *grown;

	if (word >= SIZE_MAX / sizeof(**bits))
		return -1;
	needed = (size_t)word + 1;
	if (needed > *words) {
		capacity = *words ? *words : 1;
		while (capacity < needed) {
			if (capacity > SIZE_MAX / 2) {
				capacity = needed;
				break;
			}
			capacity *= 2;
		}
		if (capacity > SIZE_MAX / sizeof(**bits))
			return -1;
		grown = realloc(*bits, capacity * sizeof(**bits));
		if (!grown)
			return -1;
		memset(grown + *words, 0,
		       (capacity - *words) * sizeof(**bits));
		*bits = grown;
		*words = capacity;
	}
	(*bits)[word] |= 1UL << (pfn % bits_per_word);
	return 0;
}

static int pfn_bitmap_get(const unsigned long *bits, size_t words,
		  unsigned long pfn)
{
	const unsigned long bits_per_word = sizeof(*bits) * CHAR_BIT;
	unsigned long word = pfn / bits_per_word;

	if (word >= words)
		return 0;
	return !!(bits[word] & (1UL << (pfn % bits_per_word)));
}

static unsigned long frag_order2_group_alignment_skip(unsigned long pfn)
{
	return (8UL - (pfn & 7UL)) & 7UL;
}

/* pfns[] stores PFN+1 so zero can mark an unread pagemap entry. */
static int frag_page_has_held_buddy(unsigned long encoded_pfn,
				    const unsigned long *seen,
				    size_t seen_words)
{
	unsigned long pfn;

	if (encoded_pfn <= 1)
		return 0;
	pfn = encoded_pfn - 1;
	return !(pfn & 1UL) && pfn_bitmap_get(seen, seen_words, pfn + 1);
}

static long frag_recovery_pages_needed(long free_kb, long wmark_kb)
{
	long free_above_wmark_kb, needed_kb;

	if (free_kb < 0 || wmark_kb < 0)
		return -1;
	free_above_wmark_kb = free_kb > wmark_kb ? free_kb - wmark_kb : 0;
	if (free_above_wmark_kb >= FRAG_RUNTIME_MIN_FREE_KB)
		return 0;

	needed_kb = FRAG_RUNTIME_MIN_FREE_KB - free_above_wmark_kb;
	return (needed_kb * 1024L + FRAG_PAGE - 1) / FRAG_PAGE;
}

/* Rebuild the bitmap from resident PFNs after the hole and refine passes. */
static int frag_record_mapping_pfns(int pmfd, char *mapping, long bytes,
				    unsigned long **seen, size_t *seen_words)
{
	long off;

	for (off = 0; off < bytes; off += FRAG_PAGE) {
		unsigned long pfn;

		if (pagemap_pfn(pmfd, mapping + off, &pfn) != 0)
			continue;
		if (pfn_bitmap_set(seen, seen_words, pfn))
			return -1;
	}
	return 0;
}

static int frag_recover_runtime_reserve(int pmfd, void **maps, long map_count,
					void **chase_maps, long chase_count,
					void **reserve, long reserve_count,
					unsigned long **seen, size_t *seen_words,
					const char *release_file,
					long *recovered_pages,
					long *scanned_pages, long *free_kb,
					long *wmark_kb, long *high_after,
					long *high_after_pages)
{
	long needed_pages, i;
	int done;

	*recovered_pages = 0;
	*scanned_pages = 0;
	*free_kb = mem_free_kb();
	*wmark_kb = live_min_watermark_kb();
	needed_pages = frag_recovery_pages_needed(*free_kb, *wmark_kb);
	if (needed_pages < 0) {
		printf("FRAGMENT_BUDDY ready=0 reason=runtime-recovery-measurement-unavailable\n");
		fflush(stdout);
		return -1;
	}
	if (needed_pages > FRAG_RUNTIME_RECOVERY_MAX_PAGES) {
		printf("FRAGMENT_BUDDY ready=0 reason=runtime-recovery-cap\n");
		printf("FRAGMENT_BUDDY recovery needed_pages=%ld cap_pages=%ld\n",
		       needed_pages, FRAG_RUNTIME_RECOVERY_MAX_PAGES);
		fflush(stdout);
		return -1;
	}
	done = needed_pages == 0;
	if (!done) {
		/*
		 * Hole punching and refine can change which PFNs are still held.
		 * Rebuild from live mappings so a page released earlier is never
		 * mistaken for a held buddy.
		 */
		free(*seen);
		*seen = NULL;
		*seen_words = 0;
		for (i = 0; i < map_count; i++) {
			if (frag_record_mapping_pfns(pmfd, maps[i], FRAG_CHUNK,
						     seen, seen_words))
				goto pfn_set_failed;
		}
		for (i = 0; i < chase_count; i++) {
			if (frag_record_mapping_pfns(pmfd, chase_maps[i],
						     FRAG_CHUNK, seen,
						     seen_words))
				goto pfn_set_failed;
		}
		for (i = 0; i < reserve_count; i++) {
			if (frag_record_mapping_pfns(pmfd, reserve[i],
						     FRAG_RESERVE_CHUNK, seen,
						     seen_words))
				goto pfn_set_failed;
		}

		/*
		 * MADV_DONTNEED_LOCKED drops resident pages without splitting the
		 * VMA. Release only an even PFN whose odd buddy remains present in
		 * the live bitmap, so each returned page stays order-0 and cannot
		 * rebuild high-order blocks. No discarded page is touched again.
		 */
		for (i = 0; i < map_count + chase_count + reserve_count && !done;
		     i++) {
			char *mapping;
			long bytes, page_off;

			if (i < map_count) {
				mapping = maps[i];
				bytes = FRAG_CHUNK;
			} else if (i < map_count + chase_count) {
				mapping = chase_maps[i - map_count];
				bytes = FRAG_CHUNK;
			} else {
				mapping = reserve[i - map_count - chase_count];
				bytes = FRAG_RESERVE_CHUNK;
			}
			for (page_off = 0; page_off < bytes && !done;
			     page_off += FRAG_PAGE) {
				unsigned long pfn, after_pfn;

				if (((*scanned_pages)++ & 63L) == 0 &&
				    frag_release_requested(release_file))
					return -1;
				if (pagemap_pfn(pmfd, mapping + page_off, &pfn) != 0 ||
				    !frag_page_has_held_buddy(pfn + 1, *seen,
							      *seen_words))
					continue;
				if (madvise(mapping + page_off, (size_t)FRAG_PAGE,
					    MADV_DONTNEED_LOCKED) != 0) {
					printf("FRAGMENT_BUDDY recovery_madvise errno=%d\n",
					       errno);
					fflush(stdout);
					return -1;
				}
				if (pagemap_pfn(pmfd, mapping + page_off,
						&after_pfn) == 0) {
					printf("FRAGMENT_BUDDY recovery_page_retained\n");
					fflush(stdout);
					return -1;
				}
				(*recovered_pages)++;
				if (((*recovered_pages) & 63L) == 0 ||
				    *recovered_pages == FRAG_RUNTIME_RECOVERY_MAX_PAGES) {
					*free_kb = mem_free_kb();
					*wmark_kb = live_min_watermark_kb();
					needed_pages = frag_recovery_pages_needed(*free_kb,
										  *wmark_kb);
					if (needed_pages < 0) {
						printf("FRAGMENT_BUDDY recovery_measurement\n");
						fflush(stdout);
						return -1;
					}
					done = needed_pages == 0;
				}
			}
		}
		*free_kb = mem_free_kb();
		*wmark_kb = live_min_watermark_kb();
		needed_pages = frag_recovery_pages_needed(*free_kb, *wmark_kb);
		if (needed_pages < 0 || !done) {
			printf("FRAGMENT_BUDDY ready=0 reason=reserve-recovery-insufficient\n");
			printf("FRAGMENT_BUDDY recovery pages=%ld scan=%ld needed=%ld cap=%ld\n",
			       *recovered_pages, *scanned_pages, needed_pages,
			       FRAG_RUNTIME_RECOVERY_MAX_PAGES);
			fflush(stdout);
			return -1;
		}
	}
	*high_after = buddy_blocks_at_or_above(7);
	*high_after_pages = buddy_pages_at_or_above(7);
	if (*high_after < 0 || *high_after_pages < 0) {
		printf("FRAGMENT_BUDDY ready=0 reason=recovery-buddyinfo-unavailable\n");
		fflush(stdout);
		return -1;
	}
	if (*recovered_pages > 0 &&
	    !frag_recovered_order7_qualified(*high_after, *high_after_pages)) {
		printf("FRAGMENT_BUDDY ready=0 reason=recovery-order7-not-preserved\n");
		printf("FRAGMENT_BUDDY recovery high_order_7plus=%ld pages=%ld "
		       "recovered_pages=%ld scan=%ld free_kb=%ld "
		       "above_wmark_kb=%ld max_pages=%ld\n",
		       *high_after, *high_after_pages, *recovered_pages,
		       *scanned_pages, *free_kb,
		       *free_kb > *wmark_kb ? *free_kb - *wmark_kb : 0,
		       FRAG_BOUNDED_MAX_REMAINING_PAGES);
		fflush(stdout);
		return -1;
	}
	printf("FRAGMENT_BUDDY recovery pages=%ld scan=%ld free_kb=%ld above_wmark_kb=%ld\n",
	       *recovered_pages, *scanned_pages, *free_kb,
	       *free_kb > *wmark_kb ? *free_kb - *wmark_kb : 0);
	printf("FRAGMENT_BUDDY recovery required_kb=%ld high_order_7plus=%ld pages=%ld\n",
	       FRAG_RUNTIME_MIN_FREE_KB, *high_after, *high_after_pages);
	fflush(stdout);
	return 0;

pfn_set_failed:
	printf("FRAGMENT_BUDDY ready=0 reason=runtime-recovery-pfn-set-failed\n");
	fflush(stdout);
	return -1;
}

static int do_fragment_buddy(int argc, char **argv)
{
	long mib, hold, want, got = 0, locked = 0, i, off, stopped = 0;
	long freed_pages = 0, held_pages = 0, no_pfn = 0, pairs = 0;
	long high_before = -1, high_locked = -1, high_after = -1;
	long free_kb = -1, free_above_wmark_kb = -1;
	long high_before_pages = -1, high_locked_pages = -1;
	long high_after_pages = -1;
	long wmark_kb = -1, floor_kb = -1;
	long chase_free_kb = -1, chase_wmark_kb = -1, chase_floor_kb = -1;
	long recovery_pages = 0, recovery_scanned = 0;
	long min_free_saved = -1, min_free_set = 512, min_free_now = -1;
	long boost_saved = -1, boost_now = -1;
	long pcp_high_fraction_saved = -1, pcp_high_fraction_now = -1;
	long pcp_high_set = FRAG_PCP_HIGH_FRACTION;
	long map_count_saved = -1, map_count_set = 1048576;
	long map_count_now = -1, oom_score_adj_saved = LONG_MIN;
	long oom_score_adj_now = LONG_MIN;
	long chase = 0, chase_locked = 0;
	long chase_holes = 0, chase_pairs = 0;
	long unsplit_at_stop = -1;
	void **maps = NULL, **chase_maps = NULL;
	void *reserve[FRAG_RESERVE_CHUNKS] = { 0 };
	void *soak[FRAG_PCP_SOAK_CHUNKS] = { 0 };
	long soak_got = 0;
	long reserve_got = 0, order2_groups = 0, order2_pages = 0;
	long order2_buddy = -1;
	unsigned long *pfns = NULL, *seen = NULL;
	unsigned long max_pfn = 0;
	size_t seen_words = 0;
	int pmfd = -1, bounded = 0, rc = 1, restore_ok;
	int min_free_changed = 0, boost_changed = 0, map_count_changed = 0;
	int pcp_high_fraction_changed = 0;
	const char *release_file = NULL;
	const char *pid_file = NULL;
	const char *stop_reason = "ceiling";

	if (argc < 3 || argc > 5) {
		fprintf(stderr,
			"usage: fragment-buddy <mib> <hold_seconds> [release_file] [pid_file]\n");
		return 2;
	}
	mib = parse_long(argv[1], "mib");
	hold = parse_long(argv[2], "hold_seconds");
	if (argc == 4 && argv[3][0] != '\0')
		release_file = argv[3];
	if (argc == 5) {
		if (argv[3][0] != '\0')
			release_file = argv[3];
		if (argv[4][0] != '\0')
			pid_file = argv[4];
	}
	if (mib <= 0 || mib > (long)(16 * 1024) || hold > 3600 ||
	    (release_file && hold <= 0)) {
		fprintf(stderr, "HELPER mib or hold_seconds out of range\n");
		return 2;
	}

	/*
	 * mib is a ceiling the allocation loop must never reach, not a
	 * quota. Passing a share of what looks free stops the loop while the
	 * untouched remainder still holds order-10 blocks, so order-7 never
	 * fails and the drill reports INCONCLUSIVE. The caller passes
	 * MemTotal; the loop stops when the test condition is met.
	 */
	want = (mib * 1024 * 1024) / FRAG_CHUNK;
	if (want > FRAG_MAX_CHUNKS)
		want = FRAG_MAX_CHUNKS;
	if (want < 2) {
		fprintf(stderr, "HELPER mib too small to fragment\n");
		return 2;
	}
	if (frag_install_signal_handlers()) {
		printf("FRAGMENT_BUDDY ready=0 reason=signal-handler-install\n");
		fflush(stdout);
		return 3;
	}
	if (frag_write_pid_file(pid_file)) {
		printf("FRAGMENT_BUDDY ready=0 reason=pid-file-write-failed\n");
		fflush(stdout);
		return 3;
	}

	/*
	 * Read every process/global setting before changing any of them. The map
	 * limit and watermarks are restored after the mappings are gone; the OOM
	 * score is restored exactly to the value inherited from the parent.
	 */
	map_count_saved = max_map_count_read();
	min_free_saved = min_free_kb_read();
	boost_saved = boost_factor_read();
	pcp_high_fraction_saved = pcp_high_fraction_read();
	oom_score_adj_saved = oom_score_adj_read();
	if (map_count_saved < 0 || min_free_saved < 0 || boost_saved < 0 ||
	    pcp_high_fraction_saved < 0 || oom_score_adj_saved == LONG_MIN) {
		printf("FRAGMENT_BUDDY ready=0 reason=state-read-failed ");
		printf("max_map_count=%ld min_free_kbytes=%ld ",
		       map_count_saved, min_free_saved);
		printf("watermark_boost_factor=%ld pcp_high_fraction=%ld ",
		       boost_saved, pcp_high_fraction_saved);
		printf("oom_score_adj=%ld\n", oom_score_adj_saved);
		fflush(stdout);
		return 3;
	}
	if (map_count_set < map_count_saved)
		map_count_set = map_count_saved;
	printf("FRAGMENT_BUDDY saved_state max_map_count=%ld min_free_kbytes=%ld ",
	       map_count_saved, min_free_saved);
	printf("watermark_boost_factor=%ld pcp_high_fraction=%ld ",
	       boost_saved, pcp_high_fraction_saved);
	printf("oom_score_adj=%ld\n", oom_score_adj_saved);
	fflush(stdout);
	if (frag_release_requested(release_file)) {
		printf("FRAGMENT_BUDDY ready=0 reason=release-before-setup\n");
		fflush(stdout);
		rc = frag_stop_signal ? 128 + frag_stop_signal : 3;
		goto cleanup;
	}
	pcp_high_fraction_changed = pcp_high_set != pcp_high_fraction_saved;
	if (pcp_high_fraction_changed)
		pcp_high_fraction_write(pcp_high_set);
	pcp_high_fraction_now = pcp_high_fraction_read();
	printf("FRAGMENT_BUDDY pcp_high_fraction saved=%ld set=%ld now=%ld\n",
	       pcp_high_fraction_saved, pcp_high_set,
	       pcp_high_fraction_now);
	fflush(stdout);
	if (!frag_pcp_high_fraction_qualified(pcp_high_set,
					      pcp_high_fraction_now)) {
		printf("FRAGMENT_BUDDY ready=0 reason=pcp-high-fraction-not-set\n");
		fflush(stdout);
		rc = 3;
		goto cleanup;
	}
	if (oom_score_adj_saved != 0 &&
	    (set_oom_adj(0) || oom_score_adj_read() != 0)) {
		printf("FRAGMENT_BUDDY ready=0 reason=oom-score-reset-failed\n");
		fflush(stdout);
		rc = 3;
		goto cleanup;
	}
	map_count_changed = map_count_set != map_count_saved;
	if (map_count_changed)
		max_map_count_write(map_count_set);
	map_count_now = max_map_count_read();
	printf("FRAGMENT_BUDDY max_map_count saved=%ld set=%ld now=%ld\n",
	       map_count_saved, map_count_set, map_count_now);
	fflush(stdout);
	if (map_count_now != map_count_set) {
		printf("FRAGMENT_BUDDY ready=0 reason=max-map-count-not-raised\n");
		fflush(stdout);
		rc = 3;
		goto cleanup;
	}

	/* Lower the min watermark so the loop can reach high-order blocks hidden
	 * behind the guest's normal reserve. */
	min_free_changed = 1;
	min_free_kb_write(min_free_set);
	/*
	 * Read back rather than trusting the write: the sysctl is
	 * best-effort and can be denied, and a silent no-op must not look
	 * like the lever was pulled. The report carries the value that is
	 * actually in force.
	 */
	min_free_now = min_free_kb_read();
	printf("FRAGMENT_BUDDY min_free_kbytes saved=%ld set=%ld now=%ld\n",
	       min_free_saved, min_free_set, min_free_now);
	fflush(stdout);
	if (min_free_now != min_free_set) {
		/*
		 * Fail closed. Run 36879744347 is what an unverified write
		 * costs: min_free_kbytes stayed at its saved ~5694 kB, the
		 * MemFree floor never bound (buddy free 5376 kB > the 4 MiB
		 * floor, with 15 MiB stranded in pcp), an order-1 GFP_KERNEL
		 * from sh hit the un-lowered watermark, and both guests died.
		 * No floor below ~6 MiB is meaningful unless the watermark
		 * is actually the one this run asked for.
		 */
		printf("FRAGMENT_BUDDY ready=0 pagemap=0 reason=min-free-not-lowered\n");
		fflush(stdout);
		rc = 3;
		goto cleanup;
	}

	/*
	 * Same discipline for boost. min_free_kbytes alone is not the
	 * watermark: zone->_watermark_boost is added on top of it, and
	 * fragmenting is what makes boost move. Run 36899458556 left this
	 * at the default and the floor chased it from 2048 kB up past
	 * 9484 kB, so the change that was meant to go deeper than the 8 MiB
	 * run stopped earlier and then OOMed anyway.
	 */
	boost_changed = 1;
	boost_factor_write(0);
	boost_now = boost_factor_read();
	printf("FRAGMENT_BUDDY watermark_boost_factor saved=%ld set=0 now=%ld\n",
	       boost_saved, boost_now);
	fflush(stdout);
	if (boost_now != 0) {
		printf("FRAGMENT_BUDDY ready=0 pagemap=0 reason=boost-not-disabled\n");
		fflush(stdout);
		rc = 3;
		goto cleanup;
	}

	/*
	 * Deliberately not pinned here. Allocation, punch and chase all run
	 * with the OOM killer able to take this process: a kill in that window
	 * loses the pattern and reports INCONCLUSIVE_NO_PATTERN, which is a
	 * recoverable outcome. Pinning it instead, as run 36800977305 did,
	 * let out_of_memory() reclaim the drill shell and then find nothing
	 * killable at all -- "System is deadlocked on memory", guest panic.
	 * The pin goes on once ready=1 has been printed and the pattern has to
	 * outlive this process's next fault.
	 */
	maps = calloc((size_t)want, sizeof(*maps));
	pfns = calloc((size_t)want * (FRAG_CHUNK / FRAG_PAGE), sizeof(*pfns));
	chase_maps = calloc((size_t)FRAG_CHASE_CAP, sizeof(*chase_maps));
	if (!maps || !pfns || !chase_maps) {
		printf("HELPER calloc: %s\n", strerror(errno));
		fflush(stdout);
		goto cleanup;
	}

	high_before = buddy_blocks_at_or_above(7);
	high_before_pages = buddy_pages_at_or_above(7);
	if (high_before < 0 || high_before_pages < 0) {
		printf("FRAGMENT_BUDDY ready=0 reason=initial-buddyinfo-unavailable\n");
		fflush(stdout);
		rc = 3;
		goto cleanup;
	}
	printf("FRAGMENT_BUDDY start cap_chunks=%ld high_order_7plus=%ld high_order_7plus_pages=%ld\n",
	       want, high_before, high_before_pages);
	fflush(stdout);

	/*
	 * Drain the per-cpu page cache before the reserve, so the reserve
	 * itself comes from buddy splits and therefore in runs. Order-0
	 * faults are served from the PCP first, and those pages are
	 * recycled and physically scattered; the soak holds them so they
	 * cannot come back. Held for the whole pattern with the reserve
	 * and released just before ready=1, see below.
	 */
	for (i = 0; i < FRAG_PCP_SOAK_CHUNKS; i++) {
		char *m;
		if (frag_release_requested(release_file)) {
			rc = frag_stop_signal ? 128 + frag_stop_signal : 3;
			goto cleanup;
		}

		m = mmap(NULL, FRAG_PCP_SOAK_CHUNK, PROT_READ | PROT_WRITE,
			 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (m == MAP_FAILED)
			break;
		for (off = 0; off < FRAG_PCP_SOAK_CHUNK; off += FRAG_PAGE)
			m[off] = 1;
		if (mlock(m, FRAG_PCP_SOAK_CHUNK) != 0) {
			munmap(m, FRAG_PCP_SOAK_CHUNK);
			break;
		}
		soak[i] = m;
		soak_got++;
	}

	/*
	 * Take the order-2 reserve first so it is carved out of an
	 * untouched buddy and comes back as contiguous runs. Held for the
	 * whole pattern, which keeps it out of the allocation being
	 * measured; released just before ready=1, see below.
	 */
	for (i = 0; i < FRAG_RESERVE_CHUNKS; i++) {
		char *m;
		if (frag_release_requested(release_file)) {
			rc = frag_stop_signal ? 128 + frag_stop_signal : 3;
			goto cleanup;
		}

		m = mmap(NULL, FRAG_RESERVE_CHUNK, PROT_READ | PROT_WRITE,
			 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (m == MAP_FAILED)
			break;
		for (off = 0; off < FRAG_RESERVE_CHUNK; off += FRAG_PAGE)
			m[off] = 1;
		if (mlock(m, FRAG_RESERVE_CHUNK) != 0) {
			munmap(m, FRAG_RESERVE_CHUNK);
			break;
		}
		reserve[i] = m;
		reserve_got++;
	}

	/*
	 * Allocate 64 KiB chunks and touch every page. Stop when the buddy has
	 * no more than twelve minimum order-7 blocks left, preserving the measured
	 * safety reserve,
	 * or when the MemFree floor says the rest of the run needs more room.
	 *
	 * The order-7 count and page total are measured every chunk. The reserve
	 * is checked before the floor so a single 64 KiB allocation cannot split
	 * the final reserve into smaller orders. A 32-chunk
	 * cadence walked past blocks that a single chunk would have split, and
	 * a floor on MemAvailable stopped the loop while order-7 was still
	 * present. Both are ways to leave the test condition unmet without
	 * ever being short of memory.
	 *
	 * The floor is a margin, not a measure of exhaustion. It is only
	 * consulted while more than twelve order-7 blocks remain; the chase stops
	 * at the same reserve if the main pass leaves it high-order.
	 */
	for (i = 0; i < want; i++) {
		char *m;
		long high, high_pages;

		if (frag_release_requested(release_file)) {
			rc = frag_stop_signal ? 128 + frag_stop_signal : 3;
			goto cleanup;
		}

		high = buddy_blocks_at_or_above(7);
		high_pages = buddy_pages_at_or_above(7);
		if (high < 0 || high_pages < 0) {
			printf("FRAGMENT_BUDDY ready=0 reason=allocation-buddyinfo-unavailable\n");
			fflush(stdout);
			rc = 3;
			goto cleanup;
		}
		if (high == 0) {
			stopped = 1;
			stop_reason = "order7-depleted";
			break;
		}
		if (frag_should_preserve_order7(high, high_pages)) {
			stopped = 1;
			stop_reason = "order7-reserve";
			break;
		}

		free_kb = mem_free_kb();
		if (free_kb >= 0 && free_kb < FRAG_HARD_KB) {
			stopped = 1;
			stop_reason = "memfree-margin";
			break;
		}

		m = mmap(NULL, FRAG_CHUNK, PROT_READ | PROT_WRITE,
			 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (m == MAP_FAILED) {
			stopped = 1;
			stop_reason = "mmap-refused";
			break;
		}
		for (off = 0; off < FRAG_CHUNK; off += FRAG_PAGE)
			m[off] = 1;
		/*
		 * Pin before the next order-7 measurement, not after the
		 * loop. mlock() can compact, and compaction coalesces free
		 * pages back into high-order blocks. Measuring first and
		 * pinning afterwards let the loop break with
		 * stop=order7-depleted while the pin itself rebuilt order-7
		 * blocks -- runs reached ready=1 with
		 * high_order_7plus=0->26->1 and exhausted=0, so the two
		 * flags disagreed and the drill flapped between PASS and
		 * INCONCLUSIVE on the same bytes. Locking here means the
		 * next iteration's buddy check sees exactly the state this
		 * chunk left behind, and a loop that ends with
		 * stop=order7-depleted is a state that still holds.
		 *
		 * The pin also has to stay for the hole punch: compaction
		 * must not migrate survivors into the gaps and rebuild high
		 * orders under us.
		 */
		if (mlock(m, FRAG_CHUNK) != 0) {
			int saved_errno = errno;

			munmap(m, FRAG_CHUNK);
			printf("FRAGMENT_BUDDY ready=0 reason=main-mlock-failed errno=%d\n",
			       saved_errno);
			fflush(stdout);
			rc = 3;
			goto cleanup;
		}
		locked++;
		maps[i] = m;
		got++;
	}
	/* One final check: the loop may have stopped on the ceiling. */
	if (stopped == 0 && buddy_blocks_at_or_above(7) == 0) {
		stopped = 1;
		stop_reason = "order7-depleted";
	}
	high_locked = buddy_blocks_at_or_above(7);
	high_locked_pages = buddy_pages_at_or_above(7);
	printf("FRAGMENT_BUDDY allocated chunks=%ld high_order_7plus=%ld->%ld high_order_7plus_pages=%ld->%ld locked=%ld stop=%s\n",
	       got, high_before, high_locked, high_before_pages,
	       high_locked_pages, locked, stop_reason);
	fflush(stdout);

	pmfd = open("/proc/self/pagemap", O_RDONLY);
	if (pmfd < 0) {
		printf("FRAGMENT_BUDDY ready=0 pagemap=0 reason=open:%s\n",
		       strerror(errno));
		fflush(stdout);
		rc = 2;
		goto cleanup;
	}

	/* Pass 1: collect every PFN we own and the high-water mark. */
	for (i = 0; i < got; i++) {
		char *m = maps[i];
		if (frag_release_requested(release_file)) {
			rc = frag_stop_signal ? 128 + frag_stop_signal : 3;
			goto cleanup;
		}

		for (off = 0; off < FRAG_CHUNK; off += FRAG_PAGE) {
			unsigned long pfn;

			if (pagemap_pfn(pmfd, m + off, &pfn) != 0) {
				no_pfn++;
				continue;
			}
			pfns[i * (FRAG_CHUNK / FRAG_PAGE) + off / FRAG_PAGE] =
				pfn + 1; /* 0 means "no pfn" in the array */
			if (pfn > max_pfn)
				max_pfn = pfn;
		}
	}

	if (no_pfn > 0 || max_pfn == 0) {
		printf("FRAGMENT_BUDDY ready=0 pagemap=0 no_pfn=%ld reason=pfn-incomplete\n",
		       no_pfn);
		fflush(stdout);
		rc = 2;
		goto cleanup;
	}

	/*
	 * Size the held bitmap from the highest PFN observed in the main
	 * pattern. MemTotal counts installed pages, not the highest physical
	 * PFN, so it is not a safe bound when the guest has physical-address
	 * holes. The chase can use still-higher PFNs; the setter grows the
	 * bitmap with overflow checks as those pages are observed.
	 */
	if (max_pfn / (sizeof(*seen) * CHAR_BIT) >=
	    SIZE_MAX / sizeof(*seen)) {
		printf("FRAGMENT_BUDDY ready=0 reason=pfn-bitmap-size-overflow\n");
		fflush(stdout);
		rc = 3;
		goto cleanup;
	}
	seen_words = (size_t)(max_pfn / (sizeof(*seen) * CHAR_BIT)) + 1;
	seen = calloc(seen_words, sizeof(*seen));
	if (!seen) {
		printf("HELPER calloc pfn-set: %s\n", strerror(errno));
		fflush(stdout);
		goto cleanup;
	}
	for (i = 0; i < got * (FRAG_CHUNK / FRAG_PAGE); i++) {
		if (frag_release_requested(release_file)) {
			rc = frag_stop_signal ? 128 + frag_stop_signal : 3;
			goto cleanup;
		}
		if (pfns[i] &&
		    pfn_bitmap_set(&seen, &seen_words, pfns[i] - 1)) {
			printf("FRAGMENT_BUDDY ready=0 reason=pfn-bitmap-growth-failed\n");
			fflush(stdout);
			rc = 3;
			goto cleanup;
		}
	}

	/*
	 * Chase first, punch after. The punch used to run before the chase,
	 * and that ordering is what stopped the chase from splitting anything:
	 * the 4096 holes are isolated order-0 pages, an allocator serves
	 * order-0 before it splits, and run 36811867648's chase took exactly
	 * 254 chunks x 16 pages = 15.9 MiB of them and then hit the unsplit
	 * floor with high_order_7plus still at 9. The fuel drained, the
	 * high-order blocks were never touched.
	 *
	 * Punching after means the chase faults into an untouched margin whose
	 * only free memory is the order-0-and-up the main loop left behind.
	 * The small-order residue goes first, and then every subsequent chunk
	 * is a split of an order-7-and-up block. It also keeps the bounded
	 * channel-open reserve out of the chase's RSS: that reserve is released
	 * later, which is the point of the holes in the first place.
	 *
	 * Chase: split the high-order blocks the main loop's margin left
	 * behind. Checked every chunk, against the same measured condition as
	 * the main loop. Stops at the measured order-7 reserve, then on the
	 * unsplit floor, then on the MemFree backstop, then on the cap. Still unpinned: if
	 * this is where the guest runs out, the OOM killer takes us and the
	 * drill reports INCONCLUSIVE_NO_PATTERN instead of panicking.
	 */
	for (i = 0; i < FRAG_CHASE_CAP; i++) {
		char *m;
		long high, high_pages, unsplit;

		if (frag_release_requested(release_file)) {
			rc = frag_stop_signal ? 128 + frag_stop_signal : 3;
			goto cleanup;
		}

		high = buddy_blocks_at_or_above(7);
		high_pages = buddy_pages_at_or_above(7);
		if (high < 0 || high_pages < 0) {
			printf("FRAGMENT_BUDDY ready=0 reason=chase-buddyinfo-unavailable\n");
			fflush(stdout);
			rc = 3;
			goto cleanup;
		}
		if (high == 0) {
			stopped = 1;
			stop_reason = "order7-depleted";
			break;
		}

		unsplit = unsplit_free_pages();
		unsplit_at_stop = unsplit;
		if (unsplit >= 0 && unsplit < FRAG_CHASE_UNSPLIT) {
			stopped = 1;
			stop_reason = "chase-unsplit-floor";
			break;
		}

		free_kb = mem_free_kb();
		wmark_kb = live_min_watermark_kb();
		floor_kb = FRAG_CHASE_HARD_KB;
		if (min_free_set > 0 &&
		    min_free_set + FRAG_CHASE_WMARK_MARGIN > floor_kb)
			floor_kb = min_free_set + FRAG_CHASE_WMARK_MARGIN;
		if (frag_should_preserve_order7(high, high_pages)) {
			stopped = 1;
			stop_reason = "chase-order7-reserve";
			break;
		}
		if (free_kb >= 0 && free_kb < floor_kb) {
			stopped = 1;
			stop_reason = "chase-memfree-margin";
			break;
		}

		m = mmap(NULL, FRAG_CHUNK, PROT_READ | PROT_WRITE,
			 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (m == MAP_FAILED) {
			stopped = 1;
			stop_reason = "chase-mmap-refused";
			break;
		}
		for (off = 0; off < FRAG_CHUNK; off += FRAG_PAGE)
			m[off] = 1;
		if (mlock(m, FRAG_CHUNK) != 0) {
			int saved_errno = errno;

			munmap(m, FRAG_CHUNK);
			printf("FRAGMENT_BUDDY ready=0 reason=chase-mlock-failed errno=%d\n",
			       saved_errno);
			fflush(stdout);
			rc = 3;
			goto cleanup;
		}
		chase_locked++;
		chase_maps[chase++] = m;
		/*
		 * Hold every page. No recycle here: the recycled pages came
		 * back as isolated order-0 and the next chunk's faults took
		 * those first (__rmqueue_smallest drains order-0 before it
		 * splits), so the chase split almost nothing and the
		 * high-order blocks survived untouched. Holding is what
		 * forces the split -- a held page is gone from every list
		 * the allocator can serve, so the next fault has to come out
		 * of a block that is still free. pmfd is open across this
		 * loop; it is used below to record what is held, and by
		 * pass 2 to punch the room the ring needs.
		 */
		/*
		 * Every page of this chunk is a survivor and becomes a held
		 * partner for pass 2. The bitmap must only ever gain pages
		 * that are still mapped: a freed page sitting in it as if it
		 * were held would let a later lookup release its buddy into
		 * a pair that can coalesce and rebuild the high orders just
		 * drained.
		 */
		if (pmfd >= 0) {
			for (off = 0; off < FRAG_CHUNK; off += FRAG_PAGE) {
				unsigned long spfn = 0;

				if (pagemap_pfn(pmfd, m + off, &spfn) == 0 &&
				    spfn &&
				    pfn_bitmap_set(&seen, &seen_words, spfn)) {
					printf("FRAGMENT_BUDDY ready=0 reason=pfn-bitmap-growth-failed\n");
					fflush(stdout);
					rc = 3;
					goto cleanup;
				}
			}
		}
	}
	chase_free_kb = free_kb;
	chase_wmark_kb = wmark_kb;
	chase_floor_kb = floor_kb;

	/*
	 * Pass 2: unmap every page whose PFN is even and whose buddy (pfn+1)
	 * is also ours and will be held. A freed page's buddy is then always
	 * held, so nothing above order-0 can coalesce and the survivors still
	 * serve order-0 requests. Pages whose buddy is not ours are held:
	 * freeing them could pair with leftover free memory and rebuild the
	 * high orders we just drained.
	 *
	 * The property is what matters, not the density. Discarding the resident
	 * backing keeps each VMA intact and avoids allocating VMA metadata from
	 * the same compound-page reserve the channel-open test needs. The 128 MiB
	 * cap funds hv_netvsc buffers plus guest headroom; held buddies keep
	 * order-7 from reforming. If the cap cannot produce the measured reserve,
	 * fail closed. The discarded virtual pages are never touched again before
	 * the whole mappings are released during cleanup.
	 */
	for (i = 0; i < got && freed_pages < FRAG_HOLE_CAP; i++) {
		char *m = maps[i];
		if (frag_release_requested(release_file)) {
			rc = frag_stop_signal ? 128 + frag_stop_signal : 3;
			goto cleanup;
		}

		for (off = 0; off < FRAG_CHUNK && freed_pages < FRAG_HOLE_CAP;
		     off += FRAG_PAGE) {
			unsigned long pfn =
				pfns[i * (FRAG_CHUNK / FRAG_PAGE) + off / FRAG_PAGE];

			if (!pfn) {
				held_pages++;
				continue;
			}
			/*
			 * seen[x] means the page with actual PFN x is held.
			 * Since pfns[] stores actual PFN+1, an even page n is
			 * eligible only when bit n+1 proves its true odd buddy
			 * is held. Freeing only the even member prevents that
			 * pair from coalescing, including when its buddy came
			 * from the chase mappings.
			 */
			if (frag_page_has_held_buddy(pfn, seen, seen_words)) {
				int discard = frag_discard_locked_pages(pmfd, m + off,
								(size_t)FRAG_PAGE);

				if (discard) {
					printf("FRAGMENT_BUDDY hole-discard-failed status=%d errno=%d\n",
					       discard, errno);
					fflush(stdout);
					rc = 3;
					goto cleanup;
				}
				freed_pages++;
				pairs++;
			} else {
				held_pages++;
			}
		}
	}
	if (stopped == 0 && buddy_blocks_at_or_above(7) == 0) {
		stopped = 1;
		stop_reason = "order7-depleted";
	}

	high_after = buddy_blocks_at_or_above(7);
	high_after_pages = buddy_pages_at_or_above(7);
	/*
	 * Releasing the bounded order-0 holes can expose buddy coalescing that
	 * was not visible at the chase stop. If that leaves more than the
	 * measured reserve, consume additional chunks while the same free,
	 * watermark, and unsplit floors still permit it. The extra chunks stay
	 * pinned through the channel-open measurement and are reclaimed only by
	 * the normal cleanup path.
	 */
	if (frag_should_refine_order7(high_after, high_after_pages)) {
		long refined = 0;

		for (;;) {
			char *m;
			long high, high_pages, unsplit;

			if (frag_release_requested(release_file)) {
				rc = frag_stop_signal ? 128 + frag_stop_signal : 3;
				goto cleanup;
			}
			high = buddy_blocks_at_or_above(7);
			high_pages = buddy_pages_at_or_above(7);
			if (high < 0 || high_pages < 0) {
				printf("FRAGMENT_BUDDY ready=0 reason=refine-buddyinfo-unavailable\n");
				fflush(stdout);
				rc = 3;
				goto cleanup;
			}
			high_after = high;
			high_after_pages = high_pages;
			if (high == 0) {
				stop_reason = "order7-depleted";
				break;
			}

			unsplit = unsplit_free_pages();
			unsplit_at_stop = unsplit;
			if (unsplit >= 0 && unsplit < FRAG_CHASE_UNSPLIT) {
				stop_reason = "chase-unsplit-floor";
				break;
			}

			free_kb = mem_free_kb();
			wmark_kb = live_min_watermark_kb();
			floor_kb = FRAG_CHASE_HARD_KB;
			if (min_free_set > 0 &&
			    min_free_set + FRAG_CHASE_WMARK_MARGIN > floor_kb)
				floor_kb = min_free_set + FRAG_CHASE_WMARK_MARGIN;
			chase_free_kb = free_kb;
			chase_wmark_kb = wmark_kb;
			chase_floor_kb = floor_kb;
			if (frag_should_preserve_order7(high, high_pages)) {
				stopped = 1;
				stop_reason = "chase-order7-reserve";
				break;
			}
			if (free_kb >= 0 && free_kb < floor_kb) {
				stop_reason = "chase-memfree-margin";
				break;
			}
			if (chase >= FRAG_CHASE_CAP) {
				stop_reason = "chase-cap";
				break;
			}

			m = mmap(NULL, FRAG_CHUNK, PROT_READ | PROT_WRITE,
				 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
			if (m == MAP_FAILED) {
				stop_reason = "chase-mmap-refused";
				break;
			}
			for (off = 0; off < FRAG_CHUNK; off += FRAG_PAGE)
				m[off] = 1;
			if (mlock(m, FRAG_CHUNK) != 0) {
				int saved_errno = errno;

				munmap(m, FRAG_CHUNK);
				printf("FRAGMENT_BUDDY ready=0 reason=refine-mlock-failed errno=%d\n",
				       saved_errno);
				fflush(stdout);
				rc = 3;
				goto cleanup;
			}
			chase_maps[chase++] = m;
			chase_locked++;
			refined++;
		}
		high_after = buddy_blocks_at_or_above(7);
		high_after_pages = buddy_pages_at_or_above(7);
		printf("FRAGMENT_BUDDY refine=%ld high_order_7plus=%ld high_order_7plus_pages=%ld stop=%s\n",
		       refined, high_after, high_after_pages, stop_reason);
		fflush(stdout);
	}
	printf("FRAGMENT_BUDDY chase=%ld locked=%ld holes=%ld pairs=%ld high_order_7plus=%ld->%ld high_order_7plus_pages=%ld->%ld\n",
	       chase, chase_locked, chase_holes, chase_pairs, high_locked,
	       high_after, high_locked_pages, high_after_pages);
	fflush(stdout);
	if (frag_release_requested(release_file)) {
		rc = frag_stop_signal ? 128 + frag_stop_signal : 3;
		goto cleanup;
	}

	/*
	 * Return order-2 stacks before ready=1. The current shell parser uses
	 * builtins, but channel setup and recovery still need compound-page
	 * headroom. Earlier runs lost the shell when copy_process() found no
	 * order-2 block; the guest then panicked before evidence was written.
	 *
	 * Returning the groups first does not weaken the measured claim.
	 * high_order_7plus counts orders 7 and up; order-2 blocks are
	 * invisible to it. Each group is eight consecutive PFNs aligned to
	 * an order-3 boundary. Its first four pages are unmapped while the
	 * last four stay held, so the freed order-2 half cannot coalesce
	 * with a free order-2 buddy and rebuild order-7 blocks.
	 */
	for (i = 0; i < reserve_got && order2_groups < FRAG_ORDER2_GROUPS; i++) {
		char *m = reserve[i];
		if (frag_release_requested(release_file)) {
			rc = frag_stop_signal ? 128 + frag_stop_signal : 3;
			goto cleanup;
		}

		off = 0;
		while (off + 8 * FRAG_PAGE <= FRAG_RESERVE_CHUNK &&
		       order2_groups < FRAG_ORDER2_GROUPS) {
			unsigned long p0 = 0, p = 0, align_skip;
			int run = 1, j;

			if (pagemap_pfn(pmfd, m + off, &p0) != 0) {
				off += FRAG_PAGE;
				continue;
			}
			/*
			 * Walk to the next 8-page-aligned PFN, not to the next
			 * 8-page virtual step. mmap faults order-0 pages, so a
			 * chunk whose first PFN is misaligned keeps that residue
			 * at every 8-page virtual step. Advance by the physical
			 * PFN residue to reach the next order-3 boundary.
			 */
			align_skip = frag_order2_group_alignment_skip(p0);
			if (align_skip) {
				off += align_skip * FRAG_PAGE;
				continue;
			}
			for (j = 1; j < 8; j++) {
				if (pagemap_pfn(pmfd, m + off + j * FRAG_PAGE, &p) != 0 ||
					p != p0 + (unsigned long)j) {
					run = 0;
					break;
				}
			}
			if (!run) {
				off += 4 * FRAG_PAGE;
				continue;
			}
			/*
			 * One backing discard of the whole 16 KiB run, not four
			 * separate operations. The intent is that the four pages
			 * are freed together and, once the PCP drains, coalesce as an
			 * order-2 block whose buddy (the held half) prevents
			 * further growth. That drain is NOT guaranteed here: a
			 * 16 KiB discard still frees four order-0 folios into the
			 * per-cpu page cache, and run 36934739215 (and 36940519876
			 * with stacks=504) showed the shell's next fork --
			 * copy_process wants THREAD_SIZE_ORDER, an order-2 page --
			 * finding 0*16kB free with thousands of order-0 pages
			 * parked in the PCP, then dying on "System is deadlocked
			 * on memory". The shell is fork-free until teardown for
			 * that reason; this loop is belt and braces for anything
			 * that must clone anyway.
			 */
			{
				int discard = frag_discard_locked_pages(
					pmfd, m + off, (size_t)(4 * FRAG_PAGE));

				if (discard) {
					printf("FRAGMENT_BUDDY order2-discard-failed status=%d errno=%d\n",
					       discard, errno);
					fflush(stdout);
					rc = 3;
					goto cleanup;
				}
				order2_pages += 4;
			}
			order2_groups++;
			off += 8 * FRAG_PAGE;
		}
	}
	if (frag_release_requested(release_file)) {
		rc = frag_stop_signal ? 128 + frag_stop_signal : 3;
		goto cleanup;
	}
	/*
	 * What the buddy actually holds of order-2 now. If the PCP
	 * swallowed the discarded pages this reads 0 and the shell must not
	 * fork; if it drained, this is the true forkable count. The
	 * discarded group count is reported separately and is never a
	 * forkability claim.
	 */
	order2_buddy = buddy_blocks_at_or_above(2);
	printf("FRAGMENT_BUDDY order2_reserve groups=%ld pages=%ld reserve=%ld buddy_order2=%ld\n",
	       order2_groups, order2_pages, reserve_got, order2_buddy);
	fflush(stdout);
	if (frag_recover_runtime_reserve(pmfd, maps, got, chase_maps, chase,
					 reserve, reserve_got, &seen, &seen_words,
					 release_file, &recovery_pages,
					 &recovery_scanned, &free_kb, &wmark_kb,
					 &high_after, &high_after_pages)) {
		rc = frag_stop_signal ? 128 + frag_stop_signal : 3;
		goto cleanup;
	}
	order2_buddy = buddy_blocks_at_or_above(2);
	if (free_kb >= 0 && wmark_kb >= 0 && free_kb >= wmark_kb)
		free_above_wmark_kb = free_kb - wmark_kb;
	if (!frag_runtime_reserve_qualified(FRAG_HOLE_CAP, freed_pages,
					    free_above_wmark_kb, order2_buddy)) {
		printf("FRAGMENT_BUDDY ready=0 reason=runtime-reserve-insufficient\n");
		printf("FRAGMENT_BUDDY reserve freed=%ld required_holes=%ld\n",
		       freed_pages, FRAG_RUNTIME_MIN_HOLE_PAGES);
		printf("FRAGMENT_BUDDY reserve free_kb=%ld above_wmark_kb=%ld\n",
		       free_kb, free_above_wmark_kb);
		printf("FRAGMENT_BUDDY reserve required_free_kb=%ld wmark_kb=%ld\n",
		       FRAG_RUNTIME_MIN_FREE_KB, wmark_kb);
		printf("FRAGMENT_BUDDY reserve order2=%ld required_order2=%ld\n",
		       order2_buddy, FRAG_RUNTIME_MIN_ORDER2_BLOCKS);
		fflush(stdout);
		rc = 3;
		goto cleanup;
	}

	/*
	 * `exhausted` remains the strict raw-count result. `bounded` is a
	 * separate ordinary-path qualification and never rewrites that count.
	 * Do not pin or admit a pattern that lost its measured order-7 safety
	 * reserve during the hole phase.
	 */
	bounded = frag_bounded_pressure_qualified(high_before_pages,
						  high_after_pages,
						  stop_reason, 1,
							  chase_free_kb >= 0 &&
							  chase_wmark_kb >= 0 &&
							  chase_free_kb >= chase_wmark_kb);
	if (!bounded) {
		printf("FRAGMENT_BUDDY ready=0 reason=bounded-pressure-unqualified exhausted=%ld stop=%s ",
		       high_after == 0 ? 1L : 0L, stop_reason);
		printf("high_order_7plus=%ld->%ld->%ld ",
		       high_before, high_locked, high_after);
		printf("high_order_7plus_pages=%ld->%ld->%ld\n",
		       high_before_pages, high_locked_pages, high_after_pages);
		fflush(stdout);
		rc = 3;
		goto cleanup;
	}

	/* Pin only after both measured reserve contracts qualify. */
	if (set_oom_adj(-1000) || oom_score_adj_read() != -1000) {
		printf("FRAGMENT_BUDDY ready=0 reason=oom-score-pin-failed\n");
		fflush(stdout);
		rc = 3;
		goto cleanup;
	}

	printf("FRAGMENT_BUDDY ready=1 bounded=%d chunks=%ld pages=%ld ",
	       bounded, got, got * (FRAG_CHUNK / FRAG_PAGE));
	printf("held=%ld freed=%ld locked=%ld pairs=%ld chunk_kib=64 ",
	       held_pages, freed_pages, locked, pairs);
	printf("cap_chunks=%ld hole_cap=%ld chase=%ld chase_holes=%ld ",
	       want, FRAG_HOLE_CAP, chase, chase_holes);
	printf("chase_pairs=%ld unsplit=%ld exhausted=%ld pagemap=1 ",
	       chase_pairs, unsplit_at_stop, high_after == 0 ? 1L : 0L);
	printf("groups=%ld buddy_order2=%ld pcp_high_fraction=%ld stop=%s ",
	       order2_groups, order2_buddy, pcp_high_fraction_now, stop_reason);
	printf("high_order_7plus=%ld->%ld->%ld ",
	       high_before, high_locked, high_after);
	printf("high_order_7plus_pages=%ld->%ld->%ld ",
	       high_before_pages, high_locked_pages, high_after_pages);
	printf("floor_kb=%ld wmark_kb=%ld free_kb=%ld ",
	       floor_kb, wmark_kb, free_kb);
	printf("chase_floor_kb=%ld chase_wmark_kb=%ld chase_free_kb=%ld\n",
	       chase_floor_kb, chase_wmark_kb, chase_free_kb);
	fflush(stdout);

	/*
	 * The watermarks stay where the pattern put them -- min_free_kbytes
	 * at 512 and watermark_boost_factor at 0 -- for the whole hold,
	 * including the drill's channel-open exercise. Restoring them here
	 * is what killed run 36906731699: with ~2 GiB locked and this
	 * process pinned at -1000, writing back min=5704 and boost_factor
	 * 15000 let boost_watermark() rebuild a 14712 kB boost against
	 * 9764 kB free. wmark_pages() adds boost on top of min, so the
	 * effective mark was 20416 kB, every GFP_HIGHUSER_MOVABLE fault
	 * failed, out_of_memory() found no killable process, and the guest
	 * panicked on "System is deadlocked on memory". The variable under
	 * test is fragmentation, not the reserve; a 20 MB watermark against
	 * a 9 MB free guest makes the test impossible regardless of the ring
	 * code. Restore only after the munmaps have given the memory back.
	 */
	if (hold > 0)
		frag_wait_for_release(release_file, hold);
	rc = got > 1 ? 0 : 1;

cleanup:
	/* Restore memory before raising the reserve; this keeps the known-safe
	 * ordering even on setup failures and orderly termination signals. */
	if (oom_score_adj_read() != 0)
		set_oom_adj(0);
	for (i = 0; i < got; i++)
		if (maps && maps[i])
			munmap(maps[i], FRAG_CHUNK);
	for (i = 0; i < chase; i++)
		if (chase_maps && chase_maps[i])
			munmap(chase_maps[i], FRAG_CHUNK);
	for (i = 0; i < reserve_got; i++)
		munmap(reserve[i], FRAG_RESERVE_CHUNK);
	for (i = 0; i < soak_got; i++)
		munmap(soak[i], FRAG_PCP_SOAK_CHUNK);
	free(seen);
	free(maps);
	free(pfns);
	free(chase_maps);
	if (pmfd >= 0)
		close(pmfd);

	/* The memory is back before either reserve setting is restored. Read it
	 * back so the caller can fail closed if the original values did not stick. */
	if (map_count_changed)
		max_map_count_write(map_count_saved);
	if (min_free_changed)
		min_free_kb_write(min_free_saved);
	if (boost_changed)
		boost_factor_write(boost_saved);
	if (pcp_high_fraction_changed)
		pcp_high_fraction_write(pcp_high_fraction_saved);
	if (oom_score_adj_saved != LONG_MIN &&
	    oom_score_adj_read() != oom_score_adj_saved)
		set_oom_adj(oom_score_adj_saved);
	map_count_now = max_map_count_read();
	min_free_now = min_free_kb_read();
	boost_now = boost_factor_read();
	pcp_high_fraction_now = pcp_high_fraction_read();
	oom_score_adj_now = oom_score_adj_read();
	restore_ok = map_count_saved >= 0 && min_free_saved >= 0 &&
		     boost_saved >= 0 && pcp_high_fraction_saved >= 0 &&
		     oom_score_adj_saved != LONG_MIN &&
		     map_count_now == map_count_saved &&
		     min_free_now == min_free_saved &&
		     boost_now == boost_saved &&
		     pcp_high_fraction_now == pcp_high_fraction_saved &&
		     oom_score_adj_now == oom_score_adj_saved;
	if (restore_ok) {
		printf("FRAGMENT_BUDDY teardown max_map_count_saved=%ld max_map_count_now=%ld ",
		       map_count_saved, map_count_now);
		printf("min_free_kbytes_saved=%ld min_free_kbytes_now=%ld ",
		       min_free_saved, min_free_now);
		printf("watermark_boost_factor_saved=%ld watermark_boost_factor_now=%ld ",
		       boost_saved, boost_now);
		printf("pcp_high_fraction_saved=%ld pcp_high_fraction_now=%ld ",
		       pcp_high_fraction_saved, pcp_high_fraction_now);
		printf("oom_score_adj_saved=%ld oom_score_adj_now=%ld restored=yes\n",
		       oom_score_adj_saved, oom_score_adj_now);
	} else {
		printf("FRAGMENT_BUDDY teardown max_map_count_saved=%ld max_map_count_now=%ld ",
		       map_count_saved, map_count_now);
		printf("min_free_kbytes_saved=%ld min_free_kbytes_now=%ld ",
		       min_free_saved, min_free_now);
		printf("watermark_boost_factor_saved=%ld watermark_boost_factor_now=%ld ",
		       boost_saved, boost_now);
		printf("pcp_high_fraction_saved=%ld pcp_high_fraction_now=%ld ",
		       pcp_high_fraction_saved, pcp_high_fraction_now);
		printf("oom_score_adj_saved=%ld oom_score_adj_now=%ld restored=no\n",
		       oom_score_adj_saved, oom_score_adj_now);
		rc = 1;
	}
	printf("FRAGMENT_BUDDY released held=%ld freed=%ld chase_holes=%ld status=%d\n",
	       held_pages, freed_pages, chase_holes, rc);
	fflush(stdout);
	return rc;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: vmbus_drill_helper mmap-hold <path> <bytes> <hold_seconds> [count] [release_file]\n"
		"       vmbus_drill_helper mlock-hog <mib> <hold_seconds>\n"
		"       vmbus_drill_helper fragment-buddy <mib> <hold_seconds> [release_file] [pid_file]\n"
		"       vmbus_drill_helper owner-channel-check <trace> <channel-ids> <reclaimed|active>\n");
}

/*
 * Die with the caller. Every mode holds memory -- a UIO mapping, a locked
 * hog, a buddy pattern -- that must not outlive the process that asked for
 * it. The drills run as children of a shell the OOM killer is free to take:
 * fragment-buddy pins itself at -1000 precisely so that shell is the only
 * killable task left, and 36982941081 is what that does when a rebind slab
 * allocation OOMs. The shell cannot run a trap on SIGKILL, so its teardown
 * never kills the hog, the hog is reparented and keeps the guest out of
 * memory, and init's next fork is copy_process() looking for an order-2
 * stack with "no killable processes" -- a guest panic.
 *
 * PR_SET_PDEATHSIG with SIGKILL cannot be caught, blocked or ignored, and
 * it fires on any parent death including a normal exit that skipped the
 * teardown. Fail closed if it cannot be armed: holding memory without the
 * guarantee is the bug being fixed. The getppid() re-read closes the
 * fork-to-prctl race: if the caller died in that window the signal is never
 * delivered and this process would be orphaned anyway.
 */
static int arm_parent_death(void)
{
	pid_t ppid = getppid();

	if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0) {
		fprintf(stderr, "PR_SET_PDEATHSIG: %s\n", strerror(errno));
		return -1;
	}
	if (getppid() != ppid) {
		fprintf(stderr, "caller exited before PR_SET_PDEATHSIG\n");
		return -1;
	}
	return 0;
}

int main(int argc, char **argv)
{
	if (arm_parent_death())
		return 2;
	if (argc < 2) {
		usage();
		return 2;
	}
	if (strcmp(argv[1], "mmap-hold") == 0)
		return do_mmap_hold(argc - 1, argv + 1);
	if (strcmp(argv[1], "mlock-hog") == 0)
		return do_mlock_hog(argc - 1, argv + 1);
	if (strcmp(argv[1], "fragment-buddy") == 0)
		return do_fragment_buddy(argc - 1, argv + 1);
	if (strcmp(argv[1], "owner-channel-check") == 0)
		return do_owner_channel_check(argc - 1, argv + 1);
	usage();
	return 2;
}
