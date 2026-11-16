// SPDX-License-Identifier: GPL-2.0
/* Earliest-Delivery-First (EDF) MPTCP Scheduler  — revision 2
 *
 * PRINCIPLE (unchanged)
 * ---------------------
 * For every eligible subflow, estimate when the NEXT segment placed on it
 * would be delivered, and schedule the subflow with the earliest delivery:
 *
 *   space    = snd_cwnd - packets_out            (window head-room, segments)
 *   if space > 0:  can send now  -> deliver in ~ srtt/2
 *   if space == 0: wait ~1 RTT   -> deliver in ~ srtt + srtt/2
 *
 * WHAT REVISION 2 FIXES  (setup B: 127 Mb/s, should be ~187)
 * ----------------------------------------------------------
 * Measured r1 results: A=187, B=127, C=849, D=924.  Only B regressed, and
 * the cause is structural rather than a tuning error:
 *
 *   In B both paths are 100 bw / 10 ms, but one takes periodic 100 ms spikes.
 *   After a spike, that path's srtt decays slowly back toward 10 ms.  While it
 *   is elevated (say 50 ms) r1 compared:
 *       stable path, window FULL   -> 10 * 1.5 = 15 ms
 *       spike path,  window EMPTY  -> 50 / 2   = 25 ms
 *   15 < 25, so r1 kept picking the *full* stable path and never spilled onto
 *   the idle one.  Throughput pinned near a single path (~100-148).  Latency
 *   stayed correct (11.9 ms) because avoiding the spike path IS right during a
 *   spike -- r1 just never came back afterwards.
 *
 * Revision 2 separates the two questions r1 conflated:
 *
 *   1. IS THIS PATH SAFE TO USE?  (head-of-line guard)
 *        skip a path whose srtt exceeds EDF_HOL_FACTOR x the fastest path's
 *        *min_rtt*.  min_rtt is the path's intrinsic floor, so this reference
 *        cannot be inflated by our own queueing (using the fastest *srtt*
 *        would drift upward under load and let the slow path back in).
 *        D: slow path 50 ms vs 3 x 5 ms  = excluded  -> fast path only (924 kept)
 *        B: during a spike 100 ms vs 3 x 10 ms = excluded -> latency kept
 *           between spikes    10 ms vs 3 x 10 ms = allowed  -> aggregation
 *        A: 20 ms vs 3 x ~10-20 ms = allowed -> both paths -> aggregation kept
 *
 *   2. AMONG SAFE PATHS, WHICH DELIVERS SOONEST?
 *        a path that can send NOW always beats one whose window is full.
 *        This is what makes the paths alternate as each fills, which is what
 *        produces aggregation.  Ties break toward more window head-room (the
 *        higher-rate path), which is what keeps C on the fat path.
 *
 * The fastest path always survives the guard (its own srtt is compared against
 * its own min_rtt scaled by 3), so a subflow is always selectable.
 *
 * Out-of-tree module constraints: unchanged from r1.  Only srtt_us, snd_cwnd,
 * packets_out and tcp_min_rtt() are read -- all already used by novelcwl2 on
 * this kernel, so no new accessors are needed.
 */

#define pr_fmt(fmt) "MPTCP-EDF: " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <net/mptcp.h>
#include <net/tcp.h>
#include "protocol.h"

#define MPTCP_SEND_BURST_SIZE	65428

#define EDF_DEFAULT_SRTT_US	10000u	/* assume 10ms for an unprobed path   */
#define EDF_HOL_FACTOR		3u	/* spill onto a path only if its srtt
					 * is within 3x the fastest path's
					 * min_rtt; tune 2-4 if B/D shift    */

#define SSK_MODE_ACTIVE	0
#define SSK_MODE_BACKUP	1
#define SSK_MODE_MAX	2

struct edf_send_info {
	struct sock *ssk;
	u64         delivery;	/* estimated usec until next segment delivered */
	u32         space;	/* congestion-window head-room, segments        */
	bool        sendable;	/* window has room right now                    */
};

/* srtt in usec for a subflow, with a sane default before the first sample */
static u32 edf_srtt(const struct tcp_sock *tp)
{
	u32 srtt = READ_ONCE(tp->srtt_us) >> 3;

	return srtt ? srtt : EDF_DEFAULT_SRTT_US;
}

static int edf_get_send(struct mptcp_sock *msk)
{
	struct edf_send_info send_info[SSK_MODE_MAX];
	struct mptcp_subflow_context *subflow;
	u32 burst, wmem, cwnd, pout, space, srtt, mrtt;
	u32 ref_min_rtt = U32_MAX;
	u64 hol_limit, delivery;
	struct tcp_sock *tp;
	struct sock *ssk;
	int i, nr_active = 0;
	bool better, sendable;

	for (i = 0; i < SSK_MODE_MAX; i++) {
		send_info[i].ssk      = NULL;
		send_info[i].delivery = U64_MAX;
		send_info[i].space    = 0;
		send_info[i].sendable = false;
	}

	/*
	 * Pass 1 -- reference floor: the smallest min_rtt among eligible
	 * subflows.  Using min_rtt (not srtt) keeps this reference immune to
	 * queue build-up on the path we are already loading.
	 */
	mptcp_for_each_subflow(msk, subflow) {
		ssk = mptcp_subflow_tcp_sock(subflow);

		if (!__mptcp_subflow_active(subflow) ||
		    !sk_stream_memory_free(ssk))
			continue;

		tp   = tcp_sk(ssk);
		mrtt = tcp_min_rtt(tp);
		if (!mrtt || mrtt == ~0U)
			mrtt = edf_srtt(tp);
		if (mrtt < ref_min_rtt)
			ref_min_rtt = mrtt;
	}
	if (ref_min_rtt == U32_MAX)
		ref_min_rtt = EDF_DEFAULT_SRTT_US;

	hol_limit = (u64)ref_min_rtt * EDF_HOL_FACTOR;

	/* Pass 2 -- select the safe subflow with the earliest delivery */
	mptcp_for_each_subflow(msk, subflow) {
		bool backup = subflow->backup || subflow->request_bkup;

		ssk = mptcp_subflow_tcp_sock(subflow);

		if (!__mptcp_subflow_active(subflow) ||
		    !sk_stream_memory_free(ssk))
			continue;

		nr_active += !backup;

		tp   = tcp_sk(ssk);
		srtt = edf_srtt(tp);

		/*
		 * Head-of-line guard: a path so much slower than the fastest
		 * path's floor would stall meta-level reassembly.  The fastest
		 * path itself always passes (srtt ~ its own min_rtt << limit).
		 */
		if ((u64)srtt > hol_limit) {
			pr_info("Skip (HoL): src=%pI4 dst=%pI4 srtt=%u limit=%llu\n",
				&inet_sk(ssk)->inet_saddr,
				&inet_sk(ssk)->inet_daddr, srtt, hol_limit);
			continue;
		}

		cwnd = READ_ONCE(tp->snd_cwnd);
		if (!cwnd)
			cwnd = 1;
		pout  = READ_ONCE(tp->packets_out);
		space = (cwnd > pout) ? (cwnd - pout) : 0;

		sendable = space > 0;
		delivery = sendable ? (srtt / 2) : ((u64)srtt + srtt / 2);

		/*
		 * Ordering: (1) a path that can send now beats one that cannot
		 * -- this is what makes paths alternate as each window fills,
		 * i.e. what produces aggregation; (2) earliest delivery;
		 * (3) more window head-room (favours the higher-rate path).
		 */
		if (!send_info[backup].ssk)
			better = true;
		else if (sendable != send_info[backup].sendable)
			better = sendable;
		else if (delivery != send_info[backup].delivery)
			better = delivery < send_info[backup].delivery;
		else
			better = space > send_info[backup].space;

		if (better) {
			send_info[backup].ssk      = ssk;
			send_info[backup].delivery = delivery;
			send_info[backup].space    = space;
			send_info[backup].sendable = sendable;
		}
	}

	if (!nr_active)
		send_info[SSK_MODE_ACTIVE].ssk = send_info[SSK_MODE_BACKUP].ssk;

	ssk = send_info[SSK_MODE_ACTIVE].ssk;
	if (!ssk || !sk_stream_memory_free(ssk)) {
		ssk = mptcp_subflow_get_send(msk);
		if (!ssk)
			return -EINVAL;
		mptcp_subflow_set_scheduled(mptcp_subflow_ctx(ssk), true);
		return 0;
	}

	subflow = mptcp_subflow_ctx(ssk);

	/* Burst and EWMA update -- mirrors hybridsched.c / novelcwl2 exactly. */
	burst = min_t(int, MPTCP_SEND_BURST_SIZE,
		      msk->snd_burst ?: MPTCP_SEND_BURST_SIZE);
	wmem  = READ_ONCE(ssk->sk_wmem_queued);

	if (burst && wmem) {
		WRITE_ONCE(subflow->avg_pacing_rate,
			div_u64((u64)READ_ONCE(subflow->avg_pacing_rate) * wmem +
				(u64)READ_ONCE(ssk->sk_pacing_rate) * burst,
				burst + wmem));
		msk->snd_burst = burst;
	}

	mptcp_subflow_set_scheduled(subflow, true);
	return 0;
}

static int edf_get_retrans(struct mptcp_sock *msk)
{
	struct sock *ssk = mptcp_subflow_get_retrans(msk);

	if (!ssk)
		return -EINVAL;

	mptcp_subflow_set_scheduled(mptcp_subflow_ctx(ssk), true);
	return 0;
}

static struct mptcp_sched_ops edf_sched = {
	.get_send    = edf_get_send,
	.get_retrans = edf_get_retrans,
	.name        = "edf",
	.owner       = THIS_MODULE,
};

static int __init edf_register(void)
{
	int ret = mptcp_register_scheduler(&edf_sched);

	if (ret) {
		pr_err("Failed to register: %d\n", ret);
		return ret;
	}
	pr_info("registered\n");
	return 0;
}

static void __exit edf_unregister(void)
{
	mptcp_unregister_scheduler(&edf_sched);
	pr_info("unregistered\n");
}

module_init(edf_register);
module_exit(edf_unregister);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Earliest-Delivery-First MPTCP Scheduler");
