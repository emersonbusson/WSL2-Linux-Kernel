// SPDX-License-Identifier: GPL-2.0-only
/*
 * KUnit tests for Hyper-V VMBus buffer allocation and GPADL lifetime.
 *
 * Built into the hv_vmbus object rather than a separate module so the
 * cases can reach the internal helpers declared in hyperv_vmbus.h
 * without exporting them.
 */
#include <kunit/test.h>
#include <linux/hyperv.h>
#include <linux/mm.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>

#include "hyperv_vmbus.h"

static unsigned int vmbus_test_reencrypt_calls;

static unsigned int vmbus_test_retained_count(void)
{
	struct vmbus_buffer_retained *owner;
	unsigned int count = 0;

	mutex_lock(&vmbus_retained_buffers_lock);
	list_for_each_entry(owner, &vmbus_retained_buffers, list)
		count++;
	mutex_unlock(&vmbus_retained_buffers_lock);

	return count;
}

static void vmbus_test_drop_retained(struct vmbus_buffer_retained *owner)
{
	cancel_delayed_work_sync(&owner->reclaim_work);
	mutex_lock(&vmbus_retained_buffers_lock);
	if (!list_empty(&owner->list))
		list_del_init(&owner->list);
	mutex_unlock(&vmbus_retained_buffers_lock);

	if (owner->addr) {
		if (owner->chunks)
			vunmap(owner->addr);
		else
			vfree(owner->addr);
	}
	kvfree(owner->chunks);
	owner->chunks = NULL;
	kfree(owner);
}

static int vmbus_test_reencrypt_fail(unsigned long addr, int nr_pages)
{
	vmbus_test_reencrypt_calls++;
	return -EIO;
}

static int vmbus_test_reencrypt_ok(unsigned long addr, int nr_pages)
{
	vmbus_test_reencrypt_calls++;
	return 0;
}

static struct vmbus_channel_msginfo *vmbus_test_alloc_teardown_fail(void)
{
	return NULL;
}

static void vmbus_gpadl_teardown_alloc_failure_test(struct kunit *test)
{
	struct vmbus_channel channel = {};
	struct vmbus_buffer buffer = {
		.gpadl_handle = 48,
		.gpadl_state = VMBUS_GPADL_LIVE,
	};

	KUNIT_EXPECT_EQ(test,
			__vmbus_teardown_gpadl(&channel, &buffer,
					       vmbus_test_alloc_teardown_fail),
			-ENOMEM);
	KUNIT_EXPECT_EQ(test, buffer.gpadl_handle, 48U);
	KUNIT_EXPECT_EQ(test, buffer.gpadl_state, VMBUS_GPADL_LIVE);
	KUNIT_EXPECT_FALSE(test, vmbus_buffer_should_free(&buffer));
}

static void vmbus_buffer_size_rounding_test(struct kunit *test)
{
	unsigned long nr_pages;
	u32 aligned_size;
	u32 max_request = U32_MAX - (u32)(PAGE_SIZE - 1);

	KUNIT_EXPECT_EQ(test,
			vmbus_buffer_size_pages(0, &nr_pages, &aligned_size),
			-EINVAL);
	KUNIT_EXPECT_EQ(test, nr_pages, 0UL);
	KUNIT_EXPECT_EQ(test, aligned_size, 0U);
	KUNIT_EXPECT_EQ(test,
			vmbus_buffer_size_pages(PAGE_SIZE + 1, &nr_pages,
						&aligned_size), 0);
	KUNIT_EXPECT_EQ(test, nr_pages, 2UL);
	KUNIT_EXPECT_EQ(test, aligned_size, (u32)(2 * PAGE_SIZE));
	KUNIT_EXPECT_EQ(test,
			vmbus_buffer_size_pages(max_request, &nr_pages,
						&aligned_size), 0);
	KUNIT_EXPECT_EQ(test, aligned_size, (u32)(U32_MAX & PAGE_MASK));
	KUNIT_EXPECT_EQ(test,
			vmbus_buffer_size_pages(U32_MAX, &nr_pages, &aligned_size),
			-EINVAL);
	KUNIT_EXPECT_EQ(test, nr_pages, 0UL);
	KUNIT_EXPECT_EQ(test, aligned_size, 0U);
}

static void vmbus_shared_buffer_path_selection_test(struct kunit *test)
{
	KUNIT_EXPECT_EQ(test, vmbus_uses_shared_page_chunks(false, false),
			IS_ENABLED(CONFIG_ARM64));
	KUNIT_EXPECT_TRUE(test, vmbus_uses_shared_page_chunks(false, true));
	KUNIT_EXPECT_FALSE(test, vmbus_uses_shared_page_chunks(true, true));
}

static void vmbus_gpadl_rescind_remote_vs_unload_test(struct kunit *test)
{
	struct vmbus_buffer_retained *owner;
	struct vmbus_channel channel = {};
	struct vmbus_buffer buffer = {
		.gpadl_handle = 42,
		.gpadl_state = VMBUS_GPADL_LIVE,
	};
	int ret;

	owner = vmbus_buffer_owner_alloc();
	KUNIT_ASSERT_NOT_NULL(test, owner);
	buffer.owner = owner;
	WRITE_ONCE(channel.rescind, true);
	WRITE_ONCE(channel.rescind_from_host, true);
	KUNIT_EXPECT_EQ(test, vmbus_channel_rescind_source(&channel),
			VMBUS_RESCIND_HOST);
	ret = vmbus_gpadl_teardown_result(&channel, &buffer,
					  VMBUS_GPADL_TEARDOWN_HOST_RESCIND,
					  -ENODEV);
	KUNIT_EXPECT_EQ(test, ret, 0);
	KUNIT_EXPECT_EQ(test, buffer.gpadl_handle, 0U);
	KUNIT_EXPECT_EQ(test, buffer.gpadl_state, VMBUS_GPADL_NONE);
	KUNIT_EXPECT_TRUE(test, vmbus_buffer_should_free(&buffer));

	buffer.gpadl_handle = 43;
	buffer.gpadl_state = VMBUS_GPADL_TEARING_DOWN;
	ret = vmbus_gpadl_teardown_result(&channel, &buffer,
					  VMBUS_GPADL_TEARDOWN_HOST_RESCIND,
					  -ENODEV);
	KUNIT_EXPECT_EQ(test, ret, 0);
	KUNIT_EXPECT_TRUE(test, vmbus_buffer_should_free(&buffer));

	memset(&channel, 0, sizeof(channel));
	buffer.gpadl_handle = 42;
	buffer.gpadl_state = VMBUS_GPADL_LIVE;
	buffer.owner = NULL;
	WRITE_ONCE(channel.rescind_from_host, true);
	WRITE_ONCE(channel.rescind, true);
	ret = vmbus_gpadl_teardown_result(&channel, &buffer,
					  VMBUS_GPADL_TEARDOWN_HOST_RESCIND,
					  -ENODEV);
	KUNIT_EXPECT_EQ(test, ret, 0);
	KUNIT_EXPECT_TRUE(test, vmbus_buffer_should_free(&buffer));

	buffer.gpadl_handle = 42;
	buffer.gpadl_state = VMBUS_GPADL_LIVE;
	WRITE_ONCE(channel.rescind_from_host, false);
	KUNIT_EXPECT_EQ(test, vmbus_channel_rescind_source(&channel),
			VMBUS_RESCIND_LOCAL);
	ret = vmbus_gpadl_teardown_result(&channel, &buffer,
					  VMBUS_GPADL_TEARDOWN_LOCAL_RESCIND,
					  -ENODEV);
	KUNIT_EXPECT_EQ(test, ret, -ENODEV);
	KUNIT_EXPECT_EQ(test, buffer.gpadl_handle, 42U);
	KUNIT_EXPECT_FALSE(test, vmbus_buffer_should_free(&buffer));
	kfree(owner);
}

static void vmbus_gpadl_create_response_rescind_test(struct kunit *test)
{
	struct vmbus_buffer buffer = {
		.gpadl_handle = 43,
		.gpadl_state = VMBUS_GPADL_PENDING,
	};
	struct vmbus_buffer rejected = {
		.gpadl_handle = 47,
		.gpadl_state = VMBUS_GPADL_PENDING,
	};
	int ret;

	ret = vmbus_gpadl_create_response(&buffer, true, 0, VMBUS_RESCIND_HOST);
	KUNIT_EXPECT_EQ(test, ret, -ENODEV);
	KUNIT_EXPECT_EQ(test, buffer.gpadl_handle, 43U);
	KUNIT_EXPECT_EQ(test, buffer.gpadl_state, VMBUS_GPADL_LIVE);
	KUNIT_EXPECT_FALSE(test, vmbus_buffer_should_free(&buffer));

	ret = vmbus_gpadl_create_response(&rejected, true, 1, VMBUS_RESCIND_HOST);
	KUNIT_EXPECT_EQ(test, ret, -EDQUOT);
	KUNIT_EXPECT_EQ(test, rejected.gpadl_handle, 0U);
	KUNIT_EXPECT_EQ(test, rejected.gpadl_state, VMBUS_GPADL_NONE);
	KUNIT_EXPECT_TRUE(test, vmbus_buffer_should_free(&rejected));
}

static void vmbus_gpadl_partial_post_rescind_test(struct kunit *test)
{
	struct vmbus_buffer_retained *owner;
	struct vmbus_channel channel = {};
	struct vmbus_buffer buffer = { .size = PAGE_SIZE };
	unsigned int before;
	int ret;

	owner = vmbus_buffer_owner_alloc();
	KUNIT_ASSERT_NOT_NULL(test, owner);
	buffer.owner = owner;
	ret = vmbus_gpadl_begin(&buffer, 44);
	KUNIT_ASSERT_EQ(test, ret, 0);

	/* A body post can fail after the header was accepted by the host. */
	ret = vmbus_gpadl_teardown_result(&channel, &buffer,
					  VMBUS_GPADL_TEARDOWN_FAILURE,
					  -EIO);
	KUNIT_EXPECT_EQ(test, ret, -EIO);
	ret = vmbus_gpadl_create_response(&buffer, false, 0, VMBUS_RESCIND_HOST);
	KUNIT_EXPECT_EQ(test, ret, -ENODEV);
	vmbus_gpadl_create_finish(&buffer);
	KUNIT_EXPECT_EQ(test, buffer.gpadl_handle, 44U);
	KUNIT_EXPECT_EQ(test, buffer.gpadl_state, VMBUS_GPADL_UNCERTAIN);
	WRITE_ONCE(channel.rescind, true);
	WRITE_ONCE(channel.rescind_from_host, true);

	ret = __vmbus_teardown_gpadl(&channel, &buffer,
				     vmbus_test_alloc_teardown_fail);
	KUNIT_EXPECT_EQ(test, ret, 0);
	KUNIT_EXPECT_EQ(test, buffer.gpadl_handle, 44U);
	KUNIT_EXPECT_EQ(test, buffer.gpadl_state, VMBUS_GPADL_UNCERTAIN);
	before = vmbus_test_retained_count();
	vmbus_free_buffer(&buffer);
	KUNIT_EXPECT_EQ(test, vmbus_test_retained_count(), before + 1);
	KUNIT_EXPECT_EQ(test, owner->gpadl_handle, 44U);
	KUNIT_EXPECT_EQ(test, owner->gpadl_state, VMBUS_GPADL_UNCERTAIN);
	KUNIT_EXPECT_EQ(test, owner->size, PAGE_SIZE);
	vmbus_test_drop_retained(owner);
}

static void vmbus_gpadl_teardown_ack_failure_test(struct kunit *test)
{
	struct vmbus_channel channel = {};
	struct vmbus_buffer buffer = {
		.gpadl_handle = 45,
		.gpadl_state = VMBUS_GPADL_LIVE,
		.leak = true,
	};
	int ret;

	ret = vmbus_gpadl_teardown_begin(&buffer);
	KUNIT_ASSERT_EQ(test, ret, 0);
	KUNIT_EXPECT_EQ(test, vmbus_gpadl_teardown_begin(&buffer),
			-EINPROGRESS);
	ret = vmbus_gpadl_teardown_result(&channel, &buffer,
					  VMBUS_GPADL_TEARDOWN_FAILURE,
					  -EIO);
	KUNIT_EXPECT_EQ(test, ret, -EIO);
	KUNIT_EXPECT_EQ(test, buffer.gpadl_handle, 45U);
	KUNIT_EXPECT_EQ(test, buffer.gpadl_state,
			VMBUS_GPADL_TEARING_DOWN);

	ret = vmbus_gpadl_teardown_result(&channel, &buffer,
					  VMBUS_GPADL_TEARDOWN_ACK, 0);
	KUNIT_EXPECT_EQ(test, ret, 0);
	KUNIT_EXPECT_EQ(test, buffer.gpadl_handle, 0U);
	KUNIT_EXPECT_EQ(test, buffer.gpadl_state, VMBUS_GPADL_NONE);
	KUNIT_EXPECT_TRUE(test, buffer.leak);
	KUNIT_EXPECT_FALSE(test, vmbus_buffer_should_free(&buffer));
	ret = vmbus_gpadl_teardown_result(&channel, &buffer,
					  VMBUS_GPADL_TEARDOWN_ACK, 0);
	KUNIT_EXPECT_EQ(test, ret, 0);
}

static void vmbus_buffer_reencrypt_failure_retains_test(struct kunit *test)
{
	struct vmbus_buffer_retained *owner;
	struct page **chunks;
	struct page *page;
	bool retained;

	owner = vmbus_buffer_owner_alloc();
	KUNIT_ASSERT_NOT_NULL(test, owner);
	chunks = kmalloc(sizeof(*chunks), GFP_KERNEL);
	KUNIT_ASSERT_NOT_NULL(test, chunks);
	page = alloc_page(GFP_KERNEL | __GFP_COMP);
	KUNIT_ASSERT_NOT_NULL(test, page);
	chunks[0] = page;
	mutex_lock(&vmbus_retained_buffers_lock);
	retained = __vmbus_free_buffer_mem(owner, NULL, chunks, 1, NULL,
					   vmbus_test_reencrypt_fail);
	mutex_unlock(&vmbus_retained_buffers_lock);

	KUNIT_EXPECT_TRUE(test, retained);
	KUNIT_EXPECT_TRUE(test, owner->encryption_unknown);
	KUNIT_EXPECT_PTR_EQ(test, owner->addr, NULL);
	KUNIT_EXPECT_EQ(test, owner->chunk_cnt, 1U);
	KUNIT_EXPECT_PTR_EQ(test, owner->chunks[0], page);
	vmbus_test_drop_retained(owner);
	__free_pages(page, 0);
}

static void vmbus_buffer_mapping_ref_defers_reencrypt_test(struct kunit *test)
{
	struct vmbus_buffer_retained *owner;
	struct page **chunks;
	struct page *page;
	bool retained;

	owner = vmbus_buffer_owner_alloc();
	KUNIT_ASSERT_NOT_NULL(test, owner);
	chunks = kmalloc(sizeof(*chunks), GFP_KERNEL);
	KUNIT_ASSERT_NOT_NULL(test, chunks);
	page = alloc_page(GFP_KERNEL | __GFP_COMP);
	KUNIT_ASSERT_NOT_NULL(test, page);
	chunks[0] = page;
	get_page(page);

	vmbus_test_reencrypt_calls = 0;
	mutex_lock(&vmbus_retained_buffers_lock);
	retained = __vmbus_free_buffer_mem(owner, NULL, chunks, 1, NULL,
					   vmbus_test_reencrypt_ok);
	mutex_unlock(&vmbus_retained_buffers_lock);
	KUNIT_EXPECT_TRUE(test, retained);
	KUNIT_EXPECT_EQ(test, vmbus_test_reencrypt_calls, 0U);

	if (retained) {
		KUNIT_EXPECT_PTR_EQ(test, owner->chunks[0], page);
		KUNIT_EXPECT_EQ(test, owner->chunk_cnt, 1U);
		put_page(page);
		mutex_lock(&vmbus_retained_buffers_lock);
		retained = __vmbus_free_buffer_mem(owner, NULL, owner->chunks,
						   owner->chunk_cnt, NULL,
						   vmbus_test_reencrypt_ok);
		mutex_unlock(&vmbus_retained_buffers_lock);
		KUNIT_EXPECT_FALSE(test, retained);
		KUNIT_EXPECT_EQ(test, vmbus_test_reencrypt_calls, 1U);
		owner->chunks = NULL;
	} else {
		put_page(page);
	}

	vmbus_test_drop_retained(owner);
}

static void vmbus_vmalloc_mapping_ref_defers_free_test(struct kunit *test)
{
	struct vmbus_buffer_retained *owner;
	struct page *page;
	void *addr;
	bool retained;

	owner = vmbus_buffer_owner_alloc();
	KUNIT_ASSERT_NOT_NULL(test, owner);
	addr = vzalloc(PAGE_SIZE);
	KUNIT_ASSERT_NOT_NULL(test, addr);
	page = vmalloc_to_page(addr);
	KUNIT_ASSERT_NOT_NULL(test, page);
	get_page(page);
	owner->size = PAGE_SIZE;

	mutex_lock(&vmbus_retained_buffers_lock);
	retained = __vmbus_free_buffer_mem(owner, addr, NULL, 0, NULL,
					   vmbus_test_reencrypt_ok);
	mutex_unlock(&vmbus_retained_buffers_lock);
	KUNIT_ASSERT_TRUE(test, retained);
	KUNIT_EXPECT_PTR_EQ(test, owner->addr, addr);
	put_page(page);

	mutex_lock(&vmbus_retained_buffers_lock);
	retained = __vmbus_free_buffer_mem(owner, owner->addr, NULL, 0, NULL,
					   vmbus_test_reencrypt_ok);
	mutex_unlock(&vmbus_retained_buffers_lock);
	KUNIT_EXPECT_FALSE(test, retained);
	owner->addr = NULL;
	vmbus_test_drop_retained(owner);
}

static void vmbus_reclaim_busy_ref_defers_free_test(struct kunit *test)
{
	struct vmbus_buffer_retained *owner;
	struct page *page;
	void *addr;
	unsigned int before;

	owner = vmbus_buffer_owner_alloc();
	KUNIT_ASSERT_NOT_NULL(test, owner);
	addr = vzalloc(PAGE_SIZE);
	KUNIT_ASSERT_NOT_NULL(test, addr);
	page = vmalloc_to_page(addr);
	KUNIT_ASSERT_NOT_NULL(test, page);
	get_page(page);
	owner->addr = addr;
	owner->size = PAGE_SIZE;
	owner->released = true;

	before = vmbus_test_retained_count();
	vmbus_buffer_retain_owner(owner);
	cancel_delayed_work_sync(&owner->reclaim_work);
	KUNIT_EXPECT_EQ(test, vmbus_test_retained_count(), before + 1);

	*(char *)addr = 0x5a;
	vmbus_buffer_reclaim_work(&owner->reclaim_work.work);
	KUNIT_EXPECT_PTR_EQ(test, owner->addr, addr);
	KUNIT_EXPECT_EQ(test, *(char *)addr, 0x5a);
	KUNIT_EXPECT_EQ(test, vmbus_test_retained_count(), before + 1);

	cancel_delayed_work_sync(&owner->reclaim_work);
	put_page(page);

	/*
	 * With the mapping-style ref gone the reclaimer frees the pages and
	 * drops the owner. Do not touch owner after this call.
	 */
	vmbus_buffer_reclaim_work(&owner->reclaim_work.work);
	KUNIT_EXPECT_EQ(test, vmbus_test_retained_count(), before);
}

static void vmbus_buffer_cleanup_repeated_test(struct kunit *test)
{
	struct vmbus_buffer_retained *owner;
	struct page **chunks;
	struct page *page;
	void *addr;
	struct vmbus_buffer buffer = {
		.gpadl_handle = 46,
		.gpadl_state = VMBUS_GPADL_LIVE,
		.size = PAGE_SIZE,
	};
	unsigned int before;

	owner = vmbus_buffer_owner_alloc();
	KUNIT_ASSERT_NOT_NULL(test, owner);
	chunks = kmalloc(sizeof(*chunks), GFP_KERNEL);
	KUNIT_ASSERT_NOT_NULL(test, chunks);
	page = alloc_page(GFP_KERNEL | __GFP_COMP);
	KUNIT_ASSERT_NOT_NULL(test, page);
	chunks[0] = page;
	addr = vmap(chunks, 1, VM_MAP, PAGE_KERNEL);
	KUNIT_ASSERT_NOT_NULL(test, addr);
	buffer.addr = addr;
	buffer.chunks = chunks;
	buffer.chunk_cnt = 1;
	buffer.owner = owner;
	before = vmbus_test_retained_count();
	vmbus_test_reencrypt_calls = 0;

	__vmbus_free_buffer(&buffer, vmbus_test_reencrypt_fail);
	KUNIT_EXPECT_EQ(test, vmbus_test_retained_count(), before + 1);
	KUNIT_EXPECT_PTR_EQ(test, buffer.addr, NULL);
	KUNIT_EXPECT_PTR_EQ(test, owner->addr, addr);
	KUNIT_EXPECT_PTR_EQ(test, owner->chunks, chunks);
	KUNIT_EXPECT_EQ(test, owner->chunk_cnt, 1U);
	KUNIT_EXPECT_EQ(test, vmbus_test_reencrypt_calls, 0U);
	__vmbus_free_buffer(&buffer, vmbus_test_reencrypt_fail);
	KUNIT_EXPECT_EQ(test, vmbus_test_retained_count(), before + 1);
	KUNIT_EXPECT_EQ(test, owner->gpadl_handle, 46U);
	KUNIT_EXPECT_EQ(test, vmbus_test_reencrypt_calls, 0U);
	vmbus_test_drop_retained(owner);
	__free_pages(page, 0);
}

static struct kunit_case vmbus_gpadl_lifetime_test_cases[] = {
	KUNIT_CASE(vmbus_buffer_size_rounding_test),
	KUNIT_CASE(vmbus_shared_buffer_path_selection_test),
	KUNIT_CASE(vmbus_gpadl_rescind_remote_vs_unload_test),
	KUNIT_CASE(vmbus_gpadl_create_response_rescind_test),
	KUNIT_CASE(vmbus_gpadl_partial_post_rescind_test),
	KUNIT_CASE(vmbus_gpadl_teardown_alloc_failure_test),
	KUNIT_CASE(vmbus_gpadl_teardown_ack_failure_test),
	KUNIT_CASE(vmbus_buffer_reencrypt_failure_retains_test),
	KUNIT_CASE(vmbus_buffer_mapping_ref_defers_reencrypt_test),
	KUNIT_CASE(vmbus_vmalloc_mapping_ref_defers_free_test),
	KUNIT_CASE(vmbus_reclaim_busy_ref_defers_free_test),
	KUNIT_CASE(vmbus_buffer_cleanup_repeated_test),
	{}
};

static struct kunit_suite vmbus_gpadl_lifetime_test_suite = {
	.name = "hyperv-vmbus-gpadl-lifetime",
	.test_cases = vmbus_gpadl_lifetime_test_cases,
};

kunit_test_suite(vmbus_gpadl_lifetime_test_suite);
