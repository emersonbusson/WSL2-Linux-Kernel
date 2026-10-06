#define main vmbus_drill_helper_main
#include "vmbus_drill_helper.c"
#undef main

#include <assert.h>

int main(void)
{
	/* The safe stop qualifies only the bounded ordinary allocation scope. */
	assert(frag_bounded_pressure_qualified(500000, 0,
						       "order7-depleted", 1, 1));
	assert(frag_bounded_pressure_qualified(500000, 128,
						       "chase-memfree-margin", 1, 1));
	assert(frag_bounded_pressure_qualified(12800, 128,
						       "chase-memfree-margin", 1, 1));
	assert(frag_bounded_pressure_qualified(12900, 128,
						       "chase-memfree-margin", 1, 1));

	/* A larger residue, unsafe stop, or missing PFN proof stays unqualified. */
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
	assert(!frag_bounded_pressure_qualified(0, 0,
							"order7-depleted", 1, 1));
	assert(!frag_bounded_pressure_qualified(500000, 0,
							"chase-memfree-margin", 1, 1));

	puts("fragmentation policy tests: PASS");
	return 0;
}
