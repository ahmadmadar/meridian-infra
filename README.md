# meridian-infra

Production infrastructure for the Meridian MCP server, on AWS, built
with Terraform.

The Meridian server
([`meridian-fde-enterprise-demo`](https://github.com/ahmadmadar/meridian-fde-enterprise-demo))
already runs on Render and Vercel as a fast, free-tier proof of concept,
and that deployment stays live. This repo is what its
[`docs/production-path.md`](https://github.com/ahmadmadar/meridian-fde-enterprise-demo/blob/main/docs/production-path.md)
describes in prose, built for real: private networking, a managed
database, secrets that never touch Terraform state, a container service
behind HTTPS, a deploy pipeline with an approval gate, and alerting, all
provisioned as code. The point is to have both deployments side by side,
the fast POC and the production path.

It's also my first AWS project. My earlier cloud work was on Azure (a
24-month datacenter migration), so the docs call out where AWS maps
onto Azure and where it doesn't.

Related repos:
[`meridian-fde-enterprise-demo`](https://github.com/ahmadmadar/meridian-fde-enterprise-demo)
(the MCP server) and
[`meridian-dashboard`](https://github.com/ahmadmadar/meridian-dashboard)
(the dashboard).

## What gets built

[![Runtime architecture, demo to production: clients reach CloudFront, which reaches an internal ALB over a VPC origin, then a Fargate task in a public subnet, then a private RDS Postgres database. A security group chain, Secrets Manager, ECR and CloudWatch Logs surround it, and a NAT Gateway is shown as deliberately absent.](docs/images/runtime-architecture.png)](docs/images/runtime-architecture.png)

*Diagram 1: the runtime, from the free-tier demo (left) to the production
build (right). Click for full size.*

Around that path: Secrets Manager for the database URL and the MCP API
keys, ECR for the image, CloudWatch Logs, seven CloudWatch alarms
feeding an SNS email, a $10 monthly Budget, and a GitHub Actions
pipeline (test, then a manually approved build and deploy). The full
diagram, with what each module owns, is in
[`docs/architecture.md`](docs/architecture.md#the-full-picture).

The main decisions and why I made them (full reasoning in
[`docs/architecture.md`](docs/architecture.md), eleven numbered
decisions):

- **ECS Fargate + ALB, not App Runner.** App Runner isn't supported on
  this account's free plan. Unlocking it is irreversible and removes
  the spend cap, so I kept the cap.
- **No NAT Gateway.** Tasks sit in public subnets with a public IP that
  is only used for outbound traffic, and accept inbound traffic only
  from the ALB's security group. That avoids about $33/month.
- **HTTPS through CloudFront with a VPC origin.** The ALB is internal,
  so it has no public address, and the API key never crosses the
  internet in plain text. No domain needed.
- **RDS is never publicly accessible.** Private subnets only, and its
  security group allows only the app's security group in, by ID, never
  a CIDR range.
- **Secrets never touch Terraform state.** They are generated as
  ephemeral values and written with write-only arguments.
- **The CI deploy identity is a session-scoped IAM user key, not
  GitHub OIDC.** The free plan's service control policy denies creating
  an OIDC provider. The decision records what I'd change if that ever
  opens up.
- **Local Terraform state, one environment, destroyed between
  sessions.** I'm the only operator, so these are deliberate scope calls
  rather than oversights. Each one says what would make me revisit it.

## Delivery and operations

[![Delivery, observability and cost control: a GitHub Actions pipeline with an approval gate, a CRITICAL scan gate and an ECS circuit breaker; seven CloudWatch alarms feeding SNS email; a $10 monthly Budget; and the plan, apply, verify, destroy, read-back lifecycle.](docs/images/delivery-and-operations.png)](docs/images/delivery-and-operations.png)

*Diagram 2: everything around the runtime that makes it production-grade.
Click for full size.*

- **Gated deploys.** Tests run on every push. A release only runs from a
  manual dispatch on `main`, behind a reviewer, and fails on any CRITICAL
  image-scan finding. The ECS circuit breaker rolls back a failing
  deploy.
- **Alerting that's been proven.** Seven alarms notify through SNS. A
  forced alarm produced both the ALARM and the OK email.
- **A cost guardrail.** A $10 monthly Budget emails directly, separate
  from SNS, on top of the free plan's hard spend cap.
- **A lifecycle, not a one-off.** Plan, apply, verify against AWS,
  destroy, then read back that nothing is left. The runbook is in
  [`docs/runbook.md`](docs/runbook.md).

## Build status

All six sessions are done. Sessions 1 to 5 each applied real
infrastructure, checked it against AWS (not just "apply exited 0"), and
destroyed it afterwards. Session 6 is documentation only.

| Session | Scope | Status |
|---|---|---|
| 1 | Terraform foundations: VPC, subnets, IGW, tiered security groups, decisions doc | ✅ |
| 2 | RDS Postgres (private) + Secrets Manager | ✅ |
| 3a | ECR + ECS Fargate service behind an internal ALB | ✅ |
| 3b | CloudFront with a VPC origin, HTTPS end to end | ✅ |
| 4 | GitHub Actions: test → build → push → deploy, manual approval gate | ✅ |
| 5 | CloudWatch alarms, SNS email alerts, monthly Budget | ✅ |
| 6 | Docs: full diagram, observed cost vs. estimate, runbook | ✅ |

The stack is **not running right now**, by design. The Render/Vercel
deployment is the always-on demo; this one is brought up for a session
and torn down.

## Repo layout

```
envs/poc/            the only environment: provider config + module wiring
modules/
  network/           VPC, subnets, IGW, route tables, security groups
  database/          RDS Postgres in the private subnets
  secrets/           Secrets Manager (write-only values)
  compute/           ECR, ECS cluster and Fargate service, internal ALB, IAM roles
  edge/              CloudFront distribution and VPC origin
  ci/                IAM user and scoped policy for the app repo's pipeline
  observability/     log group, alarms, SNS topic, Budget
docs/
  images/                  the two architecture diagrams used in this README
  architecture.md          decisions and trade-offs, plus the full diagram
  runbook.md               bring-up, verification and teardown, step by step
  cost-notes.md            what it cost vs. what I estimated
  ai-assisted-delivery.md  what Claude Code generated vs. what I decided, per session
```

## Running it

### Prerequisites

- Terraform ≥ 1.11 (write-only arguments need it; I use 1.16)
- AWS CLI v2, signed in with `aws login --profile meridian`. The CLI
  uses short-lived browser sign-in sessions, and there are no long-lived
  access keys, apart from the CI deploy user's session-scoped key.
- Docker, to push the first image.
- An AWS account that can create resources in `us-east-2`. The
  variables reject any other Region.

### Bring it up and tear it down

[`docs/runbook.md`](docs/runbook.md) has the full procedure. In short:

```sh
cp envs/poc/terraform.tfvars.example envs/poc/terraform.tfvars   # gitignored
terraform -chdir=envs/poc init
# 1. apply only the ECR repository, 2. push the first image,
# 3. then plan, review, and apply the rest:
terraform -chdir=envs/poc plan -out=tfplan
terraform -chdir=envs/poc apply tfplan
```

None of the variables have defaults (fail-closed). Real values go in
`terraform.tfvars` or environment variables and are never committed.
Plan before every apply, and apply exactly what was reviewed. The apply
takes 25 to 30 minutes, mostly RDS and the CloudFront VPC origin. Destroy
takes about 15, and the runbook lists what to read back to confirm
nothing is left.

## Cost

Left running, the stack costs about **$0.048/hr, or about $35/month**,
RDS included. Because it's destroyed between sessions, a 4-hour session
costs about 19 cents. Across the bring-ups billed so far (through
2026-11-05), AWS recorded **$0.53** in gross usage, all of it absorbed by
the free plan's credits, so I paid nothing. The Session 5 bring-up
hadn't posted to billing yet when I wrote this. A Budget alarm ($10/month) is active whenever the stack is up.

The original estimate was ~$0.05/hr excluding RDS. It held up: the real
numbers came in lower on networking and compute (an internal ALB removed
two public IPs, and ARM64 tasks are cheaper), and higher on two lines I
hadn't listed (RDS and Secrets Manager). The line-by-line comparison is
in [`docs/cost-notes.md`](docs/cost-notes.md).

## How this was built

Claude Code writes the Terraform, the docs and the verification
commands. I make the architecture and cost calls, review every plan,
and approve every `apply` and `destroy`. That approval is enforced in
[`.claude/settings.json`](.claude/settings.json), not left to habit.
Every resource is checked against AWS after apply, not just trusted
because `apply` exited 0. The session-by-session record, including what
got caught and corrected, is in
[`docs/ai-assisted-delivery.md`](docs/ai-assisted-delivery.md).

## License

[MIT](LICENSE)
