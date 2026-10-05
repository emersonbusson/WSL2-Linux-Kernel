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

static void vmbus_gpadl_rescind_retains_state_test(struct kunit *test)
{
	static const enum vmbus_gpadl_state states[] = {
		VMBUS_GPADL_PENDING, VMBUS_GPADL_LIVE,
		VMBUS_GPADL_TEARING_DOWN, VMBUS_GPADL_UNCERTAIN,
	};
	struct vmbus_channel channel = { .rescind = true };
	struct vmbus_buffer buffer = {};
	unsigned int origin, i;
	int ret, expected;

	for (origin = 0; origin < 2; origin++) {
		enum vmbus_gpadl_teardown_event event = origin ?
			VMBUS_GPADL_TEARDOWN_HOST_RESCIND :
			VMBUS_GPADL_TEARDOWN_LOCAL_RESCIND;

		channel.rescind_from_host = origin;
		for (i = 0; i < ARRAY_SIZE(states); i++) {
			buffer.gpadl_handle = 42;
			buffer.gpadl_state = states[i];
			ret = vmbus_gpadl_teardown_result(&channel, &buffer,
							  event, -ENODEV);
			KUNIT_EXPECT_EQ(test, ret, -ENODEV);
			KUNIT_EXPECT_EQ(test, buffer.gpadl_handle, 42U);
			KUNIT_EXPECT_EQ(test, buffer.gpadl_state, states[i]);
			KUNIT_EXPECT_FALSE(test, vmbus_buffer_should_free(&buffer));

			ret = __vmbus_teardown_gpadl(&channel, &buffer,
						     vmbus_test_alloc_teardown_fail);
			expected = states[i] == VMBUS_GPADL_PENDING ||
				   states[i] == VMBUS_GPADL_TEARING_DOWN ?
				   -EINPROGRESS : -ENODEV;
			if (origin && states[i] == VMBUS_GPADL_LIVE)
				expected = -ENOMEM;
			if (origin && states[i] == VMBUS_GPADL_UNCERTAIN)
				expected = -EINVAL;
			KUNIT_EXPECT_EQ(test, ret, expected);
			KUNIT_EXPECT_EQ(test, buffer.gpadl_handle, 42U);
			KUNIT_EXPECT_EQ(test, buffer.gpadl_state, states[i]);
			KUNIT_EXPECT_FALSE(test, vmbus_buffer_should_free(&buffer));
		}
	}
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
	KUNIT_EXPECT_EQ(test, ret, -EINVAL);
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

enum vmbus_test_teardown_reply {
	VMBUS_TEST_REPLY_ACK,
	VMBUS_TEST_REPLY_NONE,
	VMBUS_TEST_REPLY_WRONG_HANDLE,
	VMBUS_TEST_REPLY_WRONG_TYPE,
	VMBUS_TEST_REPLY_POST_FAILURE,
};

struct vmbus_teardown_test_context {
	struct vmbus_connection connection;
	struct vmbus_channel channel;
	struct vmbus_buffer buffer;
	struct kunit *test;
	enum vmbus_test_teardown_reply reply;
	unsigned int post_calls;
};

static struct vmbus_channel_msginfo *vmbus_test_alloc_teardown(void)
{
	return kzalloc(sizeof(struct vmbus_channel_msginfo) +
		       sizeof(struct vmbus_channel_gpadl_teardown), GFP_KERNEL);
}

static int vmbus_test_post_teardown(struct vmbus_connection *connection,
				    struct vmbus_channel_msginfo *info)
{
	struct vmbus_teardown_test_context *ctx =
		container_of(connection, struct vmbus_teardown_test_context,
			     connection);
	struct vmbus_channel_gpadl_teardown *msg = (void *)info->msg;
	struct vmbus_channel_gpadl_torndown response = {
		.header.msgtype = CHANNELMSG_GPADL_TORNDOWN,
		.gpadl = msg->gpadl,
	};

	ctx->post_calls++;
	KUNIT_EXPECT_EQ(ctx->test, msg->header.msgtype, CHANNELMSG_GPADL_TEARDOWN);
	KUNIT_EXPECT_EQ(ctx->test, msg->child_relid, 71U);
	KUNIT_EXPECT_EQ(ctx->test, msg->gpadl, 51U);
	KUNIT_EXPECT_PTR_EQ(ctx->test, info->waiting_channel, NULL);
	if (ctx->reply == VMBUS_TEST_REPLY_POST_FAILURE)
		return -EIO;
	if (ctx->reply == VMBUS_TEST_REPLY_NONE)
		return 0;
	if (ctx->reply == VMBUS_TEST_REPLY_WRONG_HANDLE)
		response.gpadl++;
	if (ctx->reply == VMBUS_TEST_REPLY_WRONG_TYPE)
		response.header.msgtype = CHANNELMSG_GPADL_CREATED;
	vmbus_complete_gpadl_teardown(connection, &response);
	return 0;
}

static struct vmbus_teardown_test_context *
vmbus_test_teardown_context(struct kunit *test)
{
	struct vmbus_teardown_test_context *ctx;

	ctx = kunit_kzalloc(test, sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		return NULL;
	ctx->test = test;
	ctx->buffer.gpadl_handle = 51;
	ctx->buffer.gpadl_state = VMBUS_GPADL_LIVE;
	ctx->channel.rescind = true;
	ctx->channel.rescind_from_host = true;
	ctx->channel.offermsg.child_relid = 71;
	INIT_LIST_HEAD(&ctx->connection.chn_msg_list);
	spin_lock_init(&ctx->connection.channelmsg_lock);
	return ctx;
}

static int vmbus_test_teardown_request(struct vmbus_teardown_test_context *ctx)
{
	return vmbus_gpadl_teardown_request(&ctx->channel, &ctx->buffer,
					  vmbus_test_alloc_teardown,
					  &ctx->connection,
					  vmbus_test_post_teardown, 1);
}

static void vmbus_host_rescind_teardown_ack_test(struct kunit *test)
{
	struct vmbus_teardown_test_context *ctx = vmbus_test_teardown_context(test);

	KUNIT_ASSERT_NOT_NULL(test, ctx);
	KUNIT_EXPECT_EQ(test, vmbus_test_teardown_request(ctx), 0);
	KUNIT_EXPECT_EQ(test, ctx->post_calls, 1U);
	KUNIT_EXPECT_EQ(test, ctx->buffer.gpadl_handle, 0U);
	KUNIT_EXPECT_EQ(test, ctx->buffer.gpadl_state, VMBUS_GPADL_NONE);
	KUNIT_EXPECT_TRUE(test, vmbus_buffer_should_free(&ctx->buffer));
	KUNIT_EXPECT_TRUE(test, list_empty(&ctx->connection.chn_msg_list));
}

static void vmbus_test_teardown_failure(struct kunit *test,
					enum vmbus_test_teardown_reply reply,
					int expected)
{
	struct vmbus_teardown_test_context *ctx = vmbus_test_teardown_context(test);

	KUNIT_ASSERT_NOT_NULL(test, ctx);
	ctx->reply = reply;
	KUNIT_EXPECT_EQ(test, vmbus_test_teardown_request(ctx), expected);
	KUNIT_EXPECT_EQ(test, ctx->post_calls, 1U);
	KUNIT_EXPECT_EQ(test, ctx->buffer.gpadl_handle, 51U);
	KUNIT_EXPECT_FALSE(test, vmbus_buffer_should_free(&ctx->buffer));
	KUNIT_EXPECT_TRUE(test, list_empty(&ctx->connection.chn_msg_list));
}

static void vmbus_host_rescind_teardown_timeout_test(struct kunit *test)
{
	vmbus_test_teardown_failure(test, VMBUS_TEST_REPLY_NONE, -ETIMEDOUT);
}

static void vmbus_host_rescind_teardown_wrong_handle_test(struct kunit *test)
{
	vmbus_test_teardown_failure(test, VMBUS_TEST_REPLY_WRONG_HANDLE,
				    -ETIMEDOUT);
}

static void vmbus_host_rescind_teardown_wrong_type_test(struct kunit *test)
{
	vmbus_test_teardown_failure(test, VMBUS_TEST_REPLY_WRONG_TYPE, -ENODEV);
}

static void vmbus_host_rescind_teardown_post_failure_test(struct kunit *test)
{
	vmbus_test_teardown_failure(test, VMBUS_TEST_REPLY_POST_FAILURE, -EIO);
}

static void vmbus_local_rescind_skips_teardown_test(struct kunit *test)
{
	struct vmbus_teardown_test_context *ctx = vmbus_test_teardown_context(test);

	KUNIT_ASSERT_NOT_NULL(test, ctx);
	ctx->channel.rescind_from_host = false;
	KUNIT_EXPECT_EQ(test, vmbus_test_teardown_request(ctx), -ENODEV);
	KUNIT_EXPECT_EQ(test, ctx->post_calls, 0U);
	KUNIT_EXPECT_EQ(test, ctx->buffer.gpadl_state, VMBUS_GPADL_LIVE);
	KUNIT_EXPECT_EQ(test, ctx->buffer.gpadl_handle, 51U);
}

static void vmbus_invalid_relid_skips_teardown_test(struct kunit *test)
{
	struct vmbus_teardown_test_context *ctx = vmbus_test_teardown_context(test);

	KUNIT_ASSERT_NOT_NULL(test, ctx);
	ctx->channel.offermsg.child_relid = INVALID_RELID;
	KUNIT_EXPECT_EQ(test, vmbus_test_teardown_request(ctx), -ENODEV);
	KUNIT_EXPECT_EQ(test, ctx->post_calls, 0U);
	KUNIT_EXPECT_EQ(test, ctx->buffer.gpadl_handle, 51U);
}

static void vmbus_host_rescind_teardown_late_ack_test(struct kunit *test)
{
	struct vmbus_teardown_test_context *ctx = vmbus_test_teardown_context(test);
	struct vmbus_channel_gpadl_torndown response = {
		.header.msgtype = CHANNELMSG_GPADL_TORNDOWN,
		.gpadl = 51,
	};

	KUNIT_ASSERT_NOT_NULL(test, ctx);
	ctx->reply = VMBUS_TEST_REPLY_NONE;
	KUNIT_ASSERT_EQ(test, vmbus_test_teardown_request(ctx), -ETIMEDOUT);
	/* Run the production response matcher after its waiter has been freed. */
	vmbus_complete_gpadl_teardown(&ctx->connection, &response);
	KUNIT_EXPECT_TRUE(test, list_empty(&ctx->connection.chn_msg_list));
	KUNIT_EXPECT_EQ(test, ctx->buffer.gpadl_handle, 51U);
	KUNIT_EXPECT_FALSE(test, vmbus_buffer_should_free(&ctx->buffer));
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
	KUNIT_CASE(vmbus_gpadl_rescind_retains_state_test),
	KUNIT_CASE(vmbus_host_rescind_teardown_ack_test),
	KUNIT_CASE(vmbus_host_rescind_teardown_timeout_test),
	KUNIT_CASE(vmbus_host_rescind_teardown_wrong_handle_test),
	KUNIT_CASE(vmbus_host_rescind_teardown_wrong_type_test),
	KUNIT_CASE(vmbus_host_rescind_teardown_post_failure_test),
	KUNIT_CASE(vmbus_local_rescind_skips_teardown_test),
	KUNIT_CASE(vmbus_invalid_relid_skips_teardown_test),
	KUNIT_CASE(vmbus_host_rescind_teardown_late_ack_test),
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
