// SPDX-License-Identifier: GPL-2.0
/* Hybrid RTT-Linger MPTCP Scheduler
 *
 * Combines the linger-time metric of the default scheduler with
 * RTT awareness from LRTT into a single composite score:
 *
 *   score_i = (wmem_i * RTT_i) / avg_pacing_rate_i
 *
 * Lower score = faster queue drain AND lower latency = better subflow.
 * An empty queue (wmem = 0) always scores 0 and is immediately preferred.
 * Backup subflows are only used when no active subflow is available.
 */

#define pr_fmt(fmt) "MPTCP-HYBRID: " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <net/mptcp.h>
#include <net/tcp.h>
#include "protocol.h"

#define MPTCP_SEND_BURST_SIZE   65428

#define SSK_MODE_ACTIVE  0
#define SSK_MODE_BACKUP  1
#define SSK_MODE_MAX     2

struct hybrid_send_info {
	struct sock *ssk;
	u64         score;
};

static int hybrid_get_send(struct mptcp_sock *msk)
{
	struct hybrid_send_info send_info[SSK_MODE_MAX];
	struct mptcp_subflow_context *subflow;
	struct sock *sk = (struct sock *)msk;
	u32 pace, rtt, burst, wmem;
	struct tcp_sock *tp;
	struct sock *ssk;
	int i, nr_active = 0;
	u64 score;

	/* Initialise candidate slots */
	for (i = 0; i < SSK_MODE_MAX; i++) {
		send_info[i].ssk   = NULL;
		send_info[i].score = U64_MAX;
	}

	mptcp_for_each_subflow(msk, subflow) {
		bool backup = subflow->backup || subflow->request_bkup;

		ssk = mptcp_subflow_tcp_sock(subflow);

		if (!__mptcp_subflow_active(subflow) ||
		    !sk_stream_memory_free(ssk))
			continue;

		nr_active += !backup;

		/* Initialise smoothed pacing rate on first use */
		pace = READ_ONCE(subflow->avg_pacing_rate);
		if (!pace) {
			WRITE_ONCE(subflow->avg_pacing_rate,
				   READ_ONCE(ssk->sk_pacing_rate));
			pace = READ_ONCE(subflow->avg_pacing_rate);
			if (!pace)
				continue;
		}

		tp  = tcp_sk(ssk);
		rtt = tp->srtt_us >> 3;   /* fixed-point to microseconds */
		if (!rtt)
			rtt = 1;              /* guard: avoid score=0 on zero-RTT */

		wmem = READ_ONCE(ssk->sk_wmem_queued);

		/*
		 * Composite score: score_i = (wmem_i * RTT_i) / pace_i
		 *
		 * - Empty queue (wmem=0) scores 0: always preferred
		 * - As queue grows, score rises: load naturally shifts away
		 * - Low-RTT paths score lower than high-RTT at equal load
		 */
		if (wmem == 0)
			score = 0;
		else
			score = div_u64((__u64)wmem * rtt, pace);

		pr_info("Subflow: src=%pI4 dst=%pI4 rtt=%u us wmem=%u pace=%u score=%llu backup=%d\n",
			&inet_sk(ssk)->inet_saddr, &inet_sk(ssk)->inet_daddr,
			rtt, wmem, pace, score, backup);

		if (score < send_info[backup].score) {
			send_info[backup].ssk   = ssk;
			send_info[backup].score = score;
		}
	}

	/* Promote backup only when no active subflow is available */
	if (!nr_active)
		send_info[SSK_MODE_ACTIVE].ssk = send_info[SSK_MODE_BACKUP].ssk;

	ssk = send_info[SSK_MODE_ACTIVE].ssk;
	if (!ssk || !sk_stream_memory_free(ssk)) {
		/* Fallback: let the kernel default helper decide */
		ssk = mptcp_subflow_get_send(msk);
		if (!ssk) {
			pr_info("No usable subflow found\n");
			return -EINVAL;
		}
		pr_info("Fallback to default helper\n");
		mptcp_subflow_set_scheduled(mptcp_subflow_ctx(ssk), true);
		return 0;
	}

	subflow = mptcp_subflow_ctx(ssk);

	/* Update smoothed pacing rate and burst size (mirrors default scheduler) */
	burst = min_t(int, MPTCP_SEND_BURST_SIZE, msk->snd_burst ?: MPTCP_SEND_BURST_SIZE);
	wmem  = READ_ONCE(ssk->sk_wmem_queued);

	if (burst && wmem) {
		WRITE_ONCE(subflow->avg_pacing_rate,
			div_u64((__u64)READ_ONCE(subflow->avg_pacing_rate) * wmem +
				(__u64)READ_ONCE(ssk->sk_pacing_rate) * burst,
				burst + wmem));
		msk->snd_burst = burst;
	}

	pr_info("Selected: src=%pI4 dst=%pI4 score=%llu\n",
		&inet_sk(ssk)->inet_saddr, &inet_sk(ssk)->inet_daddr,
		send_info[SSK_MODE_ACTIVE].score);

	mptcp_subflow_set_scheduled(subflow, true);
	return 0;
}

static int hybrid_get_retrans(struct mptcp_sock *msk)
{
	struct sock *ssk = mptcp_subflow_get_retrans(msk);

	if (!ssk)
		return -EINVAL;

	mptcp_subflow_set_scheduled(mptcp_subflow_ctx(ssk), true);
	return 0;
}

static struct mptcp_sched_ops hybrid_sched = {
	.get_send    = hybrid_get_send,
	.get_retrans = hybrid_get_retrans,
	.name        = "hybrid",
	.owner       = THIS_MODULE,
};

static int __init hybrid_register(void)
{
	int ret = mptcp_register_scheduler(&hybrid_sched);

	if (ret) {
		pr_err("Failed to register scheduler: %d\n", ret);
		return ret;
	}
	pr_info("registered\n");
	return 0;
}

static void __exit hybrid_unregister(void)
{
	mptcp_unregister_scheduler(&hybrid_sched);
	pr_info("unregistered\n");
}

module_init(hybrid_register);
module_exit(hybrid_unregister);
MODULE_AUTHOR("Vignesh");
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Hybrid RTT-Linger MPTCP Scheduler");
