#define main vmbus_drill_helper_main
#include "vmbus_drill_helper.c"
#undef main

#include <assert.h>

int main(void)
{
	/* The safe stop retains one measured order-7 block. */
	assert(frag_bounded_pressure_qualified(500000, 128,
						       "chase-memfree-margin", 1, 1));
	assert(frag_bounded_pressure_qualified(500000, 128,
						       "order7-reserve", 1, 1));
	assert(frag_bounded_pressure_qualified(500000, 128,
						       "chase-order7-reserve", 1, 1));
	assert(frag_bounded_pressure_qualified(12800, 128,
						       "chase-memfree-margin", 1, 1));
	assert(frag_bounded_pressure_qualified(12900, 128,
						       "chase-memfree-margin", 1, 1));

	/* Saturation, larger residue, unsafe stop, or missing PFN stays unqualified. */
	assert(!frag_bounded_pressure_qualified(500000, 0,
							"order7-depleted", 1, 1));
	assert(!frag_bounded_pressure_qualified(500000, 256,
							"chase-memfree-margin", 1, 1));
	assert(!frag_bounded_pressure_qualified(12800, 129,
							"chase-memfree-margin", 1, 1));
	assert(!frag_bounded_pressure_qualified(12799, 128,
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
	assert(!frag_should_preserve_order7(0, 128));
	assert(!frag_should_preserve_order7(1, 129));
	assert(!frag_should_preserve_order7(1, 0));
	assert(!frag_release_requested("/nonexistent/vmbus-release-sentinel"));
	assert(frag_release_requested("/dev/null"));
	frag_stop_signal = SIGTERM;
	assert(frag_release_requested(NULL));
	frag_stop_signal = 0;

	puts("fragmentation policy tests: PASS");
	return 0;
}
