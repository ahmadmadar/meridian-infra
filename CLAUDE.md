# CLAUDE.md

Context for Claude Code sessions on this project. Read this before making
changes.

## What this project is

The production infrastructure for the Meridian MCP server, built on AWS
with Terraform. Sibling project to `meridian-fde-enterprise-demo` (the
application) and `meridian-dashboard`, both under `~/Documents/GitHub`.
Deliberately its own repo — infrastructure has its own lifecycle
(plan/apply/destroy) independent of application code changes, and that
separation is itself the realistic pattern, not a convenience.

This repo doesn't replace the existing Render/Vercel deployment — that
stays live as the fast free-tier POC. This is the "what production
actually looks like" build referenced in the server repo's
`docs/production-path.md`, done for real instead of staying prose. Both
deployments existing side by side is the point: it's the fast-POC/
production-path story made concrete.

## Why this exists

Portfolio piece for FDE/SE roles, same as the other two repos. Meridian
proved enterprise integration engineering; Atlas (`atlas-rag-agent`)
proved agentic AI engineering. This repo is the missing third piece:
real cloud infrastructure, provisioned as code, not clicked together in
a dashboard. Also genuine practice — AWS is new; prior hands-on cloud
experience is Azure (a 24-month datacenter migration). Documenting that
cross-cloud transfer explicitly is part of the story, not incidental.

## Repo structure

meridian-infra/
├── envs/
│ └── poc/ # the only environment for now — see "Hard technical conventions"
│ ├── main.tf
│ ├── variables.tf
│ ├── outputs.tf
│ └── terraform.tfvars.example
├── modules/
│ ├── network/ # VPC, subnets, IGW, security groups
│ ├── database/ # RDS + subnet group
│ ├── secrets/ # Secrets Manager
│ ├── compute/ # ECR + ECS cluster/service (Fargate) + ALB
│ └── observability/ # CloudWatch log groups, alarms, budget alarm
├── docs/
│ ├── architecture.md
│ ├── cost-notes.md
│ └── ai-assisted-delivery.md
└── README.md


Module-per-concern rather than one flat `main.tf` — mirrors the "every
tool follows the same shape" discipline from the server repo, applied to
infrastructure.

## Hard technical conventions (don't deviate without discussion)

- **ECS Fargate + ALB, not App Runner.** App Runner was the original
  plan (no load balancer charge), but it is not available on this AWS
  account: it's a "new AWS experience" project on the free plan, where
  App Runner is unsupported. Unlocking it requires upgrading and
  irreversibly activating advanced features, which also removes the
  free plan's spend cap. Decided 2026-10-02 to keep the free plan's
  hard cost ceiling and use Fargate + ALB instead. Reasoning is in
  `docs/architecture.md`.
- **No NAT Gateway.** Fargate tasks run in public subnets with public
  IPs, so they reach ECR, Secrets Manager and CloudWatch Logs directly
  through the Internet Gateway. Inbound to the tasks is allowed only
  from the ALB's security group. RDS stays in private subnets. This
  avoids ~$33/month — don't introduce a NAT Gateway to "simplify"
  networking.
- **RDS is never publicly accessible.** Private subnets only; its
  security group only allows 5432 from the app tasks' security group
  (SG-to-SG reference), never a CIDR like `0.0.0.0/0`.
- **AWS account constraints.** New-experience project, free plan,
  locked to `us-east-2` (resources can't be created in other Regions).
  CLI profile `meridian`, signed in via `aws login` (no long-lived
  keys). Check any new service against the free-plan supported list
  before designing around it.
- **No fallback values for secrets or config.** Same fail-closed pattern
  as both application repos — Terraform variables have no defaults for
  anything secret; real values come from `terraform.tfvars` (gitignored)
  or environment variables at apply time, never committed.
- **Local Terraform state for now**, not S3 + DynamoDB. Deliberate scope
  call for a single-operator POC — documented as a call, not an
  oversight. Revisit if this ever needs multi-operator or CI-triggered
  applies without a human present.
- **One environment (`envs/poc`).** No dev/staging/prod split — there's
  only one instance of this system. Don't build a multi-env structure
  prematurely.
- **Destroy between sessions.** This infrastructure does not need to run
  24/7. `terraform destroy` at the end of a working/demo session,
  `terraform apply` to bring it back — see `docs/cost-notes.md` for the
  actual cost impact of leaving it running vs. tearing it down.
- **A Budget alarm is non-negotiable**, built in Session 5, active from
  that point forward regardless of what else is running.

## Version control

GitHub Desktop, not `gh` CLI, matching the other two repos. Conventional
commit format (`feat:`, `fix:`, `docs:`) in the commit summary field.
Branch per session/task, not one long-running branch.

## Session workflow

Mirrors the other two repos' discipline, adapted for infra work:

1. Read this file first.
2. Design walkthrough before code: what's being provisioned, why this
   shape and not a simpler/more common one, and the cost impact, before
   writing any `.tf`.
3. Implement, following the conventions above.
4. Verify for real: `terraform plan` reviewed before every `apply`,
   then the actual resource checked (a live ALB URL responding,
   a real `psql` connection to RDS through the running service — not
   just "terraform apply exited 0").
5. Update "Current build status" below before ending the session.
6. Update `docs/ai-assisted-delivery.md` with the session's entry
   (generated/decisions/what-got-wrong/engagement log), first-person,
   dated by calendar day (confirm the day, don't assume).
7. `terraform destroy` if the session is ending and nothing needs to
   stay live for a demo.
8. Commit via GitHub Desktop.

## Learning mode (first AWS project)

This is a first hands-on AWS project — prior cloud experience is Azure
(a 24-month datacenter migration). Before implementing any new AWS
resource or Terraform change, extend step 2 of the session workflow
(design walkthrough before code) to also cover:

1. **What the service is** — name the AWS service(s) involved and
   explain in plain terms what it does and why it's needed here, before
   writing the Terraform for it.
2. **Azure equivalent** — one or two sentences naming the closest Azure
   service and what maps over directly vs. what's genuinely different.
   Don't force a 1:1 mapping where AWS/Azure diverge in a way that
   matters (say so instead).
3. **The actual code change** — walk through the specific resource
   block/argument about to be added before writing it, not just a
   summary after the fact. What each new line does, not just that it
   "configures the VPC."

Keep this concise — a few sentences per concept, not a lecture. Don't
re-explain something already covered earlier in the project; a short
"same SG-to-SG pattern as the database security group from Session 1"
is enough on repeat. This habit is itself worth preserving in
`docs/ai-assisted-delivery.md` as part of the AI-assisted delivery
story — the explain-before-build discipline is also useful evidence for
interviews.

## Current build status

Session 2 complete (2026-10-03), infrastructure destroyed.

- Session 1: `docs/architecture.md` (decisions 1–5) and `modules/network`
  (VPC `10.0.0.0/16`, 2 public + 2 private subnets in us-east-2a/b, IGW,
  ALB → app (3001) → db (5432) security groups, locked default SG).
- Session 2: `modules/database` (RDS Postgres 16, `db.t4g.micro`,
  private, encrypted, no backups) and `modules/secrets` (three secrets
  under `meridian-poc/`: `database-url`, `mcp-key-agent`,
  `mcp-key-dashboard`).
  - Secrets are write-only: ephemeral `random_password` +
    `password_wo` / `secret_string_wo`, nothing in state. Rotate by
    bumping `credentials_version` in `envs/poc/main.tf`. See decision 6.
  - `module.secrets.secret_arns` is ready for Session 3's task
    definition and execution role policy.
  - **Owed to Session 3:** a real DB connection from inside the VPC
    (ECS Exec `psql`, or the app's first query). Session 2 verified
    only through AWS describe calls, since nothing inside the VPC can
    reach RDS yet.
- Bring it back with `terraform -chdir=envs/poc plan -out=tfplan`,
  then review and run `terraform -chdir=envs/poc apply tfplan`. This
  needs `envs/poc/terraform.tfvars` (copy the `.example`) and a live
  `aws login --profile meridian`. RDS takes several minutes to create.

## Next steps

1. ~~Session 1: Terraform foundations + decisions doc.~~ Done.
2. ~~Session 2: RDS Postgres + Secrets Manager.~~ Done.
3. Session 3, split in two (decided 2026-10-05):
   - **3a:** ECR, ECS cluster/service/task definition on Fargate
     (ARM64), execution + task IAM roles, internal ALB, log group.
     Verify from inside the VPC via ECS Exec: migrations ran, seed, a
     real DB query (pays off Session 2's owed connection test).
   - **3b:** CloudFront with a VPC origin in front of the internal ALB
     for HTTPS (decision 7: no domain purchase for a POC). Verify a
     real MCP tool call end to end, plus the negative checks (no key →
     401, ALB and task IP unreachable from the internet).
4. Session 4: GitHub Actions — test → build → push to ECR → deploy,
   with a manual approval gate.
5. Session 5: CloudWatch logs/alarms + the Budget alarm.
6. Session 6: docs + wrap — architecture diagram, `docs/cost-notes.md`
   with actual observed spend vs. the original estimate, teardown/
   bring-up runbook, README tying back to the server repo's
   `docs/production-path.md`.

## AWS Agent Toolkit rules

AWS's starter rules for new-experience accounts, kept in their own file.
Where they conflict with this file, this file wins.

@.claude/aws-starter-rules.md