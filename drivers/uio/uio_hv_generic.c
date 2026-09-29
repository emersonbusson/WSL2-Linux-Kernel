// SPDX-License-Identifier: GPL-2.0
/*
 * uio_hv_generic - generic UIO driver for VMBus
 *
 * Copyright (c) 2013-2016 Brocade Communications Systems, Inc.
 * Copyright (c) 2016, Microsoft Corporation.
 *
 * Since the driver does not declare any device ids, you must allocate
 * id and bind the device to the driver yourself.  For example:
 *
 * Associate Network GUID with UIO device
 * # echo "f8615163-df3e-46c5-913f-f2d2f965ed0e" \
 *    > /sys/bus/vmbus/drivers/uio_hv_generic/new_id
 * Then rebind
 * # echo -n "ed963694-e847-4b2a-85af-bc9cfc11d6f3" \
 *    > /sys/bus/vmbus/drivers/hv_netvsc/unbind
 * # echo -n "ed963694-e847-4b2a-85af-bc9cfc11d6f3" \
 *    > /sys/bus/vmbus/drivers/uio_hv_generic/bind
 */
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/device.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/uio_driver.h>
#include <linux/netdevice.h>
#include <linux/if_ether.h>
#include <linux/mm.h>
#include <linux/overflow.h>
#include <linux/skbuff.h>
#include <linux/hyperv.h>
#include <linux/vmalloc.h>
#include <linux/slab.h>
#if IS_ENABLED(CONFIG_KUNIT)
#include <kunit/test.h>
#endif

#include "../hv/hyperv_vmbus.h"

#define DRIVER_VERSION	"0.02.1"
#define DRIVER_AUTHOR	"Stephen Hemminger <sthemmin at microsoft.com>"
#define DRIVER_DESC	"Generic UIO driver for VMBus devices"

#define SEND_BUFFER_SIZE (16 * 1024 * 1024)
#define RECV_BUFFER_SIZE (31 * 1024 * 1024)

/*
 * List of resources to be mapped to user space
 * can be extended up to MAX_UIO_MAPS(5) items
 */
enum hv_uio_map {
	TXRX_RING_MAP = 0,
	INT_PAGE_MAP,
	MON_PAGE_MAP,
	RECV_BUF_MAP,
	SEND_BUF_MAP
};

struct hv_uio_private_data {
	struct uio_info info;
	struct hv_device *device;
	atomic_t refcnt;

	struct vmbus_buffer recv_buf;
	char	recv_name[32];	/* "recv:%u" */

	struct vmbus_buffer send_buf;
	char	send_name[32];
};

static bool hv_uio_mmap_range_valid(unsigned long map_pages,
				    pgoff_t offset,
				    unsigned long pages)
{
	return pages && offset < map_pages && pages <= map_pages - offset;
}

static int hv_uio_mmap_validate(bool shared, unsigned long map_pages,
				pgoff_t offset, unsigned long pages)
{
	if (!shared || !hv_uio_mmap_range_valid(map_pages, offset, pages))
		return -EINVAL;

	return 0;
}

static bool hv_uio_mmap_region_decrypted(struct hv_uio_private_data *pdata,
					 unsigned int map_index)
{
	struct vmbus_channel *channel = pdata->device->channel;

	switch (map_index) {
	case TXRX_RING_MAP:
		return !!channel->ringbuffer.chunks;
	case INT_PAGE_MAP:
		return false;
	case MON_PAGE_MAP:
		return true;
	case RECV_BUF_MAP:
		return !!pdata->recv_buf.chunks;
	case SEND_BUF_MAP:
		return !!pdata->send_buf.chunks;
	default:
		return false;
	}
}

static void hv_uio_mmap_set_page_prot(struct vm_area_struct *vma,
				      struct hv_uio_private_data *pdata,
				      unsigned int map_index)
{
	if (hv_uio_mmap_region_decrypted(pdata, map_index))
		vma->vm_page_prot = pgprot_decrypted(vma->vm_page_prot);
}

static struct page **hv_uio_mmap_select_pages(struct page **pages,
					      unsigned long map_pages,
					      pgoff_t offset,
					      unsigned long nr_pages)
{
	if (!pages || !hv_uio_mmap_range_valid(map_pages, offset, nr_pages))
		return NULL;

	return pages + offset;
}

#if IS_ENABLED(CONFIG_KUNIT)
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

static struct kunit_case hv_uio_mmap_test_cases[] = {
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
#endif

static void set_event(struct vmbus_channel *channel, s32 irq_state)
{
	channel->inbound.ring_buffer->interrupt_mask = !irq_state;
	if (!channel->offermsg.monitor_allocated && irq_state) {
		/* MB is needed for host to see the interrupt mask first */
		virt_mb();
		vmbus_set_event(channel);
	}
}

/*
 * This is the irqcontrol callback to be registered to uio_info.
 * It can be used to disable/enable interrupt from user space processes.
 *
 * @param info
 *  pointer to uio_info.
 * @param irq_state
 *  state value. 1 to enable interrupt, 0 to disable interrupt.
 */
static int
hv_uio_irqcontrol(struct uio_info *info, s32 irq_state)
{
	struct hv_uio_private_data *pdata = info->priv;
	struct hv_device *dev = pdata->device;
	struct vmbus_channel *primary, *sc;

	primary = dev->channel;
	set_event(primary, irq_state);

	mutex_lock(&vmbus_connection.channel_mutex);
	list_for_each_entry(sc, &primary->sc_list, sc_list)
		set_event(sc, irq_state);
	mutex_unlock(&vmbus_connection.channel_mutex);

	return 0;
}

/*
 * Callback from vmbus_event when something is in inbound ring.
 */
static void hv_uio_channel_cb(void *context)
{
	struct vmbus_channel *chan = context;
	struct hv_device *hv_dev;
	struct hv_uio_private_data *pdata;

	virt_mb();

	/*
	 * The callback may come from a subchannel, in which case look
	 * for the hv device in the primary channel
	 */
	hv_dev = chan->primary_channel ?
		 chan->primary_channel->device_obj : chan->device_obj;
	pdata = hv_get_drvdata(hv_dev);
	uio_event_notify(&pdata->info);
}

/*
 * Callback from vmbus_event when channel is rescinded.
 * It is meant for rescind of primary channels only.
 */
static void hv_uio_rescind(struct vmbus_channel *channel)
{
	struct hv_device *hv_dev = channel->device_obj;
	struct hv_uio_private_data *pdata = hv_get_drvdata(hv_dev);

	/*
	 * Turn off the interrupt file handle
	 * Next read for event will return -EIO
	 */
	pdata->info.irq = 0;

	/* Wake up reader */
	uio_event_notify(&pdata->info);

	/*
	 * With rescind callback registered, rescind path will not unregister the device
	 * from vmbus when the primary channel is rescinded.
	 * Without it, rescind handling is incomplete and next onoffer msg does not come.
	 * Unregister the device from vmbus here.
	 */
	vmbus_device_unregister(channel->device_obj);
}

/* Function used for mmap of ring buffer sysfs interface.
 * The ring buffer is allocated as contiguous memory by vmbus_open
 */
static int
hv_uio_ring_mmap(struct vmbus_channel *channel, struct vm_area_struct *vma)
{
	unsigned long pages = vma_pages(vma);
	pgoff_t offset = vma->vm_pgoff;
	struct page **map_pages;

	if (channel->state != CHANNEL_OPENED_STATE)
		return -ENODEV;
	if (hv_uio_mmap_validate(vma->vm_flags & VM_SHARED,
				 channel->ringbuffer_pagecount, offset, pages))
		return -EINVAL;

	vm_flags_set(vma, VM_DONTEXPAND | VM_DONTDUMP);
	if (channel->ringbuffer.chunks)
		vma->vm_page_prot = pgprot_decrypted(vma->vm_page_prot);

	map_pages = hv_uio_mmap_select_pages(channel->ringbuffer.pages,
					     channel->ringbuffer_pagecount,
					     offset, pages);
	if (!map_pages)
		return -EINVAL;

	return vm_map_pages_zero(vma, map_pages, pages);
}

static int hv_uio_mmap(struct uio_info *info, struct vm_area_struct *vma)
{
	struct hv_uio_private_data *pdata = info->priv;
	unsigned long requested_pages = vma_pages(vma);
	struct uio_mem *mem;
	struct page **pages;
	resource_size_t map_size, rounded_size;
	unsigned long page_offset, map_pages, i;
	void *addr;
	int ret;

	if (vma->vm_pgoff >= MAX_UIO_MAPS)
		return -EINVAL;

	mem = &info->mem[vma->vm_pgoff];
	if (!mem->size)
		return -EINVAL;
	page_offset = mem->addr & ~PAGE_MASK;
	if (check_add_overflow(mem->size, (resource_size_t)page_offset,
			       &map_size) ||
	    check_add_overflow(map_size, (resource_size_t)PAGE_SIZE - 1,
			       &rounded_size))
		return -EINVAL;
	map_pages = rounded_size >> PAGE_SHIFT;
	ret = hv_uio_mmap_validate(vma->vm_flags & VM_SHARED, map_pages, 0,
				   requested_pages);
	if (ret)
		return ret;

	pages = kvmalloc_array(requested_pages, sizeof(*pages), GFP_KERNEL);
	if (!pages)
		return -ENOMEM;

	addr = (void *)(unsigned long)mem->addr;
	for (i = 0; i < requested_pages; i++) {
		void *page_addr = (char *)addr + (i << PAGE_SHIFT);

		switch (mem->memtype) {
		case UIO_MEM_LOGICAL:
			pages[i] = virt_to_page(page_addr);
			break;
		case UIO_MEM_VIRTUAL:
			pages[i] = vmalloc_to_page(page_addr);
			break;
		default:
			ret = -EINVAL;
			goto out;
		}

		if (!pages[i]) {
			ret = -EINVAL;
			goto out;
		}
	}

	vm_flags_set(vma, VM_DONTEXPAND | VM_DONTDUMP);
	hv_uio_mmap_set_page_prot(vma, pdata, vma->vm_pgoff);
	ret = vm_map_pages_zero(vma, pages, requested_pages);

out:
	kvfree(pages);
	return ret;
}

/* Callback from VMBUS subsystem when new channel created. */
static void
hv_uio_new_channel(struct vmbus_channel *new_sc)
{
	struct hv_device *hv_dev = new_sc->primary_channel->device_obj;
	struct device *device = &hv_dev->device;
	const size_t ring_bytes = SZ_2M;
	int ret;

	/* Create host communication ring */
	ret = vmbus_open(new_sc, ring_bytes, ring_bytes, NULL, 0,
			 hv_uio_channel_cb, new_sc);
	if (ret) {
		dev_err(device, "vmbus_open subchannel failed: %d\n", ret);
		return;
	}

	set_channel_read_mode(new_sc, HV_CALL_ISR);
	ret = hv_create_ring_sysfs(new_sc, hv_uio_ring_mmap);
	if (ret) {
		dev_err(device, "sysfs create ring bin file failed; %d\n", ret);
		vmbus_close(new_sc);
	}
}

/*
 * Release the reserved buffers for send and receive.
 * Teardown before free so a live or uncertain GPADL is still resolved
 * from the recorded handle; vmbus_free_buffer() retains pages it cannot
 * prove are released. Probe error paths must not free buffers earlier.
 */
static void
hv_uio_cleanup(struct hv_device *dev, struct hv_uio_private_data *pdata)
{
	if (pdata->send_buf.gpadl_handle)
		vmbus_teardown_gpadl(dev->channel, &pdata->send_buf);
	vmbus_free_buffer(&pdata->send_buf);

	if (pdata->recv_buf.gpadl_handle)
		vmbus_teardown_gpadl(dev->channel, &pdata->recv_buf);
	vmbus_free_buffer(&pdata->recv_buf);
}

/* VMBus primary channel is opened on first use */
static int
hv_uio_open(struct uio_info *info, struct inode *inode)
{
	struct hv_uio_private_data *pdata
		= container_of(info, struct hv_uio_private_data, info);
	struct hv_device *dev = pdata->device;
	int ret;

	if (atomic_inc_return(&pdata->refcnt) != 1)
		return 0;

	vmbus_set_chn_rescind_callback(dev->channel, hv_uio_rescind);
	vmbus_set_sc_create_callback(dev->channel, hv_uio_new_channel);

	ret = vmbus_connect_ring(dev->channel,
				 hv_uio_channel_cb, dev->channel);
	if (ret)
		atomic_dec(&pdata->refcnt);

	return ret;
}

/* VMBus primary channel is closed on last close */
static int
hv_uio_release(struct uio_info *info, struct inode *inode)
{
	struct hv_uio_private_data *pdata
		= container_of(info, struct hv_uio_private_data, info);
	struct hv_device *dev = pdata->device;
	int ret = 0;

	if (atomic_dec_and_test(&pdata->refcnt))
		ret = vmbus_disconnect_ring(dev->channel);

	return ret;
}

static int
hv_uio_probe(struct hv_device *dev,
	     const struct hv_vmbus_device_id *dev_id)
{
	struct vmbus_channel *channel = dev->channel;
	struct hv_uio_private_data *pdata;
	void *ring_buffer;
	int ret;
	size_t ring_size = hv_dev_ring_size(channel);

	if (!ring_size)
		ring_size = SZ_2M;

	/* Adjust ring size if necessary to have it page aligned */
	ring_size = VMBUS_RING_SIZE(ring_size);

	pdata = devm_kzalloc(&dev->device, sizeof(*pdata), GFP_KERNEL);
	if (!pdata)
		return -ENOMEM;

	ret = vmbus_alloc_ring(channel, ring_size, ring_size);
	if (ret)
		return ret;

	set_channel_read_mode(channel, HV_CALL_ISR);

	/* Fill general uio info */
	pdata->info.name = "uio_hv_generic";
	pdata->info.version = DRIVER_VERSION;
	pdata->info.mmap = hv_uio_mmap;
	pdata->info.irqcontrol = hv_uio_irqcontrol;
	pdata->info.open = hv_uio_open;
	pdata->info.release = hv_uio_release;
	pdata->info.irq = UIO_IRQ_CUSTOM;
	atomic_set(&pdata->refcnt, 0);

	/* mem resources */
	pdata->info.mem[TXRX_RING_MAP].name = "txrx_rings";
	ring_buffer = channel->ringbuffer.addr;
	pdata->info.mem[TXRX_RING_MAP].addr = (uintptr_t)ring_buffer;
	pdata->info.mem[TXRX_RING_MAP].size
		= channel->ringbuffer_pagecount << PAGE_SHIFT;
	pdata->info.mem[TXRX_RING_MAP].memtype = UIO_MEM_VIRTUAL;

	pdata->info.mem[INT_PAGE_MAP].name = "int_page";
	pdata->info.mem[INT_PAGE_MAP].addr
		= (uintptr_t)vmbus_connection.int_page;
	pdata->info.mem[INT_PAGE_MAP].size = HV_HYP_PAGE_SIZE;
	pdata->info.mem[INT_PAGE_MAP].memtype = UIO_MEM_LOGICAL;

	pdata->info.mem[MON_PAGE_MAP].name = "monitor_page";
	pdata->info.mem[MON_PAGE_MAP].addr
		= (uintptr_t)vmbus_connection.monitor_pages[1];
	pdata->info.mem[MON_PAGE_MAP].size = HV_HYP_PAGE_SIZE;
	pdata->info.mem[MON_PAGE_MAP].memtype = UIO_MEM_LOGICAL;

	if (channel->device_id == HV_NIC) {
		ret = vmbus_alloc_buffer(channel, RECV_BUFFER_SIZE,
					 channel->co_external_memory,
					 &pdata->recv_buf);
		if (ret)
			goto fail_free_ring;

		ret = vmbus_establish_gpadl(channel, &pdata->recv_buf);
		if (ret)
			goto fail_close;

		/* put Global Physical Address Label in name */
		snprintf(pdata->recv_name, sizeof(pdata->recv_name),
			 "recv:%u", pdata->recv_buf.gpadl_handle);
		pdata->info.mem[RECV_BUF_MAP].name = pdata->recv_name;
		pdata->info.mem[RECV_BUF_MAP].addr =
			(uintptr_t)pdata->recv_buf.addr;
		pdata->info.mem[RECV_BUF_MAP].size = RECV_BUFFER_SIZE;
		pdata->info.mem[RECV_BUF_MAP].memtype = UIO_MEM_VIRTUAL;

		ret = vmbus_alloc_buffer(channel, SEND_BUFFER_SIZE,
					 channel->co_external_memory,
					 &pdata->send_buf);
		if (ret)
			goto fail_close;

		ret = vmbus_establish_gpadl(channel, &pdata->send_buf);
		if (ret)
			goto fail_close;

		snprintf(pdata->send_name, sizeof(pdata->send_name),
			 "send:%u", pdata->send_buf.gpadl_handle);
		pdata->info.mem[SEND_BUF_MAP].name = pdata->send_name;
		pdata->info.mem[SEND_BUF_MAP].addr =
			(uintptr_t)pdata->send_buf.addr;
		pdata->info.mem[SEND_BUF_MAP].size = SEND_BUFFER_SIZE;
		pdata->info.mem[SEND_BUF_MAP].memtype = UIO_MEM_VIRTUAL;
	}

	pdata->info.priv = pdata;
	pdata->device = dev;

	ret = uio_register_device(&dev->device, &pdata->info);
	if (ret) {
		dev_err(&dev->device, "hv_uio register failed\n");
		goto fail_close;
	}

	/*
	 * This internally calls sysfs_update_group, which returns a non-zero value if it executes
	 * before sysfs_create_group. This is expected as the 'ring' will be created later in
	 * vmbus_device_register() -> vmbus_add_channel_kobj(). Thus, no need to check the return
	 * value and print warning.
	 *
	 * Creating/exposing sysfs in driver probe is not encouraged as it can lead to race
	 * conditions with userspace. For backward compatibility, "ring" sysfs could not be removed
	 * or decoupled from uio_hv_generic probe. Userspace programs can make use of inotify
	 * APIs to make sure that ring is created.
	 */
	hv_create_ring_sysfs(channel, hv_uio_ring_mmap);

	hv_set_drvdata(dev, pdata);

	return 0;

fail_close:
	hv_uio_cleanup(dev, pdata);
fail_free_ring:
	vmbus_free_ring(dev->channel);

	return ret;
}

static void
hv_uio_remove(struct hv_device *dev)
{
	struct hv_uio_private_data *pdata = hv_get_drvdata(dev);

	if (!pdata)
		return;

	hv_remove_ring_sysfs(dev->channel);
	uio_unregister_device(&pdata->info);
	hv_uio_cleanup(dev, pdata);

	vmbus_free_ring(dev->channel);
}

static struct hv_driver hv_uio_drv = {
	.name = "uio_hv_generic",
	.id_table = NULL, /* only dynamic id's */
	.probe = hv_uio_probe,
	.remove = hv_uio_remove,
};

static int __init
hyperv_module_init(void)
{
	return vmbus_driver_register(&hv_uio_drv);
}

static void __exit
hyperv_module_exit(void)
{
	vmbus_driver_unregister(&hv_uio_drv);
}

module_init(hyperv_module_init);
module_exit(hyperv_module_exit);

MODULE_VERSION(DRIVER_VERSION);
MODULE_LICENSE("GPL v2");
MODULE_AUTHOR(DRIVER_AUTHOR);
MODULE_DESCRIPTION(DRIVER_DESC);
