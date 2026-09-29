// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2009, Microsoft Corporation.
 *
 * Authors:
 *   Haiyang Zhang <haiyangz@microsoft.com>
 *   Hank Janssen  <hjanssen@microsoft.com>
 */
#define pr_fmt(fmt) KBUILD_MODNAME ": " fmt

#include <linux/kernel.h>
#include <linux/sched.h>
#include <linux/wait.h>
#include <linux/mm.h>
#include <linux/overflow.h>
#include <linux/vmalloc.h>
#include <linux/slab.h>
#include <linux/log2.h>
#include <linux/module.h>
#include <linux/hyperv.h>
#include <linux/mutex.h>
#include <linux/workqueue.h>
#include <linux/uio.h>
#include <linux/interrupt.h>
#include <linux/set_memory.h>
#include <linux/export.h>
#include <asm/page.h>
#include <asm/mshyperv.h>
#if IS_ENABLED(CONFIG_KUNIT)
#include <kunit/test.h>
#endif

#include "hyperv_vmbus.h"

struct vmbus_buffer_retained {
	struct list_head list;
	struct delayed_work reclaim_work;
	void *addr;
	struct page **chunks;
	u32 chunk_cnt;
	u32 size;
	u32 gpadl_handle;
	enum vmbus_gpadl_state gpadl_state;
	bool leak;
	bool encryption_unknown;
	bool released;
	bool reclaiming;
};

typedef int (*vmbus_reencrypt_fn)(unsigned long, int);
typedef struct vmbus_channel_msginfo *(*vmbus_gpadl_info_alloc_fn)(void);

static int __vmbus_teardown_gpadl(struct vmbus_channel *channel,
				  struct vmbus_buffer *buffer,
				  vmbus_gpadl_info_alloc_fn alloc_info);
static bool vmbus_buffer_pages_busy(struct vmbus_buffer_retained *owner);
static void vmbus_buffer_reclaim_work(struct work_struct *work);
static bool __vmbus_free_buffer_mem(struct vmbus_buffer_retained *owner,
				    void *addr, struct page **chunks,
				    u32 chunk_cnt, struct page *unknown_page,
				    vmbus_reencrypt_fn reencrypt);

static bool vmbus_uses_shared_page_chunks(bool encrypted,
					  bool hv_isolated)
{
	return !encrypted && (hv_isolated || IS_ENABLED(CONFIG_ARM64));
}

static int vmbus_buffer_size_pages(u32 requested_size,
				   unsigned long *nr_pages,
				   u32 *aligned_size)
{
	unsigned long rounded_size;

	*nr_pages = 0;
	*aligned_size = 0;
	if (!requested_size ||
	    check_add_overflow((unsigned long)requested_size, PAGE_SIZE - 1,
			       &rounded_size))
		return -EINVAL;

	rounded_size &= PAGE_MASK;
	if (rounded_size > U32_MAX)
		return -EINVAL;

	*nr_pages = rounded_size >> PAGE_SHIFT;
	*aligned_size = rounded_size;
	return 0;
}

static LIST_HEAD(vmbus_retained_buffers);
static DEFINE_MUTEX(vmbus_retained_buffers_lock);
static struct workqueue_struct *vmbus_buffer_reclaim_wq;
static bool vmbus_buffer_reclaimer_stopping;
#if IS_ENABLED(CONFIG_KUNIT)
static unsigned int vmbus_test_reencrypt_calls;
#endif

enum vmbus_rescind_source {
	VMBUS_RESCIND_NONE,
	VMBUS_RESCIND_HOST,
	VMBUS_RESCIND_LOCAL,
};

enum vmbus_gpadl_teardown_event {
	VMBUS_GPADL_TEARDOWN_ACK,
	VMBUS_GPADL_TEARDOWN_HOST_RESCIND,
	VMBUS_GPADL_TEARDOWN_LOCAL_RESCIND,
	VMBUS_GPADL_TEARDOWN_FAILURE,
};

static enum vmbus_rescind_source
vmbus_channel_rescind_source(const struct vmbus_channel *channel)
{
	if (READ_ONCE(channel->rescind_from_host))
		return VMBUS_RESCIND_HOST;
	if (READ_ONCE(channel->rescind))
		return VMBUS_RESCIND_LOCAL;
	return VMBUS_RESCIND_NONE;
}

static int vmbus_gpadl_begin(struct vmbus_buffer *buffer, u32 handle)
{
	if (!handle || buffer->gpadl_state != VMBUS_GPADL_NONE ||
	    buffer->gpadl_handle)
		return -EBUSY;

	buffer->gpadl_handle = handle;
	buffer->gpadl_state = VMBUS_GPADL_PENDING;
	return 0;
}

static int vmbus_gpadl_teardown_begin(struct vmbus_buffer *buffer)
{
	if (!buffer->gpadl_handle)
		return -EINVAL;

	if (cmpxchg(&buffer->gpadl_state, VMBUS_GPADL_LIVE,
		    VMBUS_GPADL_TEARING_DOWN) != VMBUS_GPADL_LIVE)
		return -EINPROGRESS;

	return 0;
}

static void vmbus_gpadl_teardown_cancel(struct vmbus_buffer *buffer)
{
	cmpxchg(&buffer->gpadl_state, VMBUS_GPADL_TEARING_DOWN,
		VMBUS_GPADL_LIVE);
}

static int vmbus_gpadl_create_response(struct vmbus_buffer *buffer,
				       bool response_received,
				       u32 creation_status,
				       enum vmbus_rescind_source rescind_source)
{
	if (buffer->gpadl_state != VMBUS_GPADL_PENDING ||
	    !buffer->gpadl_handle)
		return -EINVAL;

	if (!response_received)
		return -ENODEV;

	if (creation_status) {
		buffer->gpadl_handle = 0;
		buffer->gpadl_state = VMBUS_GPADL_NONE;
		return -EDQUOT;
	}

	buffer->gpadl_state = VMBUS_GPADL_LIVE;
	return rescind_source != VMBUS_RESCIND_NONE ? -ENODEV : 0;
}

static void vmbus_gpadl_create_finish(struct vmbus_buffer *buffer)
{
	cmpxchg(&buffer->gpadl_state, VMBUS_GPADL_PENDING,
		VMBUS_GPADL_UNCERTAIN);
}

static int vmbus_gpadl_teardown_result(struct vmbus_channel *channel,
				       struct vmbus_buffer *buffer,
				       enum vmbus_gpadl_teardown_event event,
				       int ret)
{
	if (event == VMBUS_GPADL_TEARDOWN_ACK) {
		buffer->gpadl_handle = 0;
		buffer->gpadl_state = VMBUS_GPADL_NONE;
		return 0;
	}

	/*
	 * A host rescind revokes GPADLs that were already established. A create
	 * request with an uncertain response may still have a partial GPADL at
	 * the host, so retain that state. vmbus_free_buffer() separately retains
	 * backing pages while user mappings still reference them. Ownerless callers
	 * manage their own pages and must quiesce them before relying on host
	 * rescind; DXG stops the allocation before teardown.
	 */
	if (event == VMBUS_GPADL_TEARDOWN_HOST_RESCIND) {
		WARN_ON_ONCE(vmbus_channel_rescind_source(channel) !=
			     VMBUS_RESCIND_HOST);
		if (buffer->gpadl_state == VMBUS_GPADL_LIVE ||
		    buffer->gpadl_state == VMBUS_GPADL_TEARING_DOWN) {
			buffer->gpadl_handle = 0;
			buffer->gpadl_state = VMBUS_GPADL_NONE;
		}
		return 0;
	}

	/* Local unload/suspend rescinds do not prove host-side revocation. */
	if (event == VMBUS_GPADL_TEARDOWN_LOCAL_RESCIND)
		return ret ? ret : -ENODEV;

	return ret ? ret : -EIO;
}

static bool vmbus_buffer_should_free(const struct vmbus_buffer *buffer)
{
	return !buffer->leak && !buffer->gpadl_handle &&
	       buffer->gpadl_state == VMBUS_GPADL_NONE;
}

static bool
vmbus_buffer_owner_can_reclaim(const struct vmbus_buffer_retained *owner)
{
	return owner->released && !owner->reclaiming && !owner->leak &&
	       !owner->encryption_unknown &&
	       !owner->gpadl_handle &&
	       owner->gpadl_state == VMBUS_GPADL_NONE &&
	       (owner->addr || owner->chunks);
}

static struct vmbus_buffer_retained *vmbus_buffer_owner_alloc(void)
{
	struct vmbus_buffer_retained *owner;

	owner = kzalloc(sizeof(*owner), GFP_KERNEL);
	if (!owner)
		return NULL;

	INIT_LIST_HEAD(&owner->list);
	INIT_DELAYED_WORK(&owner->reclaim_work, vmbus_buffer_reclaim_work);

	mutex_lock(&vmbus_retained_buffers_lock);
	if (vmbus_buffer_reclaimer_stopping)
		goto err_unlock;
	if (!vmbus_buffer_reclaim_wq) {
		vmbus_buffer_reclaim_wq =
			alloc_workqueue("vmbus-buffer-reclaim",
					WQ_UNBOUND | WQ_MEM_RECLAIM, 1);
		if (!vmbus_buffer_reclaim_wq)
			goto err_unlock;
	}
	mutex_unlock(&vmbus_retained_buffers_lock);

	return owner;

err_unlock:
	mutex_unlock(&vmbus_retained_buffers_lock);
	kfree(owner);
	return NULL;
}

static void vmbus_buffer_retain_owner(struct vmbus_buffer_retained *owner)
{
	mutex_lock(&vmbus_retained_buffers_lock);
	if (list_empty(&owner->list))
		list_add_tail(&owner->list, &vmbus_retained_buffers);
	if (!vmbus_buffer_reclaimer_stopping && vmbus_buffer_reclaim_wq &&
	    vmbus_buffer_owner_can_reclaim(owner))
		mod_delayed_work(vmbus_buffer_reclaim_wq,
				 &owner->reclaim_work, 1);
	mutex_unlock(&vmbus_retained_buffers_lock);
}

static bool vmbus_buffer_pages_busy(struct vmbus_buffer_retained *owner)
{
	unsigned long page_count, i;

	if (owner->chunks) {
		if (!owner->chunk_cnt)
			return true;

		for (i = 0; i < owner->chunk_cnt; i++) {
			struct page *page = owner->chunks[i];

			if (WARN_ON_ONCE(!page) ||
			    folio_ref_count(page_folio(page)) != 1)
				return true;
		}

		return false;
	}

	if (!owner->addr || !owner->size ||
	    !IS_ALIGNED(owner->size, PAGE_SIZE) ||
	    !is_vmalloc_addr(owner->addr))
		return true;

	page_count = owner->size >> PAGE_SHIFT;
	for (i = 0; i < page_count; i++) {
		struct page *page = vmalloc_to_page((char *)owner->addr +
							    (i << PAGE_SHIFT));

		if (WARN_ON_ONCE(!page) ||
		    folio_ref_count(page_folio(page)) != 1)
			return true;
	}

	return false;
}

static void vmbus_buffer_reclaim_work(struct work_struct *work)
{
	struct vmbus_buffer_retained *owner = container_of(to_delayed_work(work),
								   struct vmbus_buffer_retained,
								   reclaim_work);
	bool retained;

	mutex_lock(&vmbus_retained_buffers_lock);
	if (vmbus_buffer_reclaimer_stopping ||
	    !vmbus_buffer_owner_can_reclaim(owner)) {
		mutex_unlock(&vmbus_retained_buffers_lock);
		return;
	}

	if (vmbus_buffer_pages_busy(owner)) {
		mod_delayed_work(vmbus_buffer_reclaim_wq,
				 &owner->reclaim_work, msecs_to_jiffies(1000));
		mutex_unlock(&vmbus_retained_buffers_lock);
		return;
	}

	owner->reclaiming = true;
	mutex_unlock(&vmbus_retained_buffers_lock);

	retained = __vmbus_free_buffer_mem(owner, owner->addr, owner->chunks,
					   owner->chunk_cnt, NULL,
					   set_memory_encrypted);

	mutex_lock(&vmbus_retained_buffers_lock);
	owner->reclaiming = false;
	if (retained) {
		if (!vmbus_buffer_reclaimer_stopping &&
		    vmbus_buffer_owner_can_reclaim(owner))
			mod_delayed_work(vmbus_buffer_reclaim_wq,
					 &owner->reclaim_work,
					 msecs_to_jiffies(1000));
		mutex_unlock(&vmbus_retained_buffers_lock);
		return;
	}

	if (!list_empty(&owner->list))
		list_del_init(&owner->list);
	mutex_unlock(&vmbus_retained_buffers_lock);
	kfree(owner);
}

void vmbus_buffer_reclaimer_shutdown(void)
{
	struct vmbus_buffer_retained *owner;
	struct workqueue_struct *wq;

	mutex_lock(&vmbus_retained_buffers_lock);
	vmbus_buffer_reclaimer_stopping = true;
	wq = vmbus_buffer_reclaim_wq;
	vmbus_buffer_reclaim_wq = NULL;
	list_for_each_entry(owner, &vmbus_retained_buffers, list)
		cancel_delayed_work(&owner->reclaim_work);
	mutex_unlock(&vmbus_retained_buffers_lock);

	if (wq)
		destroy_workqueue(wq);
}

static bool vmbus_buffer_retain(struct vmbus_buffer *buffer)
{
	struct vmbus_buffer_retained *owner = buffer->owner;

	if (WARN_ON_ONCE(!owner))
		return false;

	owner->addr = buffer->addr;
	owner->chunks = buffer->chunks;
	owner->chunk_cnt = buffer->chunk_cnt;
	owner->size = buffer->size;
	owner->gpadl_handle = buffer->gpadl_handle;
	owner->gpadl_state = buffer->gpadl_state;
	owner->leak = buffer->leak;
	owner->released = true;
	buffer->owner = NULL;
	vmbus_buffer_retain_owner(owner);
	return true;
}

/*
 * hv_gpadl_size - Return the real size of a gpadl, the size that Hyper-V uses
 *
 * For BUFFER gpadl, Hyper-V uses the exact same size as the guest does.
 *
 * For RING gpadl, in each ring, the guest uses one PAGE_SIZE as the header
 * (because of the alignment requirement), however, the hypervisor only
 * uses the first HV_HYP_PAGE_SIZE as the header, therefore leaving a
 * (PAGE_SIZE - HV_HYP_PAGE_SIZE) gap. And since there are two rings in a
 * ringbuffer, the total size for a RING gpadl that Hyper-V uses is the
 * total size that the guest uses minus twice of the gap size.
 */
static inline u32 hv_gpadl_size(enum hv_gpadl_type type, u32 size)
{
	switch (type) {
	case HV_GPADL_BUFFER:
		return size;
	case HV_GPADL_RING:
		/* The size of a ringbuffer must be page-aligned */
		BUG_ON(size % PAGE_SIZE);
		/*
		 * Two things to notice here:
		 * 1) We're processing two ring buffers as a unit
		 * 2) We're skipping any space larger than HV_HYP_PAGE_SIZE in
		 * the first guest-size page of each of the two ring buffers.
		 * So we effectively subtract out two guest-size pages, and add
		 * back two Hyper-V size pages.
		 */
		return size - 2 * (PAGE_SIZE - HV_HYP_PAGE_SIZE);
	}
	BUG();
	return 0;
}

/*
 * hv_ring_gpadl_send_hvpgoffset - Calculate the send offset (in unit of
 *                                 HV_HYP_PAGE) in a ring gpadl based on the
 *                                 offset in the guest
 *
 * @offset: the offset (in bytes) where the send ringbuffer starts in the
 *               virtual address space of the guest
 */
static inline u32 hv_ring_gpadl_send_hvpgoffset(u32 offset)
{

	/*
	 * For RING gpadl, in each ring, the guest uses one PAGE_SIZE as the
	 * header (because of the alignment requirement), however, the
	 * hypervisor only uses the first HV_HYP_PAGE_SIZE as the header,
	 * therefore leaving a (PAGE_SIZE - HV_HYP_PAGE_SIZE) gap.
	 *
	 * And to calculate the effective send offset in gpadl, we need to
	 * substract this gap.
	 */
	return (offset - (PAGE_SIZE - HV_HYP_PAGE_SIZE)) >> HV_HYP_PAGE_SHIFT;
}

/*
 * hv_gpadl_hvpfn - Return the Hyper-V page PFN of the @i th Hyper-V page in
 *                  the gpadl
 *
 * @type: the type of the gpadl
 * @kbuffer: the pointer to the gpadl in the guest
 * @size: the total size (in bytes) of the gpadl
 * @send_offset: the offset (in bytes) where the send ringbuffer starts in the
 *               virtual address space of the guest
 * @i: the index
 */
static inline u64 hv_gpadl_hvpfn(enum hv_gpadl_type type, void *kbuffer,
				 u32 size, u32 send_offset, int i)
{
	int send_idx = hv_ring_gpadl_send_hvpgoffset(send_offset);
	unsigned long delta = 0UL;

	switch (type) {
	case HV_GPADL_BUFFER:
		break;
	case HV_GPADL_RING:
		if (i == 0)
			delta = 0;
		else if (i <= send_idx)
			delta = PAGE_SIZE - HV_HYP_PAGE_SIZE;
		else
			delta = 2 * (PAGE_SIZE - HV_HYP_PAGE_SIZE);
		break;
	default:
		BUG();
		break;
	}

	return virt_to_hvpfn(kbuffer + delta + (HV_HYP_PAGE_SIZE * i));
}

/*
 * vmbus_setevent- Trigger an event notification on the specified
 * channel.
 */
void vmbus_setevent(struct vmbus_channel *channel)
{
	struct hv_monitor_page *monitorpage;

	trace_vmbus_setevent(channel);

	/*
	 * For channels marked as in "low latency" mode
	 * bypass the monitor page mechanism.
	 */
	if (channel->offermsg.monitor_allocated && !channel->low_latency) {
		vmbus_send_interrupt(channel->offermsg.child_relid);

		/* Get the child to parent monitor page */
		monitorpage = vmbus_connection.monitor_pages[1];

		sync_set_bit(channel->monitor_bit,
			(unsigned long *)&monitorpage->trigger_group
					[channel->monitor_grp].pending);

	} else {
		vmbus_set_event(channel);
	}
}
EXPORT_SYMBOL_GPL(vmbus_setevent);

/* vmbus_free_ring - drop mapping of ring buffer */
void vmbus_free_ring(struct vmbus_channel *channel)
{
	struct vmbus_buffer *buffer = &channel->ringbuffer;

	hv_ringbuffer_cleanup(&channel->outbound);
	hv_ringbuffer_cleanup(&channel->inbound);

	vmbus_free_buffer(buffer);
}
EXPORT_SYMBOL_GPL(vmbus_free_ring);

/* vmbus_alloc_ring - allocate and map pages for ring buffer */
int vmbus_alloc_ring(struct vmbus_channel *newchannel,
		     u32 send_size, u32 recv_size)
{
	struct vmbus_buffer *buffer = &newchannel->ringbuffer;
	u32 size;
	u32 i;
	int err;

	if (!send_size || !recv_size ||
	    send_size % PAGE_SIZE || recv_size % PAGE_SIZE ||
	    check_add_overflow(send_size, recv_size, &size))
		return -EINVAL;

	err = vmbus_alloc_buffer(newchannel, size,
				 newchannel->co_ring_buffer, buffer);
	if (err)
		return err;

	newchannel->ringbuffer_pagecount = size >> PAGE_SHIFT;
	newchannel->ringbuffer_send_offset = send_size >> PAGE_SHIFT;
	buffer->pages = kvcalloc(newchannel->ringbuffer_pagecount,
				 sizeof(*buffer->pages), GFP_KERNEL);
	if (!buffer->pages) {
		vmbus_free_buffer(buffer);
		return -ENOMEM;
	}

	for (i = 0; i < newchannel->ringbuffer_pagecount; i++)
		buffer->pages[i] = vmalloc_to_page(buffer->addr + (i << PAGE_SHIFT));

	return 0;
}
EXPORT_SYMBOL_GPL(vmbus_alloc_ring);

/* Used for Hyper-V Socket: a guest client's connect() to the host */
int vmbus_send_tl_connect_request(const guid_t *shv_guest_servie_id,
				  const guid_t *shv_host_servie_id)
{
	struct vmbus_channel_tl_connect_request conn_msg;
	int ret;

	memset(&conn_msg, 0, sizeof(conn_msg));
	conn_msg.header.msgtype = CHANNELMSG_TL_CONNECT_REQUEST;
	conn_msg.guest_endpoint_id = *shv_guest_servie_id;
	conn_msg.host_service_id = *shv_host_servie_id;

	ret = vmbus_post_msg(&conn_msg, sizeof(conn_msg), true);

	trace_vmbus_send_tl_connect_request(&conn_msg, ret);

	return ret;
}
EXPORT_SYMBOL_GPL(vmbus_send_tl_connect_request);

static int send_modifychannel_without_ack(struct vmbus_channel *channel, u32 target_vp)
{
	struct vmbus_channel_modifychannel msg;
	int ret;

	memset(&msg, 0, sizeof(msg));
	msg.header.msgtype = CHANNELMSG_MODIFYCHANNEL;
	msg.child_relid = channel->offermsg.child_relid;
	msg.target_vp = target_vp;

	ret = vmbus_post_msg(&msg, sizeof(msg), true);
	trace_vmbus_send_modifychannel(&msg, ret);

	return ret;
}

static int send_modifychannel_with_ack(struct vmbus_channel *channel, u32 target_vp)
{
	struct vmbus_channel_modifychannel *msg;
	struct vmbus_channel_msginfo *info;
	unsigned long flags;
	int ret;

	info = kzalloc(sizeof(struct vmbus_channel_msginfo) +
				sizeof(struct vmbus_channel_modifychannel),
		       GFP_KERNEL);
	if (!info)
		return -ENOMEM;

	init_completion(&info->waitevent);
	info->waiting_channel = channel;

	msg = (struct vmbus_channel_modifychannel *)info->msg;
	msg->header.msgtype = CHANNELMSG_MODIFYCHANNEL;
	msg->child_relid = channel->offermsg.child_relid;
	msg->target_vp = target_vp;

	spin_lock_irqsave(&vmbus_connection.channelmsg_lock, flags);
	list_add_tail(&info->msglistentry, &vmbus_connection.chn_msg_list);
	spin_unlock_irqrestore(&vmbus_connection.channelmsg_lock, flags);

	ret = vmbus_post_msg(msg, sizeof(*msg), true);
	trace_vmbus_send_modifychannel(msg, ret);
	if (ret != 0) {
		spin_lock_irqsave(&vmbus_connection.channelmsg_lock, flags);
		list_del(&info->msglistentry);
		spin_unlock_irqrestore(&vmbus_connection.channelmsg_lock, flags);
		goto free_info;
	}

	/*
	 * Release channel_mutex; otherwise, vmbus_onoffer_rescind() could block on
	 * the mutex and be unable to signal the completion.
	 *
	 * See the caller target_cpu_store() for information about the usage of the
	 * mutex.
	 */
	mutex_unlock(&vmbus_connection.channel_mutex);
	wait_for_completion(&info->waitevent);
	mutex_lock(&vmbus_connection.channel_mutex);

	spin_lock_irqsave(&vmbus_connection.channelmsg_lock, flags);
	list_del(&info->msglistentry);
	spin_unlock_irqrestore(&vmbus_connection.channelmsg_lock, flags);

	if (info->response.modify_response.status)
		ret = -EAGAIN;

free_info:
	kfree(info);
	return ret;
}

/*
 * Set/change the vCPU (@target_vp) the channel (@child_relid) will interrupt.
 *
 * CHANNELMSG_MODIFYCHANNEL messages are aynchronous.  When VMbus version 5.3
 * or later is negotiated, Hyper-V always sends an ACK in response to such a
 * message.  For VMbus version 5.2 and earlier, it never sends an ACK.  With-
 * out an ACK, we can not know when the host will stop interrupting the "old"
 * vCPU and start interrupting the "new" vCPU for the given channel.
 *
 * The CHANNELMSG_MODIFYCHANNEL message type is supported since VMBus version
 * VERSION_WIN10_V4_1.
 */
int vmbus_send_modifychannel(struct vmbus_channel *channel, u32 target_vp)
{
	if (vmbus_proto_version >= VERSION_WIN10_V5_3)
		return send_modifychannel_with_ack(channel, target_vp);
	return send_modifychannel_without_ack(channel, target_vp);
}
EXPORT_SYMBOL_GPL(vmbus_send_modifychannel);

/*
 * create_gpadl_header - Creates a gpadl for the specified buffer
 */
static int create_gpadl_header(enum hv_gpadl_type type, void *kbuffer,
			       u32 size, u32 send_offset,
			       struct vmbus_channel_msginfo **msginfo)
{
	int i;
	int pagecount;
	struct vmbus_channel_gpadl_header *gpadl_header;
	struct vmbus_channel_gpadl_body *gpadl_body;
	struct vmbus_channel_msginfo *msgheader;
	struct vmbus_channel_msginfo *msgbody = NULL;
	u32 msgsize;

	int pfnsum, pfncount, pfnleft, pfncurr, pfnsize;

	pagecount = hv_gpadl_size(type, size) >> HV_HYP_PAGE_SHIFT;

	pfnsize = MAX_SIZE_CHANNEL_MESSAGE -
		  sizeof(struct vmbus_channel_gpadl_header) -
		  sizeof(struct gpa_range);
	pfncount = umin(pagecount, pfnsize / sizeof(u64));

	msgsize = sizeof(struct vmbus_channel_msginfo) +
		  sizeof(struct vmbus_channel_gpadl_header) +
		  sizeof(struct gpa_range) + pfncount * sizeof(u64);
	msgheader =  kzalloc(msgsize, GFP_KERNEL);
	if (!msgheader)
		return -ENOMEM;

	INIT_LIST_HEAD(&msgheader->submsglist);
	msgheader->msgsize = msgsize;

	gpadl_header = (struct vmbus_channel_gpadl_header *)
		msgheader->msg;
	gpadl_header->rangecount = 1;
	gpadl_header->range_buflen = sizeof(struct gpa_range) +
				 pagecount * sizeof(u64);
	gpadl_header->range[0].byte_offset = 0;
	gpadl_header->range[0].byte_count = hv_gpadl_size(type, size);
	for (i = 0; i < pfncount; i++)
		gpadl_header->range[0].pfn_array[i] = hv_gpadl_hvpfn(
			type, kbuffer, size, send_offset, i);
	*msginfo = msgheader;

	pfnsum = pfncount;
	pfnleft = pagecount - pfncount;

	/* how many pfns can we fit in a body message */
	pfnsize = MAX_SIZE_CHANNEL_MESSAGE -
		  sizeof(struct vmbus_channel_gpadl_body);
	pfncount = pfnsize / sizeof(u64);

	/*
	 * If pfnleft is zero, everything fits in the header and no body
	 * messages are needed
	 */
	while (pfnleft) {
		pfncurr = umin(pfncount, pfnleft);
		msgsize = sizeof(struct vmbus_channel_msginfo) +
			  sizeof(struct vmbus_channel_gpadl_body) +
			  pfncurr * sizeof(u64);
		msgbody = kzalloc(msgsize, GFP_KERNEL);

		if (!msgbody) {
			struct vmbus_channel_msginfo *pos = NULL;
			struct vmbus_channel_msginfo *tmp = NULL;
			/*
			 * Free up all the allocated messages.
			 */
			list_for_each_entry_safe(pos, tmp,
				&msgheader->submsglist,
				msglistentry) {

				list_del(&pos->msglistentry);
				kfree(pos);
			}
			kfree(msgheader);
			return -ENOMEM;
		}

		msgbody->msgsize = msgsize;
		gpadl_body = (struct vmbus_channel_gpadl_body *)msgbody->msg;

		/*
		 * Gpadl is u32 and we are using a pointer which could
		 * be 64-bit
		 * This is governed by the guest/host protocol and
		 * so the hypervisor guarantees that this is ok.
		 */
		for (i = 0; i < pfncurr; i++)
			gpadl_body->pfn[i] = hv_gpadl_hvpfn(type,
				kbuffer, size, send_offset, pfnsum + i);

		/* add to msg header */
		list_add_tail(&msgbody->msglistentry, &msgheader->submsglist);
		pfnsum += pfncurr;
		pfnleft -= pfncurr;
	}

	return 0;
}

static void vmbus_free_channel_msginfo(struct vmbus_channel_msginfo *msginfo)
{
	struct vmbus_channel_msginfo *submsginfo, *tmp;

	list_for_each_entry_safe(submsginfo, tmp, &msginfo->submsglist,
				 msglistentry) {
		kfree(submsginfo);
	}

	kfree(msginfo);
}

/*
 * __vmbus_establish_gpadl - Establish a GPADL for a buffer or ringbuffer
 *
 * @channel: a channel
 * @type: BUFFER or RING (Hyper-V page-size accounting only)
 * @buffer: buffer filled by vmbus_alloc_buffer(); @buffer->addr must already
 *          be host-visible. vmbus_alloc_buffer() owns CoCo decryption, so
 *          this function never changes encryption state.
 * @send_offset: the offset (in bytes) where the send ring buffer starts,
 *              should be 0 for BUFFER type gpadl
 */
static int __vmbus_establish_gpadl(struct vmbus_channel *channel,
				   enum hv_gpadl_type type,
				   struct vmbus_buffer *buffer,
				   u32 send_offset)
{
	struct vmbus_channel_gpadl_header *gpadlmsg;
	struct vmbus_channel_gpadl_body *gpadl_body;
	struct vmbus_channel_msginfo *msginfo = NULL;
	struct vmbus_channel_msginfo *submsginfo;
	struct list_head *curr;
	u32 next_gpadl_handle;
	unsigned long flags;
	int ret = 0;

	if (!buffer->addr || !buffer->size)
		return -EINVAL;

	next_gpadl_handle =
		(atomic_inc_return(&vmbus_connection.next_gpadl_handle) - 1);

	ret = create_gpadl_header(type, buffer->addr, buffer->size, send_offset,
				  &msginfo);
	if (ret)
		return ret;

	init_completion(&msginfo->waitevent);
	msginfo->waiting_channel = channel;

	gpadlmsg = (struct vmbus_channel_gpadl_header *)msginfo->msg;
	gpadlmsg->header.msgtype = CHANNELMSG_GPADL_HEADER;
	gpadlmsg->child_relid = channel->offermsg.child_relid;
	gpadlmsg->gpadl = next_gpadl_handle;

	spin_lock_irqsave(&vmbus_connection.channelmsg_lock, flags);
	list_add_tail(&msginfo->msglistentry,
		      &vmbus_connection.chn_msg_list);
	spin_unlock_irqrestore(&vmbus_connection.channelmsg_lock, flags);

	if (vmbus_channel_rescind_source(channel) != VMBUS_RESCIND_NONE) {
		ret = -ENODEV;
		goto cleanup;
	}

	/* Record the candidate before posting: even an errored post may arrive. */
	ret = vmbus_gpadl_begin(buffer, next_gpadl_handle);
	if (ret)
		goto cleanup;

	ret = vmbus_post_msg(gpadlmsg, msginfo->msgsize -
			     sizeof(*msginfo), true);

	trace_vmbus_establish_gpadl_header(gpadlmsg, ret);

	if (ret != 0)
		goto cleanup;

	list_for_each(curr, &msginfo->submsglist) {
		if (vmbus_channel_rescind_source(channel) !=
		    VMBUS_RESCIND_NONE) {
			ret = -ENODEV;
			goto cleanup;
		}

		submsginfo = (struct vmbus_channel_msginfo *)curr;
		gpadl_body =
			(struct vmbus_channel_gpadl_body *)submsginfo->msg;

		gpadl_body->header.msgtype =
			CHANNELMSG_GPADL_BODY;
		gpadl_body->gpadl = next_gpadl_handle;

		ret = vmbus_post_msg(gpadl_body,
				     submsginfo->msgsize - sizeof(*submsginfo),
				     true);

		trace_vmbus_establish_gpadl_body(gpadl_body, ret);

		if (ret != 0)
			goto cleanup;
	}
	wait_for_completion(&msginfo->waitevent);

	ret = vmbus_gpadl_create_response(buffer,
					  msginfo->response.gpadl_created.header.msgtype ==
							  CHANNELMSG_GPADL_CREATED,
					  msginfo->response.gpadl_created.creation_status,
					  vmbus_channel_rescind_source(channel));
	if (ret == -EDQUOT)
		pr_err("Failed to establish GPADL: err = 0x%x\n",
		       msginfo->response.gpadl_created.creation_status);
	if (ret)
		goto cleanup;

cleanup:
	/* No create post or response can still be in flight after this point. */
	vmbus_gpadl_create_finish(buffer);
	spin_lock_irqsave(&vmbus_connection.channelmsg_lock, flags);
	list_del(&msginfo->msglistentry);
	spin_unlock_irqrestore(&vmbus_connection.channelmsg_lock, flags);

	vmbus_free_channel_msginfo(msginfo);

	return ret;
}

/*
 * vmbus_establish_gpadl - Establish a GPADL for the specified buffer
 *
 * @channel: a channel
 * @buffer: buffer filled by vmbus_alloc_buffer()
 */
int vmbus_establish_gpadl(struct vmbus_channel *channel,
			  struct vmbus_buffer *buffer)
{
	return __vmbus_establish_gpadl(channel, HV_GPADL_BUFFER, buffer, 0U);
}
EXPORT_SYMBOL_GPL(vmbus_establish_gpadl);

/**
 * __vmbus_free_buffer_mem - free the backing memory of a vmbus_buffer
 *
 * @addr: buffer address (virtually contiguous)
 * @chunks: chunks array from vmbus_alloc_buffer(), or NULL
 * @chunk_cnt: number of entries in @chunks
 * @unknown_page: chunk whose encryption transition failed and is unknown
 *
 * When @chunks is NULL the buffer is a plain vzalloc() allocation.
 *
 * Otherwise tear down the vmap, and for each chunk re-encrypt and free
 * the underlying pages. Chunks with unknown encryption remain owned by the
 * retained-buffer list.
 */
static bool __vmbus_free_buffer_mem(struct vmbus_buffer_retained *owner,
				    void *addr, struct page **chunks,
				    u32 chunk_cnt, struct page *unknown_page,
				    vmbus_reencrypt_fn reencrypt)
{
	u32 i, retained_cnt = 0;

	if (!chunks) {
		if (!addr)
			return false;

		owner->addr = addr;
		owner->chunks = NULL;
		owner->chunk_cnt = 0;
		if (vmbus_buffer_pages_busy(owner)) {
			owner->gpadl_handle = 0;
			owner->gpadl_state = VMBUS_GPADL_NONE;
			vmbus_buffer_retain_owner(owner);
			return true;
		}

		vfree(addr);
		return false;
	}

	if (addr)
		vunmap(addr);
	owner->addr = NULL;
	owner->chunks = chunks;
	owner->chunk_cnt = chunk_cnt;

	if (!unknown_page && chunk_cnt && vmbus_buffer_pages_busy(owner)) {
		owner->gpadl_handle = 0;
		owner->gpadl_state = VMBUS_GPADL_NONE;
		vmbus_buffer_retain_owner(owner);
		return true;
	}

	for (i = 0; i < chunk_cnt; i++) {
		unsigned long vaddr =
			(unsigned long)page_address(chunks[i]);
		unsigned int order = folio_order(page_folio(chunks[i]));

		if (chunks[i] == unknown_page ||
		    reencrypt(vaddr, 1U << order)) {
			chunks[retained_cnt++] = chunks[i];
			continue;
		}
		__free_pages(chunks[i], order);
	}

	if (retained_cnt) {
		owner->addr = NULL;
		owner->chunks = chunks;
		owner->chunk_cnt = retained_cnt;
		owner->gpadl_handle = 0;
		owner->gpadl_state = VMBUS_GPADL_NONE;
		owner->leak = true;
		owner->encryption_unknown = true;
		owner->released = true;
		vmbus_buffer_retain_owner(owner);
		return true;
	}

	kvfree(chunks);
	return false;
}

/**
 * vmbus_free_buffer - release a buffer filled by vmbus_alloc_buffer()
 *
 * @buffer: buffer from vmbus_alloc_buffer()
 *
 * Safe to call twice. A pending/live/tearing-down GPADL or independent leak
 * state moves the complete ownership record to the retained-buffer list.
 * Memory with uncertain GPADL ownership is not re-encrypted or released. A
 * teardown acknowledgment permits release unless independent leak state
 * remains.
 */
static void __vmbus_free_buffer(struct vmbus_buffer *buffer,
				vmbus_reencrypt_fn reencrypt)
{
	struct vmbus_buffer_retained *owner = buffer->owner;
	bool keep_pages = !vmbus_buffer_should_free(buffer);
	bool retained;

	if (!owner) {
		if (vmbus_buffer_should_free(buffer) && !buffer->addr &&
		    !buffer->chunks && !buffer->pages)
			return;
		WARN_ON_ONCE(1);
		return;
	}

	/* pages[] is just the ring page-pointer array, not the ring itself */
	kvfree(buffer->pages);

	if (keep_pages) {
		if (!vmbus_buffer_retain(buffer))
			return;
		memset(buffer, 0, sizeof(*buffer));
		return;
	}

	owner->released = true;
	retained = __vmbus_free_buffer_mem(owner, buffer->addr,
					   buffer->chunks,
					   buffer->chunk_cnt, NULL,
					   reencrypt);
	if (!retained)
		kfree(owner);

	memset(buffer, 0, sizeof(*buffer));
}

void vmbus_free_buffer(struct vmbus_buffer *buffer)
{
	__vmbus_free_buffer(buffer, set_memory_encrypted);
}
EXPORT_SYMBOL_GPL(vmbus_free_buffer);

#if IS_ENABLED(CONFIG_KUNIT)
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
	retained = __vmbus_free_buffer_mem(owner, NULL, chunks, 1, NULL,
					   vmbus_test_reencrypt_fail);

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
	retained = __vmbus_free_buffer_mem(owner, NULL, chunks, 1, NULL,
					   vmbus_test_reencrypt_ok);
	KUNIT_EXPECT_TRUE(test, retained);
	KUNIT_EXPECT_EQ(test, vmbus_test_reencrypt_calls, 0U);

	if (retained) {
		KUNIT_EXPECT_PTR_EQ(test, owner->chunks[0], page);
		KUNIT_EXPECT_EQ(test, owner->chunk_cnt, 1U);
		put_page(page);
		retained = __vmbus_free_buffer_mem(owner, NULL, owner->chunks,
						   owner->chunk_cnt, NULL,
						   vmbus_test_reencrypt_ok);
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

	retained = __vmbus_free_buffer_mem(owner, addr, NULL, 0, NULL,
					   vmbus_test_reencrypt_ok);
	KUNIT_ASSERT_TRUE(test, retained);
	KUNIT_EXPECT_PTR_EQ(test, owner->addr, addr);
	put_page(page);

	retained = __vmbus_free_buffer_mem(owner, owner->addr, NULL, 0, NULL,
					   vmbus_test_reencrypt_ok);
	KUNIT_EXPECT_FALSE(test, retained);
	owner->addr = NULL;
	vmbus_test_drop_retained(owner);
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
	KUNIT_CASE(vmbus_buffer_cleanup_repeated_test),
	{}
};

static struct kunit_suite vmbus_gpadl_lifetime_test_suite = {
	.name = "hyperv-vmbus-gpadl-lifetime",
	.test_cases = vmbus_gpadl_lifetime_test_cases,
};

kunit_test_suite(vmbus_gpadl_lifetime_test_suite);
#endif

/**
 * vmbus_alloc_buffer - allocate a virtually-contiguous VMBus buffer
 *
 * @channel: channel the buffer will be attached to
 * @size: requested size in bytes (rounded up to PAGE_SIZE)
 * @encrypted: true if the buffer stays guest-private (e.g. co_ring_buffer,
 *             co_external_memory); false if the host will map it via GPADL
 * @buffer: output descriptor, zeroed on failure
 *
 * Guest-private buffers use vzalloc() and never touch encryption state.
 * Non-isolated x86 VMs also use vzalloc(). Arm64 host-visible buffers use
 * page chunks because the generic arm64 memory-encryption API is not reported
 * by Hyper-V's weak isolation query.
 *
 * Host-visible buffers in an isolated VM are built from physically-contiguous
 * chunks (MAX_PAGE_ORDER downward). Each chunk is decrypted on its direct-map
 * address via set_memory_decrypted(), then all chunks are joined with vmap().
 * This function is the only place that changes encryption state;
 * vmbus_establish_gpadl() must not decrypt again (it cannot: set_memory_*()
 * does not work on vmalloc addresses in arm64 CCA / TDX-without-paravisor).
 *
 * Return: 0 on success, -ENOMEM or -EINVAL on failure.
 */
int vmbus_alloc_buffer(struct vmbus_channel *channel,
		       u32 size,
		       bool encrypted,
		       struct vmbus_buffer *buffer)
{
	unsigned long nr_pages;
	unsigned long remaining;
	unsigned long page_idx = 0;
	struct vmbus_buffer_retained *owner;
	struct page **chunks = NULL;
	struct page **pages = NULL;
	struct page *unknown_page = NULL;
	int order = MAX_PAGE_ORDER;
	u32 aligned_size;
	u32 chunk_cnt = 0;
	void *addr;
	u32 i;
	int ret;

	memset(buffer, 0, sizeof(*buffer));
	ret = vmbus_buffer_size_pages(size, &nr_pages, &aligned_size);
	if (ret)
		return ret;
	remaining = nr_pages;

	owner = vmbus_buffer_owner_alloc();
	if (!owner)
		return -ENOMEM;
	buffer->owner = owner;

	buffer->size = aligned_size;
	owner->size = buffer->size;
	/* Guest-private, or no isolation: nothing to decrypt */
	if (!vmbus_uses_shared_page_chunks(encrypted,
					   hv_is_isolation_supported())) {
		buffer->addr = vzalloc(buffer->size);
		if (buffer->addr)
			return 0;
		kfree(owner);
		memset(buffer, 0, sizeof(*buffer));
		return -ENOMEM;
	}

	/* Worst case: every chunk is a single page. */
	chunks = kvmalloc_objs(*chunks, nr_pages, GFP_KERNEL | __GFP_ZERO);
	if (!chunks)
		goto err;

	pages = kvmalloc_objs(*pages, nr_pages);
	if (!pages)
		goto err;

	while (remaining) {
		struct page *page;
		gfp_t gfp;

		order = min(order, ilog2(remaining));

		/*
		 * Use __GFP_NORETRY | __GFP_NOWARN to avoid OOM-killing,
		 * but try harder at order 0 since that is the final
		 * fallback.
		 * __GFP_COMP stores order information in the page folio.
		 */
		gfp = GFP_KERNEL | __GFP_ZERO;
		if (order)
			gfp |= __GFP_COMP | __GFP_NORETRY | __GFP_NOWARN;

		page = alloc_pages_node(cpu_to_node(channel->target_cpu),
					gfp, order);
		if (!page) {
			if (!order--)
				goto err;
			continue;
		}

		ret = set_memory_decrypted((unsigned long)page_address(page),
					   1U << order);
		if (ret) {
			/*
			 * set_memory_decrypted() failed; the page state is
			 * unknown so it must be leaked rather than freed.
			 */
			unknown_page = page;
			chunks[chunk_cnt++] = page;
			goto err;
		}

		chunks[chunk_cnt++] = page;

		for (i = 0; i < (1U << order); i++)
			pages[page_idx++] = page + i;

		remaining -= 1U << order;
	}

	addr = vmap(pages, nr_pages, VM_MAP, pgprot_decrypted(PAGE_KERNEL));
	if (!addr)
		goto err;

	memset(addr, 0, nr_pages << PAGE_SHIFT);

	kvfree(pages);
	buffer->addr = addr;
	buffer->chunks = chunks;
	buffer->chunk_cnt = chunk_cnt;
	return 0;

err:
	kvfree(pages);
	owner->released = true;
	if (!__vmbus_free_buffer_mem(owner, NULL, chunks, chunk_cnt,
				     unknown_page, set_memory_encrypted))
		kfree(owner);
	memset(buffer, 0, sizeof(*buffer));
	return -ENOMEM;
}
EXPORT_SYMBOL_GPL(vmbus_alloc_buffer);

/**
 * request_arr_init - Allocates memory for the requestor array. Each slot
 * keeps track of the next available slot in the array. Initially, each
 * slot points to the next one (as in a Linked List). The last slot
 * does not point to anything, so its value is U64_MAX by default.
 * @size The size of the array
 */
static u64 *request_arr_init(u32 size)
{
	int i;
	u64 *req_arr;

	req_arr = kcalloc(size, sizeof(u64), GFP_KERNEL);
	if (!req_arr)
		return NULL;

	for (i = 0; i < size - 1; i++)
		req_arr[i] = i + 1;

	/* Last slot (no more available slots) */
	req_arr[i] = U64_MAX;

	return req_arr;
}

/*
 * vmbus_alloc_requestor - Initializes @rqstor's fields.
 * Index 0 is the first free slot
 * @size: Size of the requestor array
 */
static int vmbus_alloc_requestor(struct vmbus_requestor *rqstor, u32 size)
{
	u64 *rqst_arr;
	unsigned long *bitmap;

	rqst_arr = request_arr_init(size);
	if (!rqst_arr)
		return -ENOMEM;

	bitmap = bitmap_zalloc(size, GFP_KERNEL);
	if (!bitmap) {
		kfree(rqst_arr);
		return -ENOMEM;
	}

	rqstor->req_arr = rqst_arr;
	rqstor->req_bitmap = bitmap;
	rqstor->size = size;
	rqstor->next_request_id = 0;
	spin_lock_init(&rqstor->req_lock);

	return 0;
}

/*
 * vmbus_free_requestor - Frees memory allocated for @rqstor
 * @rqstor: Pointer to the requestor struct
 */
static void vmbus_free_requestor(struct vmbus_requestor *rqstor)
{
	kfree(rqstor->req_arr);
	bitmap_free(rqstor->req_bitmap);
}

static int __vmbus_open(struct vmbus_channel *newchannel,
		       void *userdata, u32 userdatalen,
		       void (*onchannelcallback)(void *context), void *context)
{
	struct vmbus_channel_open_channel *open_msg;
	struct vmbus_channel_msginfo *open_info = NULL;
	struct vmbus_buffer *buffer = &newchannel->ringbuffer;
	u32 send_pages, recv_pages;
	unsigned long flags;
	int err;

	if (userdatalen > MAX_USER_DEFINED_BYTES)
		return -EINVAL;

	send_pages = newchannel->ringbuffer_send_offset;
	recv_pages = newchannel->ringbuffer_pagecount - send_pages;

	if (newchannel->state != CHANNEL_OPEN_STATE)
		return -EINVAL;

	/* Create and init requestor */
	if (newchannel->rqstor_size) {
		if (vmbus_alloc_requestor(&newchannel->requestor, newchannel->rqstor_size))
			return -ENOMEM;
	}

	newchannel->state = CHANNEL_OPENING_STATE;
	newchannel->onchannel_callback = onchannelcallback;
	newchannel->channel_callback_context = context;

	if (!newchannel->max_pkt_size)
		newchannel->max_pkt_size = VMBUS_DEFAULT_MAX_PKT_SIZE;

	/* Establish the gpadl for the ring buffer */
	err = __vmbus_establish_gpadl(newchannel, HV_GPADL_RING, buffer,
				      newchannel->ringbuffer_send_offset << PAGE_SHIFT);
	if (err)
		goto error_clean_ring;

	err = hv_ringbuffer_init(&newchannel->outbound,
				 buffer->addr, send_pages, 0,
				 newchannel->co_ring_buffer);
	if (err)
		goto error_free_gpadl;

	err = hv_ringbuffer_init(&newchannel->inbound,
				 buffer->addr + (send_pages << PAGE_SHIFT),
				 recv_pages, newchannel->max_pkt_size,
				 newchannel->co_ring_buffer);
	if (err)
		goto error_free_gpadl;

	/* Create and init the channel open message */
	open_info = kzalloc(sizeof(*open_info) +
			   sizeof(struct vmbus_channel_open_channel),
			   GFP_KERNEL);
	if (!open_info) {
		err = -ENOMEM;
		goto error_free_gpadl;
	}

	init_completion(&open_info->waitevent);
	open_info->waiting_channel = newchannel;

	open_msg = (struct vmbus_channel_open_channel *)open_info->msg;
	open_msg->header.msgtype = CHANNELMSG_OPENCHANNEL;
	open_msg->openid = newchannel->offermsg.child_relid;
	open_msg->child_relid = newchannel->offermsg.child_relid;
	open_msg->ringbuffer_gpadlhandle = buffer->gpadl_handle;
	/*
	 * The unit of ->downstream_ringbuffer_pageoffset is HV_HYP_PAGE and
	 * the unit of ->ringbuffer_send_offset (i.e. send_pages) is PAGE, so
	 * here we calculate it into HV_HYP_PAGE.
	 */
	open_msg->downstream_ringbuffer_pageoffset =
		hv_ring_gpadl_send_hvpgoffset(send_pages << PAGE_SHIFT);
	open_msg->target_vp = hv_cpu_number_to_vp_number(newchannel->target_cpu);

	if (userdatalen)
		memcpy(open_msg->userdata, userdata, userdatalen);

	spin_lock_irqsave(&vmbus_connection.channelmsg_lock, flags);
	list_add_tail(&open_info->msglistentry,
		      &vmbus_connection.chn_msg_list);
	spin_unlock_irqrestore(&vmbus_connection.channelmsg_lock, flags);

	if (newchannel->rescind) {
		err = -ENODEV;
		goto error_clean_msglist;
	}

	err = vmbus_post_msg(open_msg,
			     sizeof(struct vmbus_channel_open_channel), true);

	trace_vmbus_open(open_msg, err);

	if (err != 0)
		goto error_clean_msglist;

	wait_for_completion(&open_info->waitevent);

	spin_lock_irqsave(&vmbus_connection.channelmsg_lock, flags);
	list_del(&open_info->msglistentry);
	spin_unlock_irqrestore(&vmbus_connection.channelmsg_lock, flags);

	if (newchannel->rescind) {
		err = -ENODEV;
		goto error_free_info;
	}

	if (open_info->response.open_result.status) {
		err = -EAGAIN;
		goto error_free_info;
	}

	newchannel->state = CHANNEL_OPENED_STATE;
	kfree(open_info);
	return 0;

error_clean_msglist:
	spin_lock_irqsave(&vmbus_connection.channelmsg_lock, flags);
	list_del(&open_info->msglistentry);
	spin_unlock_irqrestore(&vmbus_connection.channelmsg_lock, flags);
error_free_info:
	kfree(open_info);
error_free_gpadl:
	/* A missing teardown acknowledgment leaves the owner retained. */
	vmbus_teardown_gpadl(newchannel, buffer);
error_clean_ring:
	hv_ringbuffer_cleanup(&newchannel->outbound);
	hv_ringbuffer_cleanup(&newchannel->inbound);
	vmbus_free_requestor(&newchannel->requestor);
	newchannel->state = CHANNEL_OPEN_STATE;
	return err;
}

/*
 * vmbus_connect_ring - Open the channel but reuse ring buffer
 */
int vmbus_connect_ring(struct vmbus_channel *newchannel,
		       void (*onchannelcallback)(void *context), void *context)
{
	return  __vmbus_open(newchannel, NULL, 0, onchannelcallback, context);
}
EXPORT_SYMBOL_GPL(vmbus_connect_ring);

/*
 * vmbus_open - Open the specified channel.
 */
int vmbus_open(struct vmbus_channel *newchannel,
	       u32 send_ringbuffer_size, u32 recv_ringbuffer_size,
	       void *userdata, u32 userdatalen,
	       void (*onchannelcallback)(void *context), void *context)
{
	int err;

	err = vmbus_alloc_ring(newchannel, send_ringbuffer_size,
			       recv_ringbuffer_size);
	if (err)
		return err;

	err = __vmbus_open(newchannel, userdata, userdatalen,
			   onchannelcallback, context);
	if (err)
		vmbus_free_ring(newchannel);

	return err;
}
EXPORT_SYMBOL_GPL(vmbus_open);

static struct vmbus_channel_msginfo *vmbus_alloc_teardown_info(void)
{
	return kzalloc(sizeof(struct vmbus_channel_msginfo) +
		       sizeof(struct vmbus_channel_gpadl_teardown), GFP_KERNEL);
}

/*
 * vmbus_teardown_gpadl - Teardown the specified GPADL handle
 *
 * A teardown acknowledgment clears the handle. A host rescind also revokes
 * the device's GPADLs under the upstream VMBus lifecycle contract; a local
 * suspend/unload mark does not. VMBus-owned memory is reclaimed only after
 * the driver's remove/close path has quiesced.
 */
static int __vmbus_teardown_gpadl(struct vmbus_channel *channel,
				  struct vmbus_buffer *buffer,
				  vmbus_gpadl_info_alloc_fn alloc_info)
{
	struct vmbus_channel_gpadl_teardown *msg;
	struct vmbus_channel_msginfo *info;
	unsigned long flags;
	enum vmbus_rescind_source rescind_source;
	enum vmbus_gpadl_teardown_event event;
	int ret;

	if (buffer->gpadl_state == VMBUS_GPADL_NONE &&
	    !buffer->gpadl_handle)
		return 0;

	if (buffer->gpadl_state == VMBUS_GPADL_PENDING ||
	    buffer->gpadl_state == VMBUS_GPADL_TEARING_DOWN)
		return -EINPROGRESS;

	rescind_source = vmbus_channel_rescind_source(channel);
	if (rescind_source == VMBUS_RESCIND_HOST)
		return vmbus_gpadl_teardown_result(channel, buffer,
					   VMBUS_GPADL_TEARDOWN_HOST_RESCIND,
					   -ENODEV);
	if (rescind_source == VMBUS_RESCIND_LOCAL)
		return vmbus_gpadl_teardown_result(channel, buffer,
					   VMBUS_GPADL_TEARDOWN_LOCAL_RESCIND,
					   -ENODEV);

	if (buffer->gpadl_state != VMBUS_GPADL_LIVE ||
	    !buffer->gpadl_handle)
		return -EINVAL;

	ret = vmbus_gpadl_teardown_begin(buffer);
	if (ret)
		return ret;

	info = alloc_info();
	if (!info) {
		vmbus_gpadl_teardown_cancel(buffer);
		return -ENOMEM;
	}

	init_completion(&info->waitevent);
	info->waiting_channel = channel;

	msg = (struct vmbus_channel_gpadl_teardown *)info->msg;

	msg->header.msgtype = CHANNELMSG_GPADL_TEARDOWN;
	msg->child_relid = channel->offermsg.child_relid;
	msg->gpadl = buffer->gpadl_handle;

	spin_lock_irqsave(&vmbus_connection.channelmsg_lock, flags);
	list_add_tail(&info->msglistentry,
		      &vmbus_connection.chn_msg_list);
	spin_unlock_irqrestore(&vmbus_connection.channelmsg_lock, flags);

	rescind_source = vmbus_channel_rescind_source(channel);
	if (rescind_source != VMBUS_RESCIND_NONE) {
		vmbus_gpadl_teardown_cancel(buffer);
		if (rescind_source == VMBUS_RESCIND_HOST)
			event = VMBUS_GPADL_TEARDOWN_HOST_RESCIND;
		else
			event = VMBUS_GPADL_TEARDOWN_LOCAL_RESCIND;
		ret = vmbus_gpadl_teardown_result(channel, buffer, event,
						  -ENODEV);
		goto cleanup_info;
	}

	ret = vmbus_post_msg(msg, sizeof(struct vmbus_channel_gpadl_teardown),
			     true);

	trace_vmbus_teardown_gpadl(msg, ret);

	if (ret)
		goto resolve_result;

	wait_for_completion(&info->waitevent);

	if (info->response.gpadl_torndown.header.msgtype ==
	    CHANNELMSG_GPADL_TORNDOWN) {
		event = VMBUS_GPADL_TEARDOWN_ACK;
		ret = 0;
	} else {
		rescind_source = vmbus_channel_rescind_source(channel);
		if (rescind_source == VMBUS_RESCIND_HOST)
			event = VMBUS_GPADL_TEARDOWN_HOST_RESCIND;
		else if (rescind_source == VMBUS_RESCIND_LOCAL)
			event = VMBUS_GPADL_TEARDOWN_LOCAL_RESCIND;
		else
			event = VMBUS_GPADL_TEARDOWN_FAILURE;
		ret = -ENODEV;
	}
	ret = vmbus_gpadl_teardown_result(channel, buffer, event, ret);

	goto cleanup_info;

resolve_result:
	rescind_source = vmbus_channel_rescind_source(channel);
	if (rescind_source == VMBUS_RESCIND_HOST)
		event = VMBUS_GPADL_TEARDOWN_HOST_RESCIND;
	else if (rescind_source == VMBUS_RESCIND_LOCAL)
		event = VMBUS_GPADL_TEARDOWN_LOCAL_RESCIND;
	else
		event = VMBUS_GPADL_TEARDOWN_FAILURE;
	ret = vmbus_gpadl_teardown_result(channel, buffer, event, ret);

cleanup_info:
	spin_lock_irqsave(&vmbus_connection.channelmsg_lock, flags);
	list_del(&info->msglistentry);
	spin_unlock_irqrestore(&vmbus_connection.channelmsg_lock, flags);

	kfree(info);

	return ret;
}

int vmbus_teardown_gpadl(struct vmbus_channel *channel,
			 struct vmbus_buffer *buffer)
{
	return __vmbus_teardown_gpadl(channel, buffer,
				      vmbus_alloc_teardown_info);
}
EXPORT_SYMBOL_GPL(vmbus_teardown_gpadl);

void vmbus_reset_channel_cb(struct vmbus_channel *channel)
{
	unsigned long flags;

	/*
	 * vmbus_on_event(), running in the per-channel tasklet, can race
	 * with vmbus_close_internal() in the case of SMP guest, e.g., when
	 * the former is accessing channel->inbound.ring_buffer, the latter
	 * could be freeing the ring_buffer pages, so here we must stop it
	 * first.
	 *
	 * vmbus_chan_sched() might call the netvsc driver callback function
	 * that ends up scheduling NAPI work that accesses the ring buffer.
	 * At this point, we have to ensure that any such work is completed
	 * and that the channel ring buffer is no longer being accessed, cf.
	 * the calls to napi_disable() in netvsc_device_remove().
	 */
	tasklet_disable(&channel->callback_event);

	/* See the inline comments in vmbus_chan_sched(). */
	spin_lock_irqsave(&channel->sched_lock, flags);
	channel->onchannel_callback = NULL;
	spin_unlock_irqrestore(&channel->sched_lock, flags);

	channel->sc_creation_callback = NULL;

	/* Re-enable tasklet for use on re-open */
	tasklet_enable(&channel->callback_event);
}

static int vmbus_close_internal(struct vmbus_channel *channel)
{
	struct vmbus_channel_close_channel *msg;
	int ret;

	vmbus_reset_channel_cb(channel);

	/*
	 * In case a device driver's probe() fails (e.g.,
	 * util_probe() -> vmbus_open() returns -ENOMEM) and the device is
	 * rescinded later (e.g., we dynamically disable an Integrated Service
	 * in Hyper-V Manager), the driver's remove() invokes vmbus_close():
	 * here we should skip most of the below cleanup work.
	 */
	if (channel->state != CHANNEL_OPENED_STATE)
		return -EINVAL;

	channel->state = CHANNEL_OPEN_STATE;

	/* Send a closing message */

	msg = &channel->close_msg;

	msg->header.msgtype = CHANNELMSG_CLOSECHANNEL;
	msg->child_relid = channel->offermsg.child_relid;

	ret = vmbus_post_msg(msg, sizeof(struct vmbus_channel_close_channel),
			     true);

	trace_vmbus_close_internal(msg, ret);

	if (ret) {
		pr_err("Close failed: close post msg return is %d\n", ret);
		/*
		 * If we failed to post the close msg,
		 * it is perhaps better to leak memory.
		 */
	}

	/* Tear down the gpadl for the channel's ring buffer */
	else if (channel->ringbuffer.gpadl_handle) {
		ret = vmbus_teardown_gpadl(channel, &channel->ringbuffer);
		if (ret) {
			pr_err("Close failed: teardown gpadl return %d\n", ret);
			/*
			 * If we failed to teardown gpadl,
			 * it is perhaps better to leak memory.
			 */
		}
	}

	if (!ret)
		vmbus_free_requestor(&channel->requestor);

	return ret;
}

/* disconnect ring - close all channels */
int vmbus_disconnect_ring(struct vmbus_channel *channel)
{
	struct vmbus_channel *cur_channel, *tmp;
	int ret;

	if (channel->primary_channel != NULL)
		return -EINVAL;

	list_for_each_entry_safe(cur_channel, tmp, &channel->sc_list, sc_list) {
		if (cur_channel->rescind)
			wait_for_completion(&cur_channel->rescind_event);

		mutex_lock(&vmbus_connection.channel_mutex);
		if (vmbus_close_internal(cur_channel) == 0) {
			vmbus_free_ring(cur_channel);

			if (cur_channel->rescind)
				hv_process_channel_removal(cur_channel);
		}
		mutex_unlock(&vmbus_connection.channel_mutex);
	}

	/*
	 * Now close the primary.
	 */
	mutex_lock(&vmbus_connection.channel_mutex);
	ret = vmbus_close_internal(channel);
	mutex_unlock(&vmbus_connection.channel_mutex);

	return ret;
}
EXPORT_SYMBOL_GPL(vmbus_disconnect_ring);

/*
 * vmbus_close - Close the specified channel
 */
void vmbus_close(struct vmbus_channel *channel)
{
	if (vmbus_disconnect_ring(channel) == 0)
		vmbus_free_ring(channel);
}
EXPORT_SYMBOL_GPL(vmbus_close);

/**
 * vmbus_sendpacket_getid() - Send the specified buffer on the given channel
 * @channel: Pointer to vmbus_channel structure
 * @buffer: Pointer to the buffer you want to send the data from.
 * @bufferlen: Maximum size of what the buffer holds.
 * @requestid: Identifier of the request
 * @trans_id: Identifier of the transaction associated to this request, if
 *            the send is successful; undefined, otherwise.
 * @type: Type of packet that is being sent e.g. negotiate, time
 *	  packet etc.
 * @flags: 0 or VMBUS_DATA_PACKET_FLAG_COMPLETION_REQUESTED
 *
 * Sends data in @buffer directly to Hyper-V via the vmbus.
 * This will send the data unparsed to Hyper-V.
 *
 * Mainly used by Hyper-V drivers.
 */
int vmbus_sendpacket_getid(struct vmbus_channel *channel, void *buffer,
			   u32 bufferlen, u64 requestid, u64 *trans_id,
			   enum vmbus_packet_type type, u32 flags)
{
	struct vmpacket_descriptor desc;
	u32 packetlen = sizeof(struct vmpacket_descriptor) + bufferlen;
	u32 packetlen_aligned = ALIGN(packetlen, sizeof(u64));
	struct kvec bufferlist[3];
	u64 aligned_data = 0;
	int num_vecs = ((bufferlen != 0) ? 3 : 1);


	/* Setup the descriptor */
	desc.type = type; /* VmbusPacketTypeDataInBand; */
	desc.flags = flags; /* VMBUS_DATA_PACKET_FLAG_COMPLETION_REQUESTED; */
	/* in 8-bytes granularity */
	desc.offset8 = sizeof(struct vmpacket_descriptor) >> 3;
	desc.len8 = (u16)(packetlen_aligned >> 3);
	desc.trans_id = VMBUS_RQST_ERROR; /* will be updated in hv_ringbuffer_write() */

	bufferlist[0].iov_base = &desc;
	bufferlist[0].iov_len = sizeof(struct vmpacket_descriptor);
	bufferlist[1].iov_base = buffer;
	bufferlist[1].iov_len = bufferlen;
	bufferlist[2].iov_base = &aligned_data;
	bufferlist[2].iov_len = (packetlen_aligned - packetlen);

	return hv_ringbuffer_write(channel, bufferlist, num_vecs, requestid, trans_id);
}
EXPORT_SYMBOL(vmbus_sendpacket_getid);

/**
 * vmbus_sendpacket() - Send the specified buffer on the given channel
 * @channel: Pointer to vmbus_channel structure
 * @buffer: Pointer to the buffer you want to send the data from.
 * @bufferlen: Maximum size of what the buffer holds.
 * @requestid: Identifier of the request
 * @type: Type of packet that is being sent e.g. negotiate, time
 *	  packet etc.
 * @flags: 0 or VMBUS_DATA_PACKET_FLAG_COMPLETION_REQUESTED
 *
 * Sends data in @buffer directly to Hyper-V via the vmbus.
 * This will send the data unparsed to Hyper-V.
 *
 * Mainly used by Hyper-V drivers.
 */
int vmbus_sendpacket(struct vmbus_channel *channel, void *buffer,
		     u32 bufferlen, u64 requestid,
		     enum vmbus_packet_type type, u32 flags)
{
	return vmbus_sendpacket_getid(channel, buffer, bufferlen,
				      requestid, NULL, type, flags);
}
EXPORT_SYMBOL(vmbus_sendpacket);

/*
 * vmbus_sendpacket_mpb_desc - Send one or more multi-page buffer packets
 * using a GPADL Direct packet type.
 * The desc argument must include space for the VMBus descriptor. The
 * rangecount field must already be set.
 */
int vmbus_sendpacket_mpb_desc(struct vmbus_channel *channel,
			      struct vmbus_packet_mpb_array *desc,
			      u32 desc_size,
			      void *buffer, u32 bufferlen, u64 requestid)
{
	u32 packetlen;
	u32 packetlen_aligned;
	struct kvec bufferlist[3];
	u64 aligned_data = 0;

	packetlen = desc_size + bufferlen;
	packetlen_aligned = ALIGN(packetlen, sizeof(u64));

	/* Setup the descriptor */
	desc->type = VM_PKT_DATA_USING_GPA_DIRECT;
	desc->flags = VMBUS_DATA_PACKET_FLAG_COMPLETION_REQUESTED;
	desc->dataoffset8 = desc_size >> 3; /* in 8-bytes granularity */
	desc->length8 = (u16)(packetlen_aligned >> 3);
	desc->transactionid = VMBUS_RQST_ERROR; /* will be updated in hv_ringbuffer_write() */
	desc->reserved = 0;

	bufferlist[0].iov_base = desc;
	bufferlist[0].iov_len = desc_size;
	bufferlist[1].iov_base = buffer;
	bufferlist[1].iov_len = bufferlen;
	bufferlist[2].iov_base = &aligned_data;
	bufferlist[2].iov_len = (packetlen_aligned - packetlen);

	return hv_ringbuffer_write(channel, bufferlist, 3, requestid, NULL);
}
EXPORT_SYMBOL_GPL(vmbus_sendpacket_mpb_desc);

/**
 * __vmbus_recvpacket() - Retrieve the user packet on the specified channel
 * @channel: Pointer to vmbus_channel structure
 * @buffer: Pointer to the buffer you want to receive the data into.
 * @bufferlen: Maximum size of what the buffer can hold.
 * @buffer_actual_len: The actual size of the data after it was received.
 * @requestid: Identifier of the request
 * @raw: true means keep the vmpacket_descriptor header in the received data.
 *
 * Receives directly from the hyper-v vmbus and puts the data it received
 * into Buffer. This will receive the data unparsed from hyper-v.
 *
 * Mainly used by Hyper-V drivers.
 */
static inline int
__vmbus_recvpacket(struct vmbus_channel *channel, void *buffer,
		   u32 bufferlen, u32 *buffer_actual_len, u64 *requestid,
		   bool raw)
{
	return hv_ringbuffer_read(channel, buffer, bufferlen,
				  buffer_actual_len, requestid, raw);

}

int vmbus_recvpacket(struct vmbus_channel *channel, void *buffer,
		     u32 bufferlen, u32 *buffer_actual_len,
		     u64 *requestid)
{
	return __vmbus_recvpacket(channel, buffer, bufferlen,
				  buffer_actual_len, requestid, false);
}
EXPORT_SYMBOL(vmbus_recvpacket);

/*
 * vmbus_recvpacket_raw - Retrieve the raw packet on the specified channel
 */
int vmbus_recvpacket_raw(struct vmbus_channel *channel, void *buffer,
			      u32 bufferlen, u32 *buffer_actual_len,
			      u64 *requestid)
{
	return __vmbus_recvpacket(channel, buffer, bufferlen,
				  buffer_actual_len, requestid, true);
}
EXPORT_SYMBOL_GPL(vmbus_recvpacket_raw);

/*
 * vmbus_next_request_id - Returns a new request id. It is also
 * the index at which the guest memory address is stored.
 * Uses a spin lock to avoid race conditions.
 * @channel: Pointer to the VMbus channel struct
 * @rqst_add: Guest memory address to be stored in the array
 */
u64 vmbus_next_request_id(struct vmbus_channel *channel, u64 rqst_addr)
{
	struct vmbus_requestor *rqstor = &channel->requestor;
	unsigned long flags;
	u64 current_id;

	/* Check rqstor has been initialized */
	if (!channel->rqstor_size)
		return VMBUS_NO_RQSTOR;

	lock_requestor(channel, flags);
	current_id = rqstor->next_request_id;

	/* Requestor array is full */
	if (current_id >= rqstor->size) {
		unlock_requestor(channel, flags);
		return VMBUS_RQST_ERROR;
	}

	rqstor->next_request_id = rqstor->req_arr[current_id];
	rqstor->req_arr[current_id] = rqst_addr;

	/* The already held spin lock provides atomicity */
	bitmap_set(rqstor->req_bitmap, current_id, 1);

	unlock_requestor(channel, flags);

	/*
	 * Cannot return an ID of 0, which is reserved for an unsolicited
	 * message from Hyper-V; Hyper-V does not acknowledge (respond to)
	 * VMBUS_DATA_PACKET_FLAG_COMPLETION_REQUESTED requests with ID of
	 * 0 sent by the guest.
	 */
	return current_id + 1;
}
EXPORT_SYMBOL_GPL(vmbus_next_request_id);

/* As in vmbus_request_addr_match() but without the requestor lock */
u64 __vmbus_request_addr_match(struct vmbus_channel *channel, u64 trans_id,
			       u64 rqst_addr)
{
	struct vmbus_requestor *rqstor = &channel->requestor;
	u64 req_addr;

	/* Check rqstor has been initialized */
	if (!channel->rqstor_size)
		return VMBUS_NO_RQSTOR;

	/* Hyper-V can send an unsolicited message with ID of 0 */
	if (!trans_id)
		return VMBUS_RQST_ERROR;

	/* Data corresponding to trans_id is stored at trans_id - 1 */
	trans_id--;

	/* Invalid trans_id */
	if (trans_id >= rqstor->size || !test_bit(trans_id, rqstor->req_bitmap))
		return VMBUS_RQST_ERROR;

	req_addr = rqstor->req_arr[trans_id];
	if (rqst_addr == VMBUS_RQST_ADDR_ANY || req_addr == rqst_addr) {
		rqstor->req_arr[trans_id] = rqstor->next_request_id;
		rqstor->next_request_id = trans_id;

		/* The already held spin lock provides atomicity */
		bitmap_clear(rqstor->req_bitmap, trans_id, 1);
	}

	return req_addr;
}
EXPORT_SYMBOL_GPL(__vmbus_request_addr_match);

/*
 * vmbus_request_addr_match - Clears/removes @trans_id from the @channel's
 * requestor, provided the memory address stored at @trans_id equals @rqst_addr
 * (or provided @rqst_addr matches the sentinel value VMBUS_RQST_ADDR_ANY).
 *
 * Returns the memory address stored at @trans_id, or VMBUS_RQST_ERROR if
 * @trans_id is not contained in the requestor.
 *
 * Acquires and releases the requestor spin lock.
 */
u64 vmbus_request_addr_match(struct vmbus_channel *channel, u64 trans_id,
			     u64 rqst_addr)
{
	unsigned long flags;
	u64 req_addr;

	lock_requestor(channel, flags);
	req_addr = __vmbus_request_addr_match(channel, trans_id, rqst_addr);
	unlock_requestor(channel, flags);

	return req_addr;
}
EXPORT_SYMBOL_GPL(vmbus_request_addr_match);

/*
 * vmbus_request_addr - Returns the memory address stored at @trans_id
 * in @rqstor. Uses a spin lock to avoid race conditions.
 * @channel: Pointer to the VMbus channel struct
 * @trans_id: Request id sent back from Hyper-V. Becomes the requestor's
 * next request id.
 */
u64 vmbus_request_addr(struct vmbus_channel *channel, u64 trans_id)
{
	return vmbus_request_addr_match(channel, trans_id, VMBUS_RQST_ADDR_ANY);
}
EXPORT_SYMBOL_GPL(vmbus_request_addr);
