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
                     │ HTTPS (*.cloudfront.net)
             ┌───────▼────────┐
             │ CloudFront     │   Session 3b, decision 7
             └───────┬────────┘
                     │ VPC origin: stays on AWS's network
             ┌───────▼────────┐   private subnets (2 AZs)
             │ Internal ALB   │   no public address
             └───────┬────────┘
                     │ 3001, ALB SG only
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
| Task size | 0.25 vCPU / 0.5 GB, ARM64 (Graviton) |

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

## 7. HTTPS through CloudFront with a VPC origin, not a custom domain

An ALB's default DNS name can't get a TLS certificate, and this service
authenticates with an API key in a request header, so it can't run over
plain HTTP. I looked at three options:

- **A. CloudFront with a VPC origin pointing at an internal ALB.**
  CloudFront's default `*.cloudfront.net` domain comes with HTTPS. A VPC
  origin lets CloudFront reach an ALB in the private subnets over AWS's
  own network, so the ALB has no public address at all.
- **B. CloudFront in front of a public ALB.** The ALB would accept only
  CloudFront's managed prefix list plus a secret origin header. But the
  hop from CloudFront to the ALB is still plain HTTP over the internet,
  carrying the API key.
- **C. A domain I own plus a free ACM certificate on the ALB.** This is
  the most standard production setup.

**I chose A.** This is a POC, so I'm not buying a domain for it, and
that's why C is out. A also beats B: the API key is never sent in plain
text over the internet, and an internal ALB drops two public IPv4
addresses (about $0.01/hr). The ALB's security group changes from
"80/443 from anywhere" to "from CloudFront's VPC origin only."

If this were a real production service with a domain already in place,
I'd use C, with CloudFront added only if caching or edge features were
needed.

Before choosing A, I checked it against the free plan. CloudFront is on
the supported list, and only Lambda@Edge is excluded. The free plan's
service control policy allows all `cloudfront:*` actions, so VPC
origins are included. It also allows `ssm:*` and `ssmmessages:*`,
which ECS Exec needs. If a real apply still gets refused, B is the
fallback.

One related gotcha: as the project nears its spend limit, AWS applies
another policy. That one denies `cloudfront:CreateDistribution`,
`ecs:CreateService` and `elasticloadbalancing:CreateLoadBalancer`. If
this stack's apply suddenly fails with Access Denied, check spend in
AWS Settings > Billing before debugging IAM.

## 8. ARM64 (Graviton) tasks

The image is built on an Apple Silicon Mac, so it comes out `linux/arm64`
by default. Fargate defaults to x86, which would fail at start with
`exec format error`. Rather than cross-building for x86 under emulation,
the task definition sets `cpu_architecture = "ARM64"`. Graviton Fargate
is also about 20% cheaper, and it matches the `db.t4g` RDS instance.

Images are built with `--provenance=false --sbom=false`. Docker
Desktop's defaults otherwise push an OCI image index (the image plus an
attestation manifest) instead of a single image. ECR's basic scan doesn't
scan an index, and the "expire untagged" lifecycle rule would target
the untagged image underneath the tag.

## 9. ECR is bootstrapped first, with `-target`

The ECS service can't start without an image, and the image can't be
pushed until the repository exists. So every bring-up applies the ECR
repository on its own first (`-target`), pushes the image, then applies
everything else. The tag is a required `image_tag` variable (the app
repo's git short SHA, never `latest`), and tags are immutable.
Targeting is normally discouraged. Here it's a documented, one-step
bootstrap, and Session 4's pipeline takes over the push.

The repository has `force_delete = true`, so `destroy` removes it even
with images inside. Re-pushing about 300 MB at each bring-up is cheaper
and simpler than keeping a registry alive outside the stack.

## 10. Scoped IAM instead of AWS-managed task policies

Each task has two roles. The execution role is used by ECS to pull the
image, inject secrets and create the log stream. The task role is used
by the app's own process. The execution role has an inline policy
scoped to this repository, this log group and the three secret ARNs,
rather than `AmazonECSTaskExecutionRolePolicy`, which allows pulling from
every repository and writing to every log group. The app calls no AWS
APIs, so the task role carries only the four `ssmmessages` actions
needed for ECS Exec. Both trust policies require `aws:SourceAccount` and
an `aws:SourceArn` in this account and Region (confused-deputy
protection).

## AWS account constraints

- A new-experience project on the free plan, locked to `us-east-2`.
  Resources can't be created in any other Region.
- The CLI signs in with `aws login` (browser sign-in, 12-hour sessions)
  under the profile `meridian`. There are no long-lived access keys
  anywhere.
- The free plan's spend cap is a safety net, not a substitute for the
  Budget alarm in Session 5. The alarm tells me when spend is climbing.
  The cap only stops things once it's too late to fix calmly.
