# meridian-infra

Production infrastructure for the Meridian MCP server, on AWS, built
with Terraform.

The Meridian server
([`meridian-fde-enterprise-demo`](https://github.com/ahmadmadar/meridian-fde-enterprise-demo))
already runs on Render and Vercel as a fast, free-tier proof of concept,
and that deployment stays live. This repo is what its
[`docs/production-path.md`](https://github.com/ahmadmadar/meridian-fde-enterprise-demo/blob/main/docs/production-path.md)
describes in prose, built for real: private networking, a managed
database, secrets that aren't environment variables in a dashboard, and
a container service behind a load balancer, all provisioned as code.
The point is to have both deployments side by side, the fast POC and
the production path.

It's also my first AWS project. My earlier cloud work was on Azure (a
24-month datacenter migration), so the docs call out where AWS maps
onto Azure and where it doesn't.

Related repos:
[`meridian-fde-enterprise-demo`](https://github.com/ahmadmadar/meridian-fde-enterprise-demo)
(the MCP server) and
[`meridian-dashboard`](https://github.com/ahmadmadar/meridian-dashboard)
(the dashboard).

## Target architecture

```
                  Internet
                     │
             ┌───────▼────────┐   public subnets (2 AZs)
             │ Application    │   SG: 80/443 from anywhere
             │ Load Balancer  │
             └───────┬────────┘
                     │ port 3001, ALB SG only
             ┌───────▼────────┐   public subnets (2 AZs)
             │ ECS Fargate    │   public IP for outbound only;
             │ task (MCP)     │   SG blocks all inbound except the ALB
             └───────┬────────┘
                     │ 5432, app SG only
             ┌───────▼────────┐   private subnets (2 AZs)
             │ RDS Postgres   │   no route to the internet,
             └────────────────┘   never publicly accessible
```

The main decisions and why I made them (full reasoning in
[`docs/architecture.md`](docs/architecture.md)):

- **ECS Fargate + ALB, not App Runner.** App Runner isn't supported on
  this account's free plan. Unlocking it is irreversible and removes
  the spend cap, so I kept the cap.
- **No NAT Gateway.** Tasks sit in public subnets with a public IP that
  is only used for outbound traffic. They accept inbound traffic only
  from the ALB's security group. This saves about $33/month.
- **RDS is never publicly accessible.** It runs in private subnets, and
  its security group only allows the app's security group in, by ID,
  never a CIDR range.
- **Local Terraform state, one environment, destroyed between
  sessions.** I'm the only operator, so these are deliberate scope
  calls rather than oversights. Each one says what would make me
  revisit it.

## Build status

| Session | Scope | Status |
|---|---|---|
| 1 | Terraform foundations: VPC, subnets, IGW, tiered security groups, decisions doc | ✅ Done (applied, verified, destroyed) |
| 2 | RDS Postgres (private) + Secrets Manager | Next |
| 3 | ECR + ECS Fargate service behind an ALB, HTTPS decision | Planned |
| 4 | GitHub Actions: test → build → push → deploy, manual approval gate | Planned |
| 5 | CloudWatch logs/alarms + Budget alarm | Planned |
| 6 | Docs + wrap: diagram, observed cost vs. estimate, runbook | Planned |

Today, only the network layer exists. The README will be updated as
each session lands.

## Repo layout

```
envs/poc/            the only environment: provider config + module wiring
modules/network/     VPC, subnets, IGW, route tables, security groups
modules/...          database, secrets, compute, observability (Sessions 2–5)
docs/
  architecture.md          decisions and trade-offs, written before provisioning
  ai-assisted-delivery.md  what Claude Code generated vs. what I decided, per session
```

## Running it

### Prerequisites

- Terraform ≥ 1.9 (I've been using 1.16)
- AWS CLI v2, signed in with `aws login --profile meridian`. The CLI
  uses short-lived browser sign-in sessions, and there are no long-lived
  access keys.
- An AWS account that can create resources in `us-east-2`. The
  variables reject any other Region.

### Bring it up

```sh
cp envs/poc/terraform.tfvars.example envs/poc/terraform.tfvars   # gitignored
terraform -chdir=envs/poc init
terraform -chdir=envs/poc plan -out=tfplan
# review the plan, then apply exactly what was reviewed:
terraform -chdir=envs/poc apply tfplan
```

None of the variables have defaults (fail-closed). Real values go in
`terraform.tfvars` or environment variables and are never committed.

### Tear it down

```sh
terraform -chdir=envs/poc destroy
```

This stack isn't meant to run 24/7, so it gets destroyed at the end of
every working session. The Render/Vercel deployment is the always-on
demo.

## Cost

The network layer alone (Session 1) costs nothing. Once the full stack
is running, it's estimated at **~$0.05/hr** excluding RDS (ALB + one
0.25 vCPU Fargate task + three public IPv4 addresses). That's about
$36/month if left on, or about 20 cents for a 4-hour session. The
account is on AWS's free plan with a hard spend cap, and a Budget alarm
lands in Session 5. Observed spend versus this estimate will go in
`docs/cost-notes.md` at the end of the build.

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
