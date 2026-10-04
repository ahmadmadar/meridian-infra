# Architecture decisions

These are the calls I made before provisioning anything, and why. Each
one is a deliberate trade-off for a single-operator proof of concept
that gets torn down between sessions, not a claim about what a large
production system should do. Prices are AWS list prices for `us-east-2`
at the time of writing. `docs/cost-notes.md` will compare them against
what I actually got billed.

## Target shape

```
                  Internet
                     │
             ┌───────▼────────┐   public subnets (2 AZs)
             │ Application    │   SG: 80/443 from anywhere
             │ Load Balancer  │
             └───────┬────────┘
                     │ container port, ALB SG only
             ┌───────▼────────┐   public subnets (2 AZs)
             │ ECS Fargate    │   public IP for outbound only;
             │ task (MCP)     │   SG blocks all inbound except the ALB
             └───────┬────────┘
                     │ 5432, app SG only
             ┌───────▼────────┐   private subnets (2 AZs)
             │ RDS Postgres   │   no route to the internet,
             └────────────────┘   never publicly accessible
```

| Piece | Value |
|---|---|
| Region | `us-east-2` (fixed by the account, see below) |
| VPC | `10.0.0.0/16` |
| Public subnets | `10.0.0.0/24` (us-east-2a), `10.0.1.0/24` (us-east-2b) |
| Private subnets | `10.0.10.0/24` (us-east-2a), `10.0.11.0/24` (us-east-2b) |
| NAT Gateway | None |

## 1. Compute: ECS Fargate + ALB, not App Runner

**The original plan was App Runner.** It runs a container from ECR,
gives you an HTTPS URL, and has no separate load balancer charge. A
0.25 vCPU / 0.5 GB service costs roughly $0.02/hr while serving
requests and about $0.004/hr idle, which works out to a few dollars a
month. It reaches a private RDS through a VPC Connector, so it needs no
NAT Gateway either. For this scale it was the cheapest, simplest
option.

**It isn't available on my account.** I signed up through AWS's new
account experience, which puts the account in a "project" on the free
plan. On the free plan, App Runner is on the "not supported for this
experience" list. I only found this out when I checked the supported
services list against the design, before writing any Terraform.
Unlocking it means upgrading to the paid plan and then activating
advanced features, which:

- can't be undone,
- removes the free plan's spend limit and doesn't allow one to be
  created again,
- makes me the administrator of an AWS Organization with a root user.

I'm keeping the free plan. A hard ceiling on spend ($100 in credits,
and the account can't bill past it) is worth more to me on a first AWS
project than App Runner's lower idle cost. Everything else I need is
supported: VPC, RDS, ECR, ECS/Fargate, Elastic Load Balancing, Secrets
Manager, CloudWatch, Budgets.

**What I'm using instead: ECS on Fargate behind an Application Load
Balancer.** Fargate runs the container without me managing servers.
The ALB gives it a stable public endpoint and health checks. This is
also the most common way containers are run on AWS, so it's the more
transferable pattern even though it isn't the cheapest.

**Cost while running** (0.25 vCPU / 0.5 GB task, excluding RDS):

| Item | Rate | Per hour |
|---|---|---|
| ALB | $0.0225/hr + LCUs (negligible at demo traffic) | ~$0.023 |
| Fargate task | 0.25 × $0.04048 vCPU + 0.5 × $0.004445 GB | ~$0.012 |
| Public IPv4 | $0.005/hr each × 3 (2 ALB, 1 task) | $0.015 |
| **Total** | | **~$0.05/hr** |

That's about $36/month left running 24/7, versus single-digit dollars
for App Runner. That gap is why CLAUDE.md originally ruled Fargate out.
But this stack is destroyed between sessions, so a 4-hour working
session costs about 20 cents. At this usage pattern the difference
barely matters.

## 2. No NAT Gateway

The textbook Fargate layout puts tasks in private subnets and gives
them outbound internet through a NAT Gateway. The task needs outbound
access to pull its image from ECR, read secrets from Secrets Manager and
ship logs to CloudWatch. A NAT Gateway costs $0.045/hr (~$33/month)
plus $0.045 per GB processed, which makes it the single most expensive
idle item in a build this size.

The other way to keep tasks private is VPC endpoints, private routes to
specific AWS services. That needs at least four interface endpoints
(ECR API, ECR Docker, CloudWatch Logs, Secrets Manager) at $0.01/hr per
AZ each. Across two AZs that's ~$58/month, more than the NAT Gateway.

**What I'm doing instead: tasks run in the public subnets with a public
IP, used only for outbound traffic.** Inbound is locked down by the
task's security group, which accepts traffic only from the ALB's
security group, so nothing on the internet can reach the task
directly. The cost is $0.005/hr for the IP.

The trade-off: the task has a public address, so the protection is the
security group rather than having no route from the internet at all.
For a production system holding real customer data I'd move tasks into
private subnets and pay for NAT or endpoints. For this proof of concept
the security group is the right control, and the database (the part
that actually holds data) stays fully private either way.

## 3. RDS is never publicly accessible

RDS goes in private subnets with no route to the internet, and
`publicly_accessible = false`. Its security group allows Postgres
(5432) only from the app tasks' security group. That rule references
the other security group by ID, not by IP range, so it can't drift into
`0.0.0.0/0`, and it keeps working when tasks get new IPs on every
deploy. RDS needs subnets in two AZs even for a single instance, which
is why there are two private subnets.

## 4. Local Terraform state

State lives on my laptop, not in S3 with a DynamoDB lock table. I'm
the only operator and every apply is run by hand after reviewing the
plan, so there's nothing to lock against. The trigger to revisit is
the first time something other than me needs to run an apply: a second
person, or the Session 4 pipeline deploying without me present.

Local state holds no secret values (see decision 6), but it still maps
out every resource ID and ARN, so `*.tfstate` is gitignored from the
first commit anyway.

## 5. One environment, destroyed between sessions

There's one environment, `envs/poc`, because there's one instance of
this system. Everything is built to be destroyed at the end of a
working session and re-applied at the start of the next, so idle cost
is close to zero. The Render/Vercel deployment stays up as the
always-on demo.

## 6. Secrets never touch Terraform state

The database password and both MCP API keys are generated by Terraform
as *ephemeral* `random_password` values. They exist only for the
duration of a run and are passed to AWS through write-only arguments
(`password_wo` on RDS, `secret_string_wo` on Secrets Manager). Nothing
secret is written to state, plan files or plan output, which I checked
after the first apply by searching the state file for each real value.

The cost is that Terraform can't detect drift on those values, and it
only sends them when a version number changes. One `credentials_version`
local covers all three, so bumping it rotates everything in one apply.
One edge case is guarded explicitly: if RDS were ever replaced, it would
get a fresh password while the `DATABASE_URL` secret kept the old one.
So the secret version is tied to the instance's `resource_id` with
`replace_triggered_by`.

I considered RDS-managed master passwords (`manage_master_user_password`),
which keep the password out of Terraform entirely, but the app expects a
single Prisma `DATABASE_URL`, and an RDS-rotated password would silently
break a URL built from it.

Each secret is its own Secrets Manager resource with
`recovery_window_in_days = 0`. The default 7–30 day window would reserve
the names after every `destroy` and break the next `apply`.

## AWS account constraints

- A new-experience project on the free plan, locked to `us-east-2`.
  Resources can't be created in any other Region.
- The CLI signs in with `aws login` (browser sign-in, 12-hour sessions)
  under the profile `meridian`. There are no long-lived access keys
  anywhere.
- The free plan's spend cap is a safety net, not a substitute for the
  Budget alarm in Session 5. The alarm tells me when spend is climbing.
  The cap only stops things once it's too late to fix calmly.

## Open questions

- **HTTPS (Session 3).** An ALB's default DNS name can't get a TLS
  certificate, and this service authenticates with an API key in a
  header, so it shouldn't run over plain HTTP. The options are a domain
  I own plus a free ACM certificate, or CloudFront in front of the ALB
  (CloudFront's default domain comes with HTTPS). I'll decide in
  Session 3.
