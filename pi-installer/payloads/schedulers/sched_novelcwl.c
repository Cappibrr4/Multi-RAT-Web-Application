// SPDX-License-Identifier: GPL-2.0
/* Congestion-Weighted Linger (CWL) MPTCP Scheduler
 *
 * Scoring formula (applied per eligible subflow):
 *
 *   fill    = packets_out / cwnd                    (fractional window use)
 *   weight  = SCALE + fill * ALPHA                  ∈ [SCALE, SCALE+ALPHA]
 *   score   = (wmem << 32) / pace  *  weight/SCALE
 *
 * The base term (wmem<<32)/pace is identical to the default scheduler's
 * linger_time metric.  The weight multiplier adds a congestion-pressure
 * penalty that steers new data toward less-loaded paths without the RTT²
 * squaring problem in hybridsched.c (RTT is still implicit in pace).
 *
 * When packets_out == 0: weight/SCALE == 1 → score == default score.
 * CWL therefore cannot regress below the default in the idle-window case.
 *
 * Out-of-tree module constraints (verified against kernel source):
 *  - mptcp_timeout_from_subflow() and __mptcp_set_timeout() are static
 *    in protocol.c — not callable from modules; omitted.
 *  - mptcp_subflow_active() (non-underscore) is not EXPORT_SYMBOL'd;
 *    we use __mptcp_subflow_active() (inline in protocol.h) instead.
 *    This means stale-subflow recovery won't run on our path, matching
 *    what hybridsched.c and every other out-of-tree scheduler does.
 *  - mptcp_wnd_end() is static in protocol.c; burst is computed as
 *    min(MPTCP_SEND_BURST_SIZE, msk->snd_burst ?: MPTCP_SEND_BURST_SIZE)
 *    matching the hybridsched.c pattern.
 */

#define pr_fmt(fmt) "MPTCP-CWL: " fmt

#include <linux/module.h>
#include <linux/kernel.h>
#include <net/mptcp.h>
#include <net/tcp.h>
#include "protocol.h"

#define MPTCP_SEND_BURST_SIZE	65428

#define CWL_SCALE	16u   /* base weight at zero window fill          */
#define CWL_ALPHA	16u   /* max additional penalty at full window    */
                              /* weight range: [16, 32]; full load → 2×  */

#define SSK_MODE_ACTIVE	0
#define SSK_MODE_BACKUP	1
#define SSK_MODE_MAX	2

struct cwl_send_info {
	struct sock *ssk;
	u64         score;
};

static int cwl_get_send(struct mptcp_sock *msk)
{
	struct cwl_send_info send_info[SSK_MODE_MAX];
	struct mptcp_subflow_context *subflow;
	u32 pace, burst, wmem;
	struct tcp_sock *tp;
	struct sock *ssk;
	int i, nr_active = 0;
	u64 score;

	for (i = 0; i < SSK_MODE_MAX; i++) {
		send_info[i].ssk   = NULL;
		send_info[i].score = U64_MAX;
	}

	mptcp_for_each_subflow(msk, subflow) {
		bool backup = subflow->backup || subflow->request_bkup;
		u32 fill_penalty, weight;

		ssk = mptcp_subflow_tcp_sock(subflow);

		if (!__mptcp_subflow_active(subflow) ||
		    !sk_stream_memory_free(ssk))
			continue;

		nr_active += !backup;

		/* Bootstrap avg_pacing_rate on first use */
		pace = READ_ONCE(subflow->avg_pacing_rate);
		if (unlikely(!pace)) {
			WRITE_ONCE(subflow->avg_pacing_rate,
				   READ_ONCE(ssk->sk_pacing_rate));
			pace = READ_ONCE(subflow->avg_pacing_rate);
			if (!pace)
				continue;
		}

		tp   = tcp_sk(ssk);
		wmem = READ_ONCE(ssk->sk_wmem_queued);

		/* Congestion penalty: fraction of cwnd in use, scaled by ALPHA */
		fill_penalty = min_t(u32,
			((__u64)tp->packets_out * CWL_ALPHA) / max(tp->snd_cwnd, 1u),
			CWL_ALPHA);
		weight = CWL_SCALE + fill_penalty;

		/* Base linger time identical to default, then apply weight */
		score = div_u64((u64)wmem << 32, pace);
		score = div_u64(score * weight, CWL_SCALE);

		pr_info("Subflow: src=%pI4 dst=%pI4 pkt_out=%u cwnd=%u wmem=%u pace=%u weight=%u score=%llu backup=%d\n",
			&inet_sk(ssk)->inet_saddr, &inet_sk(ssk)->inet_daddr,
			tp->packets_out, tp->snd_cwnd,
			wmem, pace, weight, score, backup);

		if (score < send_info[backup].score) {
			send_info[backup].ssk   = ssk;
			send_info[backup].score = score;
		}
	}

	if (!nr_active)
		send_info[SSK_MODE_ACTIVE].ssk = send_info[SSK_MODE_BACKUP].ssk;

	ssk = send_info[SSK_MODE_ACTIVE].ssk;
	if (!ssk || !sk_stream_memory_free(ssk)) {
		ssk = mptcp_subflow_get_send(msk);
		if (!ssk) {
			pr_info("No usable subflow found\n");
			return -EINVAL;
		}
		pr_info("Fallback to kernel default helper\n");
		mptcp_subflow_set_scheduled(mptcp_subflow_ctx(ssk), true);
		return 0;
	}

	subflow = mptcp_subflow_ctx(ssk);

	/*
	 * Burst and EWMA update — mirrors hybridsched.c exactly.
	 * We cannot call mptcp_wnd_end() (static in protocol.c) so we
	 * use msk->snd_burst as the cap, same as hybrid.
	 */
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

	pr_info("Selected: src=%pI4 dst=%pI4 score=%llu\n",
		&inet_sk(ssk)->inet_saddr, &inet_sk(ssk)->inet_daddr,
		send_info[SSK_MODE_ACTIVE].score);

	mptcp_subflow_set_scheduled(subflow, true);
	return 0;
}

static int cwl_get_retrans(struct mptcp_sock *msk)
{
	struct sock *ssk = mptcp_subflow_get_retrans(msk);

	if (!ssk)
		return -EINVAL;

	mptcp_subflow_set_scheduled(mptcp_subflow_ctx(ssk), true);
	return 0;
}

static struct mptcp_sched_ops cwl_sched = {
	.get_send    = cwl_get_send,
	.get_retrans = cwl_get_retrans,
	.name        = "cwl",
	.owner       = THIS_MODULE,
};

static int __init cwl_register(void)
{
	int ret = mptcp_register_scheduler(&cwl_sched);

	if (ret) {
		pr_err("Failed to register: %d\n", ret);
		return ret;
	}
	pr_info("registered\n");
	return 0;
}

static void __exit cwl_unregister(void)
{
	mptcp_unregister_scheduler(&cwl_sched);
	pr_info("unregistered\n");
}

module_init(cwl_register);
module_exit(cwl_unregister);
MODULE_AUTHOR("Jun an");
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Congestion-Weighted Linger MPTCP Scheduler");
