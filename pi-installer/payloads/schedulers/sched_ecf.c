// SPDX-License-Identifier: GPL-2.0
#include <linux/module.h>
#include <linux/kernel.h>
#include <net/mptcp.h>
#include "protocol.h"

/*
 * Earliest Completion First (ECF) MPTCP Scheduler
 *
 * For each subflow, estimates the time to deliver the next segment as:
 *
 *   completion_time = ((in_flight + segment) / cwnd) * srtt
 *
 * The subflow with the lowest completion_time is scheduled.
 * A subflow is skipped (held back) if waiting for the best subflow
 * is estimated to finish sooner than sending on it right now.
 */

/* Returns estimated completion time in arbitrary units (srtt-scaled).
 * Lower is better.
 * Returns U32_MAX if the subflow cannot send.
 */
static u32 ecf_estimate_completion(struct mptcp_subflow_context *subflow)
{
	struct tcp_sock *tp = tcp_sk(subflow->tcp_sock);
	u32 in_flight, cwnd, srtt, segment;

	if (!mptcp_subflow_active(subflow))
		return U32_MAX;

	if (!__tcp_can_send(subflow->tcp_sock) ||
	    !sk_stream_memory_free(subflow->tcp_sock))
		return U32_MAX;

	cwnd    = tp->snd_cwnd;
	srtt    = tp->srtt_us >> 3;   /* srtt_us is stored << 3 in tcp_sock */
	segment = tp->mss_cache;
	in_flight = tp->packets_out;

	/* Avoid division by zero */
	if (cwnd == 0 || srtt == 0 || segment == 0)
		return U32_MAX;

	/* If congestion window is already full, this subflow cannot take more */
	if (in_flight >= cwnd)
		return U32_MAX;

	/*
	 * Simplified ECF formula:
	 *   completion = ((in_flight + 1) * srtt) / (cwnd - in_flight)
	 *
	 * Numerator   = how many RTTs worth of data is ahead of us
	 * Denominator = remaining window slots available
	 */
	return ((in_flight + 1) * srtt) / (cwnd - in_flight);
}

static int ecf_get_send(struct mptcp_sock *msk)
{
	struct mptcp_subflow_context *subflow;
	struct mptcp_subflow_context *best = NULL;
	u32 best_time = U32_MAX;
	u32 est;

	msk_owned_by_me(msk);

	/* Pass 1: find the subflow with the earliest estimated completion */
	mptcp_for_each_subflow(msk, subflow) {
		est = ecf_estimate_completion(subflow);

		pr_debug("ECF: subflow ifindex=%d est=%u\n",
			 subflow->tcp_sock->sk_bound_dev_if, est);

		if (est < best_time) {
			best_time = est;
			best      = subflow;
		}
	}

	if (!best) {
		pr_debug("ECF: no eligible subflow found\n");
		return -EINVAL;
	}

	/*
	 * Pass 2: schedule only subflows whose estimated completion time
	 * is close enough to the best. Subflows that are significantly
	 * slower are held back (not scheduled) — ECF's key behaviour.
	 *
	 * Threshold: allow subflows within 2x of the best estimate.
	 * Subflows beyond this threshold would deliver later even if
	 * they send immediately, so we suppress them.
	 */
	mptcp_for_each_subflow(msk, subflow) {
		est = ecf_estimate_completion(subflow);

		if (est == U32_MAX)
			continue;

		if (est <= best_time * 2) {
			mptcp_subflow_set_scheduled(subflow, true);
			pr_info("ECF: scheduling subflow ifindex=%d est=%u best=%u\n",
				subflow->tcp_sock->sk_bound_dev_if,
				est, best_time);
		} else {
			pr_debug("ECF: holding back subflow ifindex=%d est=%u best=%u\n",
				 subflow->tcp_sock->sk_bound_dev_if,
				 est, best_time);
		}
	}

	return 0;
}

static int ecf_get_retrans(struct mptcp_sock *msk)
{
	/*
	 * For retransmissions, reuse the same ECF logic.
	 * The earliest-completing path is still the best choice
	 * to recover a lost segment quickly.
	 */
	return ecf_get_send(msk);
}

static void ecf_init(struct mptcp_sock *msk)
{
	pr_info("ECF: Scheduler initialized\n");
}

static void ecf_release(struct mptcp_sock *msk)
{
	pr_info("ECF: Scheduler released\n");
}

static struct mptcp_sched_ops mptcp_ecf_sched = {
	.get_send    = ecf_get_send,
	.get_retrans = ecf_get_retrans,
	.init        = ecf_init,
	.release     = ecf_release,
	.name        = "ecf",
	.owner       = THIS_MODULE,
};

static int __init ecf_register(void)
{
	return mptcp_register_scheduler(&mptcp_ecf_sched);
}

static void __exit ecf_unregister(void)
{
	mptcp_unregister_scheduler(&mptcp_ecf_sched);
}

module_init(ecf_register);
module_exit(ecf_unregister);

MODULE_AUTHOR("Your Name");
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("ECF MPTCP Scheduler - Earliest Completion First");
