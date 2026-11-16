// SPDX-License-Identifier: GPL-2.0
/*
 * MPTCP BLEST Scheduler
 *
 * BLocking ESTimation-based scheduler.
 *
 * Based on the paper:
 *   "BLEST: Blocking Estimation-based MPTCP Scheduler for Heterogeneous Networks"
 *   S. Ferlin, O. Alay, O. Mehani, R. Boreli — IFIP Networking 2016
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <net/mptcp.h>
#include "protocol.h"  /* required: same as redundant and ECF schedulers */

/* -------------------------------------------------------------------------
 * Module parameters
 * ---------------------------------------------------------------------- */
static int lambda_step __read_mostly = 5;
module_param(lambda_step, int, 0644);
MODULE_PARM_DESC(lambda_step,
	"Lambda adaptation step size x1000 (default 5 = 0.005)");

/* -------------------------------------------------------------------------
 * Per-connection private state
 *
 * FIX 1: The original used msk->sched_data which does NOT exist in the
 * upstream kernel's mptcp_sock struct. We use a simple global fallback
 * here since out-of-tree schedulers cannot rely on sched_data without
 * kernel patches. Lambda is kept as a module-level default instead.
 * ---------------------------------------------------------------------- */
static u32 g_lambda = 1000; /* global lambda, fixed-point *1000 = 1.0 */

/* -------------------------------------------------------------------------
 * FIX 2: The original used mptcp_sched_ops.get_subflow with mptcp_sched_data.
 * That API does NOT exist in the standard upstream kernel scheduler interface.
 * The correct API (matching redundant/ECF) uses:
 *   .get_send    = func(struct mptcp_sock *)
 *   .get_retrans = func(struct mptcp_sock *)
 * with mptcp_for_each_subflow() to iterate subflows.
 * ---------------------------------------------------------------------- */

/* -------------------------------------------------------------------------
 * Helper: find the subflow with the lowest SRTT (the "fast" path)
 * ---------------------------------------------------------------------- */
static struct mptcp_subflow_context *
blest_get_fast_subflow(struct mptcp_sock *msk)
{
	struct mptcp_subflow_context *subflow, *best = NULL;
	u32 min_srtt = U32_MAX;

	mptcp_for_each_subflow(msk, subflow) {
		struct tcp_sock *tp;

		if (!mptcp_subflow_active(subflow))
			continue;

		if (!__tcp_can_send(subflow->tcp_sock) ||
		    !sk_stream_memory_free(subflow->tcp_sock))
			continue;

		tp = tcp_sk(subflow->tcp_sock);
		if (tp->srtt_us < min_srtt) {
			min_srtt = tp->srtt_us;
			best = subflow;
		}
	}

	return best;
}

/* -------------------------------------------------------------------------
 * Core BLEST logic: predict whether sending on sf_slow will cause HoL.
 *
 *   X = (cwnd_fast * (rtt_slow - rtt_fast)) / rtt_fast * (lambda / 1000)
 *
 * Returns true if HoL blocking is predicted (skip this subflow).
 * ---------------------------------------------------------------------- */
static bool blest_predicts_hol_blocking(struct mptcp_subflow_context *sf_slow,
					struct mptcp_subflow_context *sf_fast,
					u32 lambda)
{
	struct tcp_sock *tp_slow, *tp_fast;
	u32 rtt_fast, rtt_slow, cwnd_fast, in_flight_slow;
	u64 x;

	if (!sf_fast || sf_fast == sf_slow)
		return false;

	tp_slow = tcp_sk(sf_slow->tcp_sock);
	tp_fast = tcp_sk(sf_fast->tcp_sock);

	/* FIX 3: srtt_us is stored <<3 in tcp_sock, shift right to get real us */
	rtt_fast = tp_fast->srtt_us >> 3;
	rtt_slow = tp_slow->srtt_us >> 3;

	/* If this subflow is equal or faster, no blocking concern */
	if (rtt_slow <= rtt_fast)
		return false;

	cwnd_fast      = tp_fast->snd_cwnd;
	in_flight_slow = tcp_packets_in_flight(tp_slow);

	if (rtt_fast == 0 || cwnd_fast == 0)
		return false;

	/* X = cwnd_fast * (rtt_slow - rtt_fast) / rtt_fast */
	x = (u64)cwnd_fast * (rtt_slow - rtt_fast);
	do_div(x, rtt_fast);

	/* Apply lambda correction */
	x = x * lambda;
	do_div(x, 1000);

	return in_flight_slow >= (u32)x;
}

/* -------------------------------------------------------------------------
 * Update lambda: adapt based on retransmission signal
 * ---------------------------------------------------------------------- */
static void blest_update_lambda(struct mptcp_subflow_context *sf_fast)
{
	struct tcp_sock *tp;
	bool hol_detected;

	if (!sf_fast)
		return;

	tp = tcp_sk(sf_fast->tcp_sock);
	hol_detected = (tp->retrans_stamp != 0);

	if (hol_detected)
		g_lambda = min_t(u32, g_lambda + lambda_step, 3000);
	else if (g_lambda > (u32)lambda_step)
		g_lambda -= lambda_step;
	else
		g_lambda = 1;
}

/* -------------------------------------------------------------------------
 * FIX 4: Main scheduling function now matches the correct API signature:
 *   int func(struct mptcp_sock *msk)
 * instead of the non-existent get_subflow(msk, sched_data) signature.
 * ---------------------------------------------------------------------- */
static int blest_get_send(struct mptcp_sock *msk)
{
	struct mptcp_subflow_context *subflow;
	struct mptcp_subflow_context *sf_fast, *best = NULL;
	u32 min_srtt = U32_MAX;
	bool scheduled = false;

	msk_owned_by_me(msk);

	/* Step 1: find the fastest subflow */
	sf_fast = blest_get_fast_subflow(msk);

	/* Step 2: update lambda */
	blest_update_lambda(sf_fast);

	/* Step 3: iterate subflows, skip HoL-predicted ones */
	mptcp_for_each_subflow(msk, subflow) {
		struct tcp_sock *tp;

		if (!mptcp_subflow_active(subflow))
			continue;

		if (!__tcp_can_send(subflow->tcp_sock) ||
		    !sk_stream_memory_free(subflow->tcp_sock))
			continue;

		tp = tcp_sk(subflow->tcp_sock);

		/* FIX 5: use snd_wnd check instead of bare !tp->snd_wnd
		 * to avoid skipping subflows incorrectly on window updates */
		if (tp->snd_wnd == 0) {
			pr_debug("BLEST: skipping subflow, zero send window\n");
			continue;
		}

		if (subflow != sf_fast &&
		    blest_predicts_hol_blocking(subflow, sf_fast, g_lambda)) {
			pr_debug("BLEST: holding back subflow ifindex=%d (HoL predicted)\n",
				 subflow->tcp_sock->sk_bound_dev_if);
			continue;
		}

		if (tp->srtt_us < min_srtt) {
			min_srtt = tp->srtt_us;
			best = subflow;
		}
	}

	/* Fallback: if everything was suppressed, use the fast subflow */
	if (!best)
		best = sf_fast;

	if (!best)
		return -EINVAL;

	mptcp_subflow_set_scheduled(best, true);
	scheduled = true;

	pr_info("BLEST: scheduled subflow ifindex=%d srtt=%u lambda=%u\n",
		best->tcp_sock->sk_bound_dev_if,
		tcp_sk(best->tcp_sock)->srtt_us >> 3,
		g_lambda);

	return scheduled ? 0 : -EINVAL;
}

static int blest_get_retrans(struct mptcp_sock *msk)
{
	/* Retransmissions use the same ECF-style decision */
	return blest_get_send(msk);
}

static void blest_init(struct mptcp_sock *msk)
{
	g_lambda = 1000;
	pr_info("BLEST: Scheduler initialized\n");
}

static void blest_release(struct mptcp_sock *msk)
{
	pr_info("BLEST: Scheduler released\n");
}

/* -------------------------------------------------------------------------
 * FIX 6: ops struct uses .get_send / .get_retrans (correct upstream API)
 * NOT .get_subflow which does not exist in the upstream mptcp_sched_ops.
 * ---------------------------------------------------------------------- */
static struct mptcp_sched_ops mptcp_sched_blest = {
	.get_send    = blest_get_send,
	.get_retrans = blest_get_retrans,
	.init        = blest_init,
	.release     = blest_release,
	.name        = "blest",
	.owner       = THIS_MODULE,
};

static int __init blest_register(void)
{
	int ret;

	ret = mptcp_register_scheduler(&mptcp_sched_blest);
	if (ret) {
		pr_err("BLEST: failed to register scheduler (%d)\n", ret);
		return ret;
	}

	pr_info("BLEST: scheduler registered (lambda_step=%d)\n", lambda_step);
	return 0;
}

static void __exit blest_unregister(void)
{
	mptcp_unregister_scheduler(&mptcp_sched_blest);
	pr_info("BLEST: scheduler unregistered\n");
}

module_init(blest_register);
module_exit(blest_unregister);

MODULE_AUTHOR("Based on Ferlin, Alay, Mehani, Boreli (2016)");
MODULE_DESCRIPTION("MPTCP BLEST: Blocking Estimation-based Scheduler");
MODULE_LICENSE("GPL");
