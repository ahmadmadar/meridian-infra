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
│ ├── ci/ # IAM user + policy for the app repo's GitHub Actions deploy
│ ├── edge/ # CloudFront + VPC origin, ALB ingress from CloudFront
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
  keys, apart from the CI deploy user's session-scoped key below). Check any new service against the free-plan supported list
  before designing around it.
- **No fallback values for secrets or config.** Same fail-closed pattern
  as both application repos — Terraform variables have no defaults for
  anything secret; real values come from `terraform.tfvars` (gitignored)
  or environment variables at apply time, never committed.
- **CI uses a session-scoped IAM user key, not OIDC.** The free-plan SCP
  denies `iam:*Provider*`, so GitHub OIDC can't be created (decision 11).
  The key is created by hand at bring-up, never by Terraform (it would
  land in state), and deleted by hand before destroy. No
  `force_destroy` on the user: it calls `iam:DeleteLoginProfile`, which
  the SCP also denies.
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

## Model usage

Default model is Sonnet. Opus is reserved for specific moments, mainly
to keep cost down and because `terraform plan` review catches most
mistakes before anything is created.

Claude Code can't switch models itself. The user switches with `/model`.
So when a task falls into the Opus category below, say so and recommend
the switch before starting, instead of continuing on Sonnet or assuming
the switch has happened. Also say when it's fine to switch back.

**Stay on Sonnet for:**
- Writing and editing Terraform modules
- The GitHub Actions pipeline
- Explain-before-you-build walkthroughs (learning mode)
- Docs, the decisions log and cost notes

**Recommend Opus for:**
- Session-start design decisions that set the shape of something
  (VPC Connector and security group layout, RDS access path)
- IAM and networking debugging, where several pieces interact
- A review pass before anything hard to undo: `terraform destroy`,
  changes to a live database, or changes to secrets
- Any issue that has failed two fix attempts on Sonnet

**Logging:** note in `docs/ai-assisted-delivery.md` which model handled
what, and why any switch happened (for example, "switched to Opus to
debug the VPC Connector security group"). Specific entries only, not
"used both models".

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
is enough on repeat. These explanations stay in the conversation: don't
write them into `docs/ai-assisted-delivery.md`, whose engagement log is
build-focused (what was built, decided, verified, caught and torn down).

## Current build status

Session 5 complete: CloudWatch alarms, SNS email alerts and the $10
monthly Budget verified on 2026-11-06 (a forced alarm delivered both the
ALARM and OK emails). Infrastructure destroyed. Next is Session 6.

- Session 1: `docs/architecture.md` (decisions 1–5) and `modules/network`
  (VPC `10.0.0.0/16`, 2 public + 2 private subnets in us-east-2a/b, IGW,
  ALB → app (3001) → db (5432) security groups, locked default SG).
- Session 2: `modules/database` (RDS Postgres 16, `db.t4g.micro`,
  private, encrypted, no backups) and `modules/secrets` (three secrets
  under `meridian-poc/`: `database-url`, `mcp-key-agent`,
  `mcp-key-dashboard`). Secrets are write-only (ephemeral
  `random_password` + `password_wo` / `secret_string_wo`), nothing in
  state. Rotate by bumping `credentials_version` in `envs/poc/main.tf`.
  See decision 6.
- Session 3a: `modules/compute` (ECR repo `meridian-poc/mcp-server`,
  ECS cluster + Fargate ARM64 service + task definition, scoped
  execution/task IAM roles, internal ALB in the private subnets) and
  `modules/observability` (just the app log group so far; Session 5
  adds alarms + Budget). Decisions 7–10.
  - Verified: target healthy, `prisma migrate deploy` ran against RDS,
    one-off seed task wrote 20 accounts / 60 tickets / 1 incident, and
    an ECS Exec read-back over SSL. Session 2's owed DB test is paid.
  - The ALB is internal and has no listener reachable from outside the
    VPC. It's only reachable publicly once 3b adds CloudFront.
  - **App repo follow-ups** (meridian-fde-enterprise-demo): ECR basic
    scan of `e5cbf50` found 7 critical / 33 high, all Debian OS packages
    in `node:20-slim` (Node 20 is EOL since 2026-04). **Resolved in
    Session 4** (Node 24 base, `openssl`, production dependencies only).

### Bring-up runbook

Needs a live `aws login --profile meridian`, Docker running, and
`envs/poc/terraform.tfvars` (copy the `.example`; `image_tag` is the app
repo's git short SHA).

1. ECR first (decision 9):
   `terraform -chdir=envs/poc plan -target=module.compute.aws_ecr_repository.app -target=module.compute.aws_ecr_lifecycle_policy.app -out=tfplan`,
   review, `terraform -chdir=envs/poc apply tfplan`.
2. Push the image from the app repo's `main` (tags are immutable). This
   manual push is only the bootstrap: the service needs a healthy image
   before the first apply can finish, and the pipeline can't create it.
   After that, deploys go through the pipeline:
   `aws ecr get-login-password --profile meridian --region us-east-2 | docker login --username AWS --password-stdin <account>.dkr.ecr.us-east-2.amazonaws.com`,
   then `docker buildx build --platform linux/arm64 --provenance=false --sbom=false --output "type=image,name=<repo_url>:<sha>,push=true" .`
   Without the two flags Docker Desktop pushes an image index the scan
   and lifecycle rule mishandle. Use `buildx` rather than `docker push`:
   on Docker Desktop's containerd image store `docker push` timed out
   ("timeout awaiting response headers") on the large layers, on
   different layers each run; the `buildx` push succeeded in ~7 minutes
   (~299MB compressed). In zsh write `"${REPO}:${SHA}"`, because
   `$REPO:e...` is read as a modifier and silently mis-tags the image.
   To build a specific older commit without touching the app repo's
   checkout, `git archive <sha> | tar -x -C <dir>` and build from there.
3. Everything else: `terraform -chdir=envs/poc plan -out=tfplan`,
   review, apply. Expect 25-30 minutes with CloudFront: RDS ~10, the
   VPC origin ~8 (and about as long to delete), and the distribution
   a few more. The apply waits for the service to be healthy.
   **CI deploy key** (decision 11, once the app repo's pipeline exists):
   `aws iam create-access-key --user-name "$(terraform -chdir=envs/poc output -raw ci_user_name)" --profile meridian`,
   then put `AccessKeyId`/`SecretAccessKey` in the app repo's `poc`
   environment secrets (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`).
   Run it in a separate terminal (not `!` in Claude Code, which would
   put the secret in the transcript), and never save the output to a
   file or commit it. One key serves every pipeline run in a bring-up.
   The key is deleted before destroy (step 6), so the GitHub secrets go
   dead; just overwrite them at the next bring-up (deleting them is
   optional tidiness). After the service is up, deploys go through the
   pipeline, not `image_tag`.
   **Confirm the SNS email** (Session 5): the apply sends an "AWS
   Notification - Subscription Confirmation" email to `alert_email`.
   Click the link in the newest one; until then alarms are silently
   dropped. Check with `aws sns get-topic-attributes --topic-arn <arn>`
   (`SubscriptionsConfirmed` = 1). The Budget emails directly and doesn't
   need this.
4. Seed (fresh DB each bring-up): `aws ecs run-task` with the
   `task_definition` output, the public subnets, the app SG,
   `assignPublicIp=ENABLED`, and a container override command
   `["npx","tsx","prisma/seed.ts"]`.
5. ECS Exec needs the Session Manager plugin
   (`brew install --cask session-manager-plugin`):
   `aws ecs execute-command --cluster meridian-poc --task <id> --container mcp-server --interactive --command "sh"`.
6. Teardown. First delete the CI key, or the destroy fails at the end
   on the IAM user with `DeleteConflict` (safe to re-run once it's gone):
   `aws iam list-access-keys --user-name meridian-poc-github-deploy --profile meridian`,
   then `aws iam delete-access-key --user-name meridian-poc-github-deploy --access-key-id <id> --profile meridian`.
   Then `terraform -chdir=envs/poc plan -destroy -out=destroy.tfplan`,
   review (an Opus moment), and `apply destroy.tfplan`: about 15
   minutes, mostly the VPC origin. Afterwards deregister the
   pipeline's task-definition revisions, which aren't in state:
   `aws ecs list-task-definitions --family-prefix meridian-poc-mcp-server --status ACTIVE`
   and `aws ecs deregister-task-definition` for each. Then read back that
   nothing is left (state empty; no RDS, ALB, ECS, ECR, secrets,
   CloudFront, VPC origin, non-default VPC, ENI, log group, or the CI
   user). `aws cloudfront list-distributions` needs `--no-paginate` when
   there are none, or the CLI prints nothing.

- Session 3b (branch `session-3b-cloudfront`, built 2026-10-08,
  verified 2026-11-02): `modules/edge` (CloudFront VPC origin +
  distribution; owns the ALB's only ingress rule, from the VPC origin's
  AWS-managed security group, looked up by name) and the Session 1
  80/443-from-anywhere ALB rules removed from `modules/network`.
  Decision 7 addendum.
  - **Account block history:** `CreateDistribution` returned 403 "Your
    account must be verified..." on 2026-10-08 and 2026-10-13 (even
    after Support case 179148119900306 was marked resolved). Cleared by
    2026-11-02, confirmed first with a disabled throwaway distribution
    made with the CLI (created, then deleted). That probe is the cheap
    way to test any future CloudFront account issue without a bring-up.
  - **Verified 2026-11-02** through `https://<id>.cloudfront.net`
    (image `e5cbf50`): `/health` 200; `tools/list` with no key lists
    all 8 tools; `tools/call list_active_incidents` with the agent key
    returns the seeded incident (CloudFront → VPC origin → internal ALB
    → Fargate → RDS). Negative checks: no key and wrong key on
    `tools/call` return HTTP 200 with `isError: true` / `UNAUTHORIZED`
    (the app has no 401, by design); plain `http://` gets 403 from
    CloudFront; the ALB name resolves only to `10.0.x.x` and times out
    from outside; the task's public IP on 3001 times out.
  - **Secrets race fix proven:** `secret_arns` in
    `modules/secrets/outputs.tf` `depends_on` the secret versions
    (added 2026-10-13 after a first task started before `database-url`
    had a value and the service got tainted). On the 2026-11-02 fresh
    apply the first task came up healthy and nothing was tainted. If a
    service ever shows as tainted but healthy, `terraform untaint` it.
  - **Known limit:** with the default `*.cloudfront.net` certificate the
    viewer TLS minimum is fixed at `TLSv1`; raising it needs option C
    (domain + ACM), which decision 7 ruled out for the POC.

- Session 4 (branch `session-4-github-actions`, verified 2026-11-03):
  `modules/ci` (IAM user `meridian-poc-github-deploy`, path `/ci/`, with
  a scoped inline policy; its key is created by hand each bring-up and
  deleted before destroy),
  `ignore_changes = [task_definition]` on the ECS service, and decision
  11. In the app repo: a multi-stage Node 24 image and
  `.github/workflows/deploy.yml` (`test` on every push/PR; `release`
  only from a manual dispatch on `main`, behind the `poc` environment's
  reviewer: ARM64 build, push tagged with the git short SHA, CRITICAL
  scan gate, new task-definition revision, wait for stability, optional
  `/health` check).
  - **OIDC is not possible on this account:** the free-plan SCP denies
    `iam:*Provider*` (even `ListOpenIDConnectProviders`). Hence the
    session-scoped IAM user key. If advanced features are ever
    activated, replace the user with an OIDC role.
  - **Verified 2026-11-03:** a pipeline deploy took the service from
    revision 5 (`0a88943`, pushed by hand) to revision 6 (`5efb174`,
    built by CI): one running task, ALB target healthy, `/health` 200 and
    a real `tools/call` through CloudFront, and `terraform plan` showing
    no changes (so `ignore_changes` works). The first dispatch failed in
    the scan gate (`aws ecr wait` fails on `ScanNotFoundException`
    right after a push); fixed by polling with `--no-paginate`.
  - Image scan: 0 critical / 5 high / 5 medium / 2 low, 180 MB
    compressed. The 5 HIGH findings are not triaged yet.
  - After a bring-up the service runs whatever the pipeline last
    deployed. `image_tag` only matters for the first image (the manual
    bootstrap push, since the pipeline can't create the first
    revision). Deploys need a new commit SHA on the app repo's `main`,
    because tags are immutable and an existing tag skips the build.

- Session 5 (branch `session-5-observability`, verified 2026-11-06):
  `modules/observability` gains an SNS topic `meridian-poc-alerts`
  (topic policy lets only CloudWatch publish, scoped by
  `aws:SourceAccount`) with an email subscription, seven alarms (ALB
  target 5xx, no healthy hosts, unhealthy hosts, ECS CPU and memory,
  RDS CPU, RDS free storage under 3 GiB), and a $10 monthly Budget
  (80% actual, 100% forecasted, emailed directly). New no-default
  variables `alert_email` and `monthly_budget_usd`; new outputs for the
  alarm dimensions in `compute` and `database`. Container Insights and
  CloudFront alarms skipped (cost; us-east-1 metrics).
  - **The Budget lives in `envs/poc`** and is destroyed with the stack, a
    deliberate call: spend is about $0 while destroyed. The free-plan SCP
    allows `CreateBudget`. Billing data lags 8–24 hours, so the Budget
    catches a stack left running, not a fast spike.
  - **Verified 2026-11-06:** `plan` clean after apply, all alarms `OK`,
    the usual CloudFront end-to-end and negative checks, all 8 tools, and
    `aws cloudwatch set-alarm-state` on `meridian-poc-alb-target-5xx`
    delivered an ALARM email, then an OK email on the next evaluation.
    Budget alert emails themselves are untested.
  - The AWS CLI on this machine lives in `~/.local/bin`, which a fresh
    Claude Code shell may not have on `PATH`.

## Next steps

1. ~~Session 1: Terraform foundations + decisions doc.~~ Done.
2. ~~Session 2: RDS Postgres + Secrets Manager.~~ Done.
3. Session 3, split in two (decided 2026-10-05):
   - ~~**3a:** ECR, ECS on Fargate (ARM64), IAM roles, internal ALB,
     log group, verified from inside the VPC.~~ Done 2026-10-05.
   - ~~**3b:** CloudFront with a VPC origin in front of the internal
     ALB for HTTPS, verified with a real MCP tool call end to end plus
     the negative checks.~~ Done 2026-11-02.
4. ~~Session 4: GitHub Actions — test → build → push to ECR → deploy,
   with a manual approval gate.~~ Done 2026-11-03.
5. ~~Session 5: CloudWatch logs/alarms + the Budget alarm.~~ Done
   2026-11-06.
6. Session 6: docs + wrap — architecture diagram, `docs/cost-notes.md`
   with actual observed spend vs. the original estimate, teardown/
   bring-up runbook, README tying back to the server repo's
   `docs/production-path.md`.

## AWS Agent Toolkit rules

AWS's starter rules for new-experience accounts, kept in their own file.
Where they conflict with this file, this file wins.

@.claude/aws-starter-rules.md