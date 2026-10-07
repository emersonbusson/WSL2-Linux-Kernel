#define main vmbus_drill_helper_main
#include "vmbus_drill_helper.c"
#undef main

#include <assert.h>

int main(void)
{
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

	/* The safe stop retains up to two measured minimum order-7 blocks. */
	assert(frag_bounded_pressure_qualified(500000, 128,
						       "chase-memfree-margin", 1, 1));
	assert(frag_bounded_pressure_qualified(500000, 256,
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
	assert(!frag_bounded_pressure_qualified(500000, 257,
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
	assert(!frag_should_preserve_order7(0, 128));
	assert(!frag_should_preserve_order7(1, 257));
	assert(!frag_should_preserve_order7(1, 0));
	assert(frag_should_refine_order7(1, 384));
	assert(!frag_should_refine_order7(1, 256));
	assert(!frag_should_refine_order7(0, 384));
	assert(!frag_release_requested("/nonexistent/vmbus-release-sentinel"));
	assert(frag_release_requested("/dev/null"));
	frag_stop_signal = SIGTERM;
	assert(frag_release_requested(NULL));
	frag_stop_signal = 0;

	puts("fragmentation policy tests: PASS");
	return 0;
}
