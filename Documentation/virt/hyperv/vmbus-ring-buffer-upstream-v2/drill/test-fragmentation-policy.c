#define main vmbus_drill_helper_main
#include "vmbus_drill_helper.c"
#undef main

#include <assert.h>

int main(void)
{
	/* MemFree omits per-CPU pages; these values come from the failing runner. */
	assert(frag_total_free_kb(896, 532) == 3024);
	assert(frag_total_free_kb(-1, 532) == -1);
	assert(frag_total_free_kb(896, -1) == -1);

	assert(frag_chase_floor_kb(512) == 512);
	assert(frag_chase_floor_kb(768) == 768);
	assert(frag_chase_floor_kb(-1) == -1);

	/* Use full chunks while safe, then page steps at the watermark boundary. */
	assert(frag_chase_fault_pages(3024, 512) == FRAG_CHUNK / FRAG_PAGE);
	assert(frag_chase_fault_pages(576, 512) == FRAG_CHUNK / FRAG_PAGE);
	assert(frag_chase_fault_pages(572, 512) == 1);
	assert(frag_chase_fault_pages(516, 512) == 1);
	assert(frag_chase_fault_pages(512, 512) == 0);
	assert(frag_chase_fault_pages(508, 512) == 0);
	assert(frag_chase_fault_pages(-1, 512) == 0);

	puts("fragmentation policy tests: PASS");
	return 0;
}
