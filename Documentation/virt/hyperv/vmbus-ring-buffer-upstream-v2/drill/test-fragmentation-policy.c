#define main vmbus_drill_helper_main
#include "vmbus_drill_helper.c"
#undef main

#include <assert.h>

static int check_owner_fixture(const char *text, const uint64_t *channels,
			       size_t channel_count, int require_active,
			       struct owner_check_stats *stats)
{
	const char *reason = NULL;
	FILE *trace = fmemopen((void *)text, strlen(text), "r");
	int rc;

	assert(trace);
	rc = owner_check_stream(trace, channels, channel_count, require_active,
				stats, &reason);
	fclose(trace);
	return rc;
}

int main(void)
{
	static const uint64_t target_channels[] = { 14, 15 };
	static const char valid_reclaimed[] =
		"worker-1 [000] .... 1.000: vmbus_buffer_owner: owner_id=1 channel_id=14 action=created size=0 pages=0 state=0\n"
		"worker-1 [000] .... 1.001: vmbus_buffer_owner: owner_id=1 channel_id=14 action=released size=4096 pages=1 state=0\n"
		"worker-1 [000] .... 1.002: vmbus_buffer_owner: owner_id=1 channel_id=14 action=retained size=4096 pages=1 state=1\n"
		"worker-1 [000] .... 1.003: vmbus_buffer_owner: owner_id=1 channel_id=14 action=reclaimed size=4096 pages=1 state=0\n"
		"worker-1 [000] .... 1.004: vmbus_buffer_owner: owner_id=2 channel_id=15 action=created size=0 pages=0 state=0\n"
		"worker-1 [000] .... 1.005: vmbus_buffer_owner: owner_id=2 channel_id=15 action=discarded size=0 pages=0 state=0\n"
		"worker-1 [000] .... 1.006: vmbus_buffer_owner: owner_id=3 channel_id=99 action=created size=0 pages=0 state=0\n";
	static const char active_owner[] =
		"worker-1 [000] .... 1.000: vmbus_buffer_owner: owner_id=8 channel_id=14 action=created size=0 pages=0 state=0\n";
	static const char released_owner[] =
		"worker-1 [000] .... 1.000: vmbus_buffer_owner: owner_id=12 channel_id=14 action=created size=0 pages=0 state=0\n"
		"worker-1 [000] .... 1.001: vmbus_buffer_owner: owner_id=12 channel_id=14 action=released size=4096 pages=1 state=0\n";
	static const char retained_owner[] =
		"worker-1 [000] .... 1.000: vmbus_buffer_owner: owner_id=9 channel_id=14 action=created size=0 pages=0 state=0\n"
		"worker-1 [000] .... 1.001: vmbus_buffer_owner: owner_id=9 channel_id=14 action=released size=4096 pages=1 state=1\n"
		"worker-1 [000] .... 1.002: vmbus_buffer_owner: owner_id=9 channel_id=14 action=retained size=4096 pages=1 state=4\n";
	static const char invalid_transition[] =
		"worker-1 [000] .... 1.000: vmbus_buffer_owner: owner_id=10 channel_id=14 action=created size=0 pages=0 state=0\n"
		"worker-1 [000] .... 1.001: vmbus_buffer_owner: owner_id=10 channel_id=14 action=reclaimed size=4096 pages=1 state=0\n";
	static const char malformed_owner[] =
		"worker-1 [000] .... 1.000: vmbus_buffer_owner: owner_id=bad channel_id=14 action=created size=0 pages=0 state=0\n";
	static const char unrelated_owner[] =
		"worker-1 [000] .... 1.000: vmbus_buffer_owner: owner_id=11 channel_id=99 action=created size=0 pages=0 state=0\n";
	struct owner_check_stats owner_stats;
	const long hole_cap = FRAG_HOLE_CAP;
	const long min_holes = FRAG_RUNTIME_MIN_HOLE_PAGES;
	const long usable_kb = FRAG_RUNTIME_MIN_FREE_KB;
	const long min_order2 = FRAG_RUNTIME_MIN_ORDER2_BLOCKS;
	long recovery_needed;
	unsigned long *seen = calloc(1, sizeof(*seen));
	size_t seen_words = 1;
	const unsigned long distant_pfn = 64UL * 9000UL + 3UL;

	assert(seen);
	/* A PFN above the initial allocation grows the bitmap without overruns. */
	assert(pfn_bitmap_set(&seen, &seen_words, distant_pfn) == 0);
	assert(seen_words > 1);
	assert(pfn_bitmap_get(seen, seen_words, distant_pfn));
	assert(!pfn_bitmap_get(seen, seen_words, distant_pfn + 1));
	free(seen);

	/* PFN+1 encoding releases only an even page with its odd buddy held. */
	seen_words = 2;
	seen = calloc(seen_words, sizeof(*seen));
	assert(seen);
	assert(pfn_bitmap_set(&seen, &seen_words, 101) == 0);
	assert(frag_page_has_held_buddy(101, seen, seen_words)); /* PFN 100 */
	assert(!frag_page_has_held_buddy(102, seen, seen_words)); /* PFN 101 */
	free(seen);
	seen_words = 2;
	seen = calloc(seen_words, sizeof(*seen));
	assert(seen);
	assert(pfn_bitmap_set(&seen, &seen_words, 99) == 0);
	assert(!frag_page_has_held_buddy(101, seen, seen_words));
	free(seen);
	/* The retained half must be the order-2 buddy within one order-3 block. */
	assert(frag_order2_group_alignment_skip(0) == 0);
	assert(frag_order2_group_alignment_skip(4) == 4);
	assert(frag_order2_group_alignment_skip(7) == 1);
	assert(frag_order2_group_alignment_skip(8) == 0);
	assert(frag_order2_group_alignment_skip(15) == 1);

	/* The pre-open stop retains up to four measured minimum order-7 blocks. */
	assert(frag_bounded_pressure_qualified(500000, 128,
						       "chase-memfree-margin", 1, 1));
	assert(frag_bounded_pressure_qualified(500000, 256,
						       "chase-memfree-margin", 1, 1));
	assert(frag_bounded_pressure_qualified(500000, 512,
						       "chase-memfree-margin", 1, 1));
	assert(frag_bounded_pressure_qualified(500000, 128,
						       "order7-reserve", 1, 1));
	assert(frag_bounded_pressure_qualified(500000, 128,
						       "chase-order7-reserve", 1, 1));
	assert(frag_bounded_pressure_qualified(25600, 256,
						       "chase-memfree-margin", 1, 1));
	assert(frag_bounded_pressure_qualified(25700, 256,
						       "chase-memfree-margin", 1, 1));

	/* Saturation, larger residue, unsafe stop, or missing PFN stays unqualified. */
	assert(!frag_bounded_pressure_qualified(500000, 0,
							"order7-depleted", 1, 1));
	assert(frag_bounded_pressure_qualified(500000, 257,
						       "chase-memfree-margin", 1, 1));
	assert(!frag_bounded_pressure_qualified(500000, 513,
							"chase-memfree-margin", 1, 1));
	assert(!frag_bounded_pressure_qualified(25600, 257,
							"chase-memfree-margin", 1, 1));
	assert(!frag_bounded_pressure_qualified(25599, 256,
							"chase-memfree-margin", 1, 1));
	assert(!frag_bounded_pressure_qualified(500000, 128,
							"chase-mmap-refused", 1, 1));
	assert(!frag_bounded_pressure_qualified(500000, 128,
							"chase-memfree-margin", 0, 1));
	assert(!frag_bounded_pressure_qualified(500000, 128,
							"chase-memfree-margin", 1, 0));
	assert(!frag_bounded_pressure_qualified(500000, 128,
							"order7-depleted", 1, 1));
	assert(!frag_bounded_pressure_qualified(0, 0,
							"order7-depleted", 1, 1));
	assert(!frag_bounded_pressure_qualified(500000, 0,
							"chase-memfree-margin", 1, 1));

	assert(frag_should_preserve_order7(1, 128));
	assert(frag_should_preserve_order7(1, 256));
	assert(frag_should_preserve_order7(1, 512));
	assert(!frag_should_preserve_order7(0, 128));
	assert(!frag_should_preserve_order7(1, 513));
	assert(!frag_should_preserve_order7(1, 0));
	assert(!frag_should_refine_order7(1, 384));
	assert(!frag_should_refine_order7(1, 512));
	assert(frag_should_refine_order7(1, 513));
	assert(!frag_should_refine_order7(0, 384));
	assert(frag_pcp_high_fraction_qualified(FRAG_PCP_HIGH_FRACTION,
						FRAG_PCP_HIGH_FRACTION));
	assert(!frag_pcp_high_fraction_qualified(FRAG_PCP_HIGH_FRACTION,
						 FRAG_PCP_HIGH_FRACTION - 1));
	assert(!frag_pcp_high_fraction_qualified(7, 7));
	assert(!frag_pcp_high_fraction_qualified(-1, -1));
	/* Recovery keeps the 64 MiB watermark reserve and has a fixed cap. */
	assert(min_holes == FRAG_RUNTIME_RECOVERY_MAX_PAGES);
	recovery_needed = frag_recovery_pages_needed(10484, 640);
	assert(recovery_needed == 13923);
	assert(frag_recovery_pages_needed(66176, 640) == 0);
	assert(frag_recovery_pages_needed(640, 640) == min_holes);
	assert(frag_recovery_pages_needed(-1, 640) == -1);
	assert(frag_recovery_pages_needed(640, -1) == -1);
	/* Keep the channel-open hole budget large enough for netvsc buffers. */
	assert(hole_cap * FRAG_PAGE >= FRAG_HOLE_MIN_BYTES);
	assert(hole_cap <= FRAG_HOLE_MAX_CAP);
	/* The measured order-2 minimum must fit in the reserved PFN runs. */
	assert(FRAG_ORDER2_GROUPS <=
	       FRAG_RESERVE_CHUNKS * FRAG_RESERVE_CHUNK / (8 * FRAG_PAGE));
	assert(FRAG_RUNTIME_MIN_ORDER2_BLOCKS <= FRAG_ORDER2_GROUPS);
	assert(frag_runtime_reserve_qualified(hole_cap, min_holes, usable_kb,
					      min_order2));
	assert(!frag_runtime_reserve_qualified(min_holes, min_holes, usable_kb,
					       min_order2));
	assert(!frag_runtime_reserve_qualified(FRAG_HOLE_MAX_CAP + 1,
					       min_holes, usable_kb,
					       min_order2));
	assert(!frag_runtime_reserve_qualified(hole_cap, min_holes - 1,
					       usable_kb, min_order2));
	assert(!frag_runtime_reserve_qualified(hole_cap, min_holes,
					       usable_kb - 1, min_order2));
	assert(!frag_runtime_reserve_qualified(hole_cap, min_holes, usable_kb,
					       min_order2 - 1));
	assert(!frag_runtime_reserve_qualified(-1, -1, -1, -1));
	assert(!frag_release_requested("/nonexistent/vmbus-release-sentinel"));
	assert(frag_release_requested("/dev/null"));
	frag_stop_signal = SIGTERM;
	assert(frag_release_requested(NULL));
	frag_stop_signal = 0;

	/* Quiescence requires every target owner to reach a terminal state. */
	assert(check_owner_fixture(valid_reclaimed, target_channels,
				   sizeof(target_channels) / sizeof(target_channels[0]),
				   0, &owner_stats) == 0);
	assert(owner_stats.created == 2 && owner_stats.active == 0);
	assert(owner_stats.reclaimed == 1 && owner_stats.discarded == 1);
	assert(owner_stats.retained == 0);
	assert(check_owner_fixture(active_owner, target_channels,
				   sizeof(target_channels) / sizeof(target_channels[0]),
				   1, &owner_stats) == 0);
	assert(owner_stats.active == 1 && owner_stats.live == 1);
	assert(check_owner_fixture(released_owner, target_channels,
				   sizeof(target_channels) / sizeof(target_channels[0]),
				   1, &owner_stats) != 0);
	assert(check_owner_fixture(retained_owner, target_channels,
				   sizeof(target_channels) / sizeof(target_channels[0]),
				   1, &owner_stats) != 0);
	assert(check_owner_fixture(invalid_transition, target_channels,
				   sizeof(target_channels) / sizeof(target_channels[0]),
				   0, &owner_stats) != 0);
	assert(check_owner_fixture(malformed_owner, target_channels,
				   sizeof(target_channels) / sizeof(target_channels[0]),
				   0, &owner_stats) != 0);
	assert(check_owner_fixture(unrelated_owner, target_channels,
				   sizeof(target_channels) / sizeof(target_channels[0]),
				   0, &owner_stats) != 0);

	puts("fragmentation policy tests: PASS");
	return 0;
}
