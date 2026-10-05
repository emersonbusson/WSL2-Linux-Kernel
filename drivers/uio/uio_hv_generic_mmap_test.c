// SPDX-License-Identifier: GPL-2.0
/*
 * KUnit tests for the UIO Hyper-V generic mmap paths.
 *
 * This file is included from uio_hv_generic.c so the cases can reach the
 * static helpers that select, validate and set the protection of the
 * mapped pages.
 */
#include <kunit/test.h>

static void hv_uio_mmap_validate_test(struct kunit *test)
{
	KUNIT_EXPECT_EQ(test, hv_uio_mmap_validate(true, 8, 0, 8), 0);
	KUNIT_EXPECT_EQ(test, hv_uio_mmap_validate(true, 8, 4, 4), 0);
	KUNIT_EXPECT_EQ(test, hv_uio_mmap_validate(false, 8, 0, 1), -EINVAL);
	KUNIT_EXPECT_EQ(test, hv_uio_mmap_validate(true, 8, 8, 1), -EINVAL);
	KUNIT_EXPECT_EQ(test, hv_uio_mmap_validate(true, 8, 7, 2), -EINVAL);
	KUNIT_EXPECT_EQ(test, hv_uio_mmap_validate(true, 8, 0, 0), -EINVAL);
}

static void hv_uio_ring_mmap_page_range_test(struct kunit *test)
{
	struct page *pages[8];

	KUNIT_EXPECT_PTR_EQ(test,
			    hv_uio_mmap_select_pages(pages, ARRAY_SIZE(pages),
						     3, 2), &pages[3]);
	KUNIT_EXPECT_PTR_EQ(test,
			    hv_uio_mmap_select_pages(pages, ARRAY_SIZE(pages),
						     7, 2), NULL);
}

static void hv_uio_mmap_page_protection_test(struct kunit *test)
{
	struct hv_uio_private_data pdata = {};
	struct vmbus_channel channel = {};
	struct hv_device dev = { .channel = &channel };
	struct vm_area_struct vma = { .vm_page_prot = PAGE_SHARED };
	struct page *chunks[1];

	pdata.device = &dev;
	pdata.recv_buf.chunks = chunks;
	pdata.send_buf.chunks = chunks;
	KUNIT_EXPECT_FALSE(test,
			   hv_uio_mmap_region_decrypted(&pdata, TXRX_RING_MAP));
	KUNIT_EXPECT_FALSE(test,
			   hv_uio_mmap_region_decrypted(&pdata, INT_PAGE_MAP));
	KUNIT_EXPECT_TRUE(test,
			  hv_uio_mmap_region_decrypted(&pdata, MON_PAGE_MAP));
	KUNIT_EXPECT_TRUE(test,
			  hv_uio_mmap_region_decrypted(&pdata, RECV_BUF_MAP));
	KUNIT_EXPECT_TRUE(test,
			  hv_uio_mmap_region_decrypted(&pdata, SEND_BUF_MAP));

	channel.ringbuffer.chunks = chunks;
	hv_uio_mmap_set_page_prot(&vma, &pdata, TXRX_RING_MAP);
	KUNIT_EXPECT_EQ(test, pgprot_val(vma.vm_page_prot),
			pgprot_val(pgprot_decrypted(PAGE_SHARED)));

	vma.vm_page_prot = PAGE_SHARED;
	hv_uio_mmap_set_page_prot(&vma, &pdata, INT_PAGE_MAP);
	KUNIT_EXPECT_EQ(test, pgprot_val(vma.vm_page_prot),
			pgprot_val(PAGE_SHARED));
	hv_uio_mmap_set_page_prot(&vma, &pdata, MON_PAGE_MAP);
	KUNIT_EXPECT_EQ(test, pgprot_val(vma.vm_page_prot),
			pgprot_val(pgprot_decrypted(PAGE_SHARED)));
}

static unsigned int hv_uio_disconnect_calls;
static int hv_uio_disconnect_result;

static int hv_uio_test_disconnect(struct vmbus_channel *channel)
{
	hv_uio_disconnect_calls++;
	channel->state = CHANNEL_OPEN_STATE;
	return hv_uio_disconnect_result;
}

static void hv_uio_remove_disconnects_open_channel_test(struct kunit *test)
{
	struct vmbus_channel channel = { .state = CHANNEL_OPEN_STATE };

	hv_uio_disconnect_calls = 0;
	hv_uio_disconnect_result = 0;
	KUNIT_EXPECT_EQ(test, hv_uio_disconnect_if_open(&channel,
							hv_uio_test_disconnect), 0);
	KUNIT_EXPECT_EQ(test, hv_uio_disconnect_calls, 0U);
	channel.state = CHANNEL_OPENED_STATE;
	KUNIT_EXPECT_EQ(test, hv_uio_disconnect_if_open(&channel,
							hv_uio_test_disconnect), 0);
	KUNIT_EXPECT_EQ(test, channel.state, CHANNEL_OPEN_STATE);
	KUNIT_EXPECT_EQ(test, hv_uio_disconnect_calls, 1U);
	KUNIT_EXPECT_EQ(test, hv_uio_disconnect_if_open(&channel,
							hv_uio_test_disconnect), 0);
	KUNIT_EXPECT_EQ(test, hv_uio_disconnect_calls, 1U);

	channel.state = CHANNEL_OPENED_STATE;
	hv_uio_disconnect_result = -EIO;
	KUNIT_EXPECT_EQ(test, hv_uio_disconnect_if_open(&channel,
							hv_uio_test_disconnect), -EIO);
	KUNIT_EXPECT_EQ(test, hv_uio_disconnect_calls, 2U);
}

static int hv_uio_test_reader_wake(struct wait_queue_entry *wait,
				   unsigned int mode, int flags, void *key)
{
	unsigned int *wakes = wait->private;

	(*wakes)++;
	return 1;
}

static void hv_uio_unregister_wakes_reader_test(struct kunit *test)
{
	struct uio_info info = {
		.name = "hv-uio-withdrawal-test",
		.version = "1",
		.irq = UIO_IRQ_CUSTOM,
	};
	struct uio_device *idev;
	struct device *parent;
	wait_queue_entry_t wait;
	unsigned int wakes = 0;
	int ret;

	parent = root_device_register("hv-uio-withdrawal-test");
	KUNIT_ASSERT_FALSE(test, IS_ERR(parent));
	ret = uio_register_device(parent, &info);
	if (ret) {
		root_device_unregister(parent);
		KUNIT_FAIL(test, "UIO registration failed: %d", ret);
		return;
	}
	idev = info.uio_dev;
	get_device(&idev->dev);
	init_waitqueue_func_entry(&wait, hv_uio_test_reader_wake);
	wait.private = &wakes;
	add_wait_queue(&idev->wait, &wait);

	uio_unregister_device(&info);
	KUNIT_EXPECT_PTR_EQ(test, idev->info, NULL);
	KUNIT_EXPECT_EQ(test, wakes, 1U);
	remove_wait_queue(&idev->wait, &wait);
	put_device(&idev->dev);
	root_device_unregister(parent);
}

static struct kunit_case hv_uio_mmap_test_cases[] = {
	KUNIT_CASE(hv_uio_unregister_wakes_reader_test),
	KUNIT_CASE(hv_uio_remove_disconnects_open_channel_test),
	KUNIT_CASE(hv_uio_mmap_validate_test),
	KUNIT_CASE(hv_uio_ring_mmap_page_range_test),
	KUNIT_CASE(hv_uio_mmap_page_protection_test),
	{}
};

static struct kunit_suite hv_uio_mmap_test_suite = {
	.name = "hyperv-uio-hv-generic-mmap",
	.test_cases = hv_uio_mmap_test_cases,
};

kunit_test_suite(hv_uio_mmap_test_suite);
