# Cost notes

What this stack actually cost, against the estimate in
[`architecture.md`](architecture.md) decision 1. Figures are from AWS Cost
Explorer (`aws ce get-cost-and-usage`, `UnblendedCost`, gross `Usage`
records, in USD), pulled on 2026-11-06.

## The headline

| | |
|---|---|
| Gross usage billed so far | **$0.53** over about 11 stack-hours |
| Charged to me | **$0.00**: the account is on AWS's free plan, and credits absorb all of it |
| Credits remaining (2026-11-06) | $139.48, plan active until 2027-04-02 |
| Observed running cost | **~$0.048/hr** all-in, RDS included |
| Estimated running cost | ~$0.05/hr **excluding** RDS (~$0.066/hr with it) |
| Left on 24/7 | ~$35/month observed, against ~$36/month estimated without RDS |

So the estimate held up, and it was slightly pessimistic. The reasons are
in the table below. The destroy-between-sessions habit matters more than
any single line item: a 4-hour session costs about 19 cents.

Cost Explorer nets the free-plan credits against usage, so the plain
cost view shows $0.00 for every service. The gross numbers here come from
filtering on `RECORD_TYPE = Usage`.

## What was billed

| Service | October | November (to 11-05) | Total |
|---|---|---|---|
| Elastic Load Balancing (the ALB) | $0.0900 | $0.1575 | $0.2475 |
| RDS (`db.t4g.micro`, 20 GB gp3) | $0.0518 | $0.1003 | $0.1521 |
| ECS (Fargate, ARM64) | $0.0229 | $0.0499 | $0.0728 |
| VPC (public IPv4 address) | $0.0126 | $0.0257 | $0.0383 |
| Secrets Manager (3 secrets) | $0.0063 | $0.0087 | $0.0150 |
| **Total** | **$0.1838** | **$0.3423** | **$0.5261** |

CloudFront, CloudWatch alarms, SNS, AWS Budgets, ECR, data transfer and
KMS all rounded to zero. CloudFront and the first 10 standard alarms sit
inside their free allowances at this traffic.

By day, the usage landed on 2026-10-06 ($0.11, Session 3a), 2026-10-08
($0.03, the blocked 3b attempt), 2026-10-13 ($0.04, the 3b retry) and
2026-11-03 ($0.34). The 11-03 bucket holds both the 3b verification and
the Session 4 run; Cost Explorer's day boundaries are UTC and I didn't
split it further.

**Not in these numbers yet:** the Session 5 bring-up on 2026-11-06.
Billing data lags by 8 to 24 hours, so it hasn't posted. It will add
roughly another $0.07 to $0.10 if it ran about 1.5 to 2 hours at the
observed rate. When it posts, add it to the table above.

## Estimate vs observed, per hour

The ALB is the one line that bills in whole, countable hours (4.0 in
October, 7.0 in November, exactly $0.0225 each), so I divided every line
by those 11 billed hours. That makes the other rows approximate, since
RDS and the task don't start and stop at exactly the same minute as the
ALB, but the comparison is close enough to see where the estimate was off.

| Line | Estimated | Observed | Why it differs |
|---|---|---|---|
| ALB | $0.023 | $0.0225 | Exact. LCU charges were negligible at demo traffic. |
| Fargate task | $0.012 | $0.0066 | The estimate used x86 prices; the task runs on ARM64 (decision 8), which is about 20% cheaper. The task also runs a little less than the full ALB hour. |
| Public IPv4 | $0.015 (3 IPs) | $0.0035 | Decision 7 made the ALB internal, which removed its two public IPs. Only the task's remains. |
| RDS | not estimated | $0.0138 | Wasn't in the original per-hour table. About the list price for `db.t4g.micro` plus storage. |
| Secrets Manager | not estimated | $0.0014 | Three secrets at $0.40/month each, prorated. |
| **Total** | **~$0.05 (ex-RDS)** | **~$0.048 (with RDS)**, **~$0.034 ex-RDS** | |

Two things moved in opposite directions. The estimate was too high on
networking and compute, because the design changed after it (an internal
ALB, ARM64). It was missing two lines altogether, RDS and Secrets
Manager. They roughly cancelled out.

## What it would cost left on

At the observed $0.048/hr all-in, 24/7 is about **$35/month**
($0.048 × 730 hours). Without RDS it's about $25. The original
README figure of ~$36/month excluded RDS, so the real all-in number is
lower than that figure implied, not higher.

For comparison, the always-on alternative that decision 1 gave up, App
Runner, would have been single-digit dollars a month. That gap is why
the stack is destroyed between sessions instead of left running.

## What isn't in the stack's cost

- **The NAT Gateway I avoided** (decision 2) would have added $0.045/hr,
  nearly doubling the hourly cost on its own.
- **The interface VPC endpoints I also avoided** would have been about
  $58/month, more than the NAT Gateway.
- **CloudFront** is $0 here because the free plan's allowance covers a
  demo's traffic. It has no hourly charge, and a VPC origin adds none.
- **The Budget** ($10/month, alerts at 80% actual and 100% forecasted)
  costs nothing. Its data lags by 8 to 24 hours, so it catches a stack
  left running, not a fast spike. The free plan's hard spend cap is the
  real backstop.

## How to re-check

```sh
# Gross usage by service, month by month (the plain view nets out credits)
aws ce get-cost-and-usage --profile meridian --region us-east-1 \
  --time-period Start=2026-10-01,End=2026-12-01 --granularity MONTHLY \
  --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --filter '{"Dimensions":{"Key":"RECORD_TYPE","Values":["Usage"]}}'

# Credits remaining
aws freetier get-account-plan-state --profile meridian --region us-east-1
```

Cost Explorer is reachable through the `meridian` profile and works with
the stack destroyed.
