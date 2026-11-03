# AI-Assisted Delivery Log

Same model as the server repo's log: Claude Code drafts the Terraform,
docs and verification commands, while architecture calls, cost
trade-offs and every `apply`/`destroy` stay with me. This log makes that
split explicit for the infrastructure side.

**Tool:** Claude Code (CLI)
**Version control:** GitHub Desktop, one branch per session
**Model of engagement:** design walkthrough before any `.tf` is
written, then implement, `terraform plan` reviewed by me, apply, verify
against the real resources with read-only AWS CLI calls, then destroy.

## Guardrails on the AI side

- **`terraform apply` and `terraform destroy` always need my approval.**
  `.claude/settings.json` has "ask" rules, so Claude Code can write
  Terraform and run `plan` freely but has to stop and ask before
  changing real infrastructure. Applies use a saved plan file, so what
  gets applied is exactly the plan I reviewed.
- **Resources are only created through Terraform**, never directly
  through the AWS console or the AWS MCP tools. Anything created outside
  Terraform is invisible to `terraform destroy` and would keep billing
  between sessions.
- **No long-lived AWS keys.** The CLI signs in with `aws login` (browser,
  12-hour sessions).
- **Learning mode** (see CLAUDE.md): this is my first AWS project, so
  before each new resource Claude explains what the service is, its
  closest Azure equivalent and what's genuinely different, and walks
  through the actual resource blocks *before* writing them.

---

## What Claude Code generated

- [x] `.gitignore` (state, tfvars, plan files)
- [x] `docs/architecture.md`, the decisions doc, written before
      anything was provisioned
- [x] `modules/network/`: VPC, IGW, 2 public + 2 private subnets,
      route tables, 3 tiered security groups, locked default SG
- [x] `envs/poc/`: provider config, module wiring, tfvars example
- [x] Post-apply verification commands (security group rules, routes,
      subnets checked against AWS directly)
- [x] `modules/database/`: RDS Postgres 16 subnet group + instance,
      ephemeral master password via `password_wo`
- [x] `modules/secrets/`: 3 Secrets Manager secrets with write-only
      versions, generated MCP keys, replacement guard for `DATABASE_URL`
- [x] Secret-safe verification: checks each secret's format and that no
      secret value appears in the state file, without printing any value
- [x] `.dockerignore` for the app repo (kept `.env` out of the image
      before the first push to ECR)
- [x] `modules/compute/`: ECR repo + lifecycle policy, ECS cluster,
      ARM64 Fargate task definition and service, scoped execution and
      task IAM roles, internal ALB + target group + listener
- [x] `modules/observability/`: the app log group (alarms come in
      Session 5)
- [x] Decisions 7–10 in `docs/architecture.md`, and the bring-up
      runbook in CLAUDE.md
- [x] Verification from inside the VPC: a one-off seed task and an ECS
      Exec query through the app's own Prisma client
- [x] `modules/edge/`: CloudFront VPC origin, distribution and the ALB's
      only ingress rule
- [x] A CLI probe for the CloudFront account block (a disabled
      throwaway distribution, deleted after it was created), and the
      end-to-end and negative checks through the CloudFront URL
- [x] `modules/ci/`: the deploy IAM user and its scoped policy, plus
      `ignore_changes` on the ECS service's task definition, and
      decision 11
- [x] In the app repo: a multi-stage Node 24 Dockerfile (non-root,
      `openssl`, production dependencies only) and the GitHub Actions
      workflow (test, then build, scan gate and deploy behind an
      approval)
- [x] A live pipeline run, checked against ECS, ECR, the ALB target
      and CloudFront, plus a `plan` showing no drift afterwards

## What required architectural decisions

- **Fargate + ALB instead of App Runner.** App Runner turned out to be
  unsupported on my free-plan account, and unlocking it is irreversible
  and removes the spend cap. I chose to keep the cap and take the higher
  always-on cost, which barely matters since I destroy between sessions.
- **Tasks in public subnets with public IPs instead of a NAT Gateway**
  (~$33/mo) or VPC endpoints (~$58/mo). The security group is the
  control instead: tasks accept traffic only from the ALB's security
  group.
- **Security groups reference each other by ID** (ALB → app → db), so
  the database can never be opened to an IP range by accident.
- **Write-only secrets instead of passwords in state.** Ephemeral values
  plus `*_wo` arguments keep the DB password and MCP keys out of state
  entirely. I accepted that Terraform can't detect drift on them, and
  that rotation means bumping a version number.
- **Terraform generates the MCP keys** rather than me supplying them, so
  no human ever sees or types a key.
- **The end-to-end `psql` check moves to Session 3.** RDS is private and
  there's no compute yet. Opening a temporary public path just to tick
  the box would undo decision 3.
- **HTTPS via CloudFront with a VPC origin, no custom domain.** This is
  a POC, so I'm not buying a domain, which rules out ACM on the ALB.
  CloudFront in front of a *public* ALB would still send the API key
  over plain HTTP between CloudFront and the ALB, so the ALB is internal
  and CloudFront reaches it over AWS's network.
- **Session 3 split into 3a (compute, verified from inside the VPC) and
  3b (CloudFront, verified end to end)**, so a failure points at one
  layer.
- **No temporary public path in 3a.** When I asked how I'd ever show an
  internal-only service publicly, the answer was 3b's CloudFront, not
  opening the ALB for a session and closing it again. So 3a checks
  ALB → app by target health rather than an HTTP call from my laptop.
- **ARM64 Fargate** to match images built on my Mac (and ~20% cheaper),
  rather than cross-building x86 under emulation.
- **Scoped IAM instead of `AmazonECSTaskExecutionRolePolicy`.** The
  managed policy allows pulling from any repository and writing to any
  log group. The inline one names this repository, this log group and
  the three secret ARNs.
- **A session-scoped IAM user key instead of GitHub OIDC.** The free
  plan's SCP denies `iam:*Provider*`, so OIDC can't be created. I chose
  an IAM user with a narrow deploy policy whose access key is made by
  hand at bring-up and deleted with the stack, over AWS-native CI
  (a bigger session, not GitHub Actions) or activating advanced
  features (loses the spend cap). Decision 11.
- **One gated `release` job.** I chose a single approval per run over
  two environments with two users. The build job and deploy job
  couldn't share one approval, so build, scan and deploy are one job.
- **CI owns the running task definition.** `ignore_changes` on the
  service means a pipeline deploy isn't rolled back by the next apply.
  The cost is that `image_tag` only sets the first image.
- **Node 24, not 26.** Node 26 only became LTS on 2026-10-28; 24 is the
  mature LTS and the safer fit for Prisma 6 and vitest 2.
- **Fail the pipeline on CRITICAL scan findings, not HIGH.** The new
  image has 5 HIGH that I haven't triaged; blocking on them would
  stop every deploy until I do.

## What got caught and corrected

- **The original design assumed App Runner was available.** CLAUDE.md
  was written around it, and Claude's first design walkthrough built on
  it too. Claude did flag "check App Runner is still accepting
  customers" as a risk. Once I'd signed in, it checked my account's
  plan (`aws freetier get-account-plan-state`) against AWS's
  supported-services list and found App Runner on the unsupported list.
  This was caught before a single `.tf` file existed. Lesson: check the
  account's real constraints before designing around a service, not
  after.
- **A cost estimate was low.** The first Fargate + ALB estimate
  (~$0.04/hr) left out public IPv4 charges for the ALB's two addresses.
  Claude corrected it to ~$0.05/hr itself when writing the decisions
  doc.
- **Plan output that can't be trusted until apply.** The plan showed
  security group rule lists as "known after apply", so whether AWS's
  default allow-all outbound rule really got removed couldn't be seen
  in the plan. Checked after apply with `describe-security-group-rules`:
  exactly the 7 designed rules, and no outbound rule at all on the
  database security group.
- **A silent password mismatch on RDS replacement.** While designing the
  write-only flow, Claude spotted that replacing the RDS instance would
  send it a fresh ephemeral password, but the `DATABASE_URL` secret
  wouldn't be rewritten, because its version number hadn't changed. The
  fix was a `terraform_data` tracking the instance's `resource_id`, with
  `replace_triggered_by` on the secret version.
- **`for_each` over an ephemeral resource.** Claude's first draft of the
  secrets module looped over the ephemeral `random_password` itself.
  Ephemeral values can't drive `for_each`, so Claude rewrote it to loop
  over a static set of names before running `validate`.
- **The docs were stale after the design changed.** Decision 4 and the
  `.gitignore` comment both said state holds the DB password. Both were
  rewritten once write-only secrets made that false.
- **The app image would have shipped my local `.env`.** The app repo had
  no `.dockerignore`, so the Dockerfile's `COPY . .` included `.env`.
  Harmless on Render, which builds from git, but not when pushing an
  image from my laptop. Claude caught it while reading the Dockerfile
  during planning. It was fixed and merged in the app repo before
  anything was pushed, and checked by looking inside a local build.
- **The first push was an image index, not an image.** Claude's first
  `docker build` used Docker Desktop's defaults, which add a provenance
  attestation and push an OCI index. ECR's scan showed nothing, and the
  untagged image under the tag would have been a target for the
  "expire untagged" lifecycle rule. Claude spotted it while verifying
  the push. It deleted those three digests (the tag is immutable),
  rebuilt with `--provenance=false --sbom=false`, and added the flags
  to the runbook.
- **A comment claimed more than the docs say.** The first draft of the
  IAM trust policy comment stated how ECS fills in `aws:SourceArn`.
  Claude couldn't back that up, so the comment was rewritten to say
  only what AWS's ECS docs say: scope to account and Region.
- **Shell slips during verification.** Twice a multi-word command or
  list was stored in a zsh variable, and zsh doesn't split variables
  into words. One delete call sent three digests as a single invalid ID
  (it failed safely, with nothing deleted), and one batch of read-only
  checks didn't run. Fixed with environment variables and a proper
  array.
- **The image scan surfaced a real problem.** ECR's basic scan of the
  first image found 7 critical and 33 high findings. All of them were
  Debian OS packages in `node:20-slim`, and Node 20 has been past
  end-of-life since April 2026. Logged as an app-repo follow-up rather
  than patched mid-session.
- **OIDC was blocked, and the design assumed it.** Claude's walkthrough
  planned GitHub OIDC. Before any Terraform was written it checked the
  live account: even `ListOpenIDConnectProviders` returned an explicit
  SCP deny, and the SCP text confirmed `iam:*Provider*` is denied.
  `terraform plan` can't see an SCP, so this would only have shown up
  at apply.
- **The "one approval" design was wrong about GitHub.** The walkthrough
  said one approval would cover both the build and deploy jobs. GitHub
  asks once per job that uses a protected environment, so the gate would
  have fired before the build and again before the deploy. Claude
  caught it while writing the workflow, merged the work into one job,
  and corrected decision 11.
- **Annotated tags pinned to the wrong SHA.** Three actions' tags are
  annotated, and the first lookup returned the tag object's SHA, not the
  commit's, which `uses:` rejects. Claude resolved them with the `^{}`
  dereference instead.
- **The scan gate failed on its first real run.** `aws ecr wait
  image-scan-complete` fails with `ScanNotFoundException` right after a
  push, because ECR creates the scan record a few seconds later. Nothing
  was deployed: the step failed before the task definition was touched.
  Claude replaced the waiter with a polling loop. Running the real step
  script against live ECR then exposed a second bug: the CLI's
  auto-pagination crashes ("'NoneType' object does not support item
  assignment") while a scan is `IN_PROGRESS`. Fixed with `--no-paginate`.
  Neither bug was visible to the linter; the script was retested on an
  in-progress image, a completed one and a missing tag.
- **An empty `--user-name`.** `create-access-key` failed with "Parameter
  validation failed" when I ran it before the stack existed:
  `terraform output` printed nothing, so the name was empty. Claude
  diagnosed it from empty state; the runbook now uses the literal name.
- **`force_destroy` collided with the SCP.** I'd set
  `force_destroy = true` on the CI user so destroy would remove the
  hand-made key. On teardown it deleted the key and the policy, then
  failed on the user: the provider also calls `DeleteLoginProfile`, and
  the SCP denies `iam:*LoginProfile*`, in the same statement Claude had
  read for OIDC that morning. Claude had checked the actions the module
  creates, not the ones the provider calls on the way out. The leftover
  user had no keys and no policies, so it could do nothing. Fixed with
  `force_destroy = false` and a runbook step to delete the key before
  destroy, then proven by destroying the leftover user that way (decision
  11).
- **More zsh word-splitting.** Three more commands stored in a string
  variable didn't split: a `docker run` whose environment flags were
  one argument, a block of `aws` calls, and a `git ls-remote` loop. The
  container failed at boot, and the other two failed at parsing; no
  ECS task was launched and nothing was changed. Fixed with a wrapper
  function and explicit arguments.

---

## Engagement log

### 2026-10-02: Session 1, foundations

**Setup.** Installed the AWS CLI and signed in through AWS's Agent
Toolkit setup (`aws login`, profile `meridian`). Also installed
Terraform 1.16. Before anything else I asked Claude whether it should
create resources directly in AWS or whether I should click through the
console. We settled on neither: Claude writes Terraform and runs `plan`,
I approve every `apply`/`destroy`, and that approval is now enforced in
`.claude/settings.json` rather than left to habit.

**The App Runner pivot.** The account check turned up a new-experience
project, on the free plan, locked to `us-east-2`, with App Runner
unsupported. Claude laid out three options: upgrade and keep App Runner,
switch to Fargate + ALB, or use Lambda. I chose Fargate + ALB to keep
the free plan's spend cap. CLAUDE.md's conventions were rewritten to
match so future sessions don't argue for App Runner again. Lambda was
out because it would mean changing the app, not just the
infrastructure.

**Built.** After a design walkthrough, Claude wrote the network module.
`fmt`, `validate` and `plan` were clean: 23 resources, $0. I reviewed
the plan, then applied it.

**Verified for real**, not just "apply exited 0":

- the 7 security group rules exactly match the design, and the database
  security group has no outbound rules,
- the default security group has 0 rules,
- all 4 subnets have auto-assigned public IPs off,
- only the public route table routes to the IGW,
- a fresh `plan` reports no drift.

**Torn down** with `terraform destroy` at the end of the session,
following the destroy-between-sessions convention, even though this
layer costs nothing. That also proves the teardown works from day one.

### 2026-10-03: Session 2, RDS + Secrets Manager

**Design.** The walkthrough happened the evening before. I paused
overnight with two decisions open and answered them today: write-only
secrets, and Terraform-generated MCP keys. I also agreed to defer the
`psql` connection test to Session 3.

**Built.** `modules/database` and `modules/secrets`, wired together in
`envs/poc`. `DATABASE_URL` is built in the root module from the
database outputs plus the ephemeral password. The plan was 32 resources
(the network rebuilt, plus 2 database and 7 secrets resources), with
every secret argument shown only as `(write-only attribute)`. I
reviewed it and applied it; RDS took most of the time.

**Verified for real:**

- RDS is `available` on `db.t4g.micro` / Postgres 16.13,
  `PubliclyAccessible=false`, encrypted gp3, in the two private
  subnets, with only the db security group attached,
- the db security group's only inbound rule is 5432 from the app
  security group, with no CIDR,
- the private route table has only the `local` route, so there is no
  path to the internet,
- `rds.force_ssl = 1`, which matches `sslmode=require` in the URL,
- `DATABASE_URL` matches the expected format and host, and both MCP
  keys are 48-character alphanumeric strings. Checked by pattern
  without printing any value,
- none of the three secret values appear anywhere in
  `terraform.tfstate`,
- a second `plan` reports no changes, so the ephemeral values don't
  cause drift.

Not yet verified: a real connection to the database. That needs
compute inside the VPC and is owed in Session 3.

**Torn down** with `terraform destroy`: 32 resources. Afterwards I
checked that no RDS instances, snapshots, secrets (including any
scheduled for deletion) or non-default VPCs were left, and that state
was empty.

### 2026-10-05: Session 3a, ECR + ECS Fargate + internal ALB

**Design.** I picked HTTPS option A (CloudFront with a VPC origin). I'm
not buying a domain for a POC, so option C was out. I also split
Session 3 in two. Before writing anything, Claude checked the free
plan: everything needed is on the supported list, and the free plan's
service control policy allows `cloudfront:*`, `ssm:*` and
`ssmmessages:*`. My live account check showed the free plan active,
with $119.99 in credits.

**Built.** ECR was applied first with `-target`, then the image
(`e5cbf50`, arm64) was pushed. The full plan was 43 resources (Sessions
1–2 re-created, plus 11 new). I reviewed it and applied it. The apply
only completed once the service was healthy.

**Verified for real:**

- the service runs 1 of 1 tasks, the rollout is `COMPLETED`, and ECS
  Exec is enabled,
- the target `10.0.0.189:3001` is `healthy` in the target group, which
  proves ALB → app works through the security groups,
- the ALB's scheme is `internal`,
- CloudWatch shows `prisma migrate deploy` applying
  `20260901194204_init` to RDS, and the app logs are JSON
  (`NODE_ENV=production`),
- a one-off seed task exited 0: 20 accounts, 60 tickets, 1 incident,
- through ECS Exec, a read-only query using the app's own Prisma client
  returned `db_user=meridian`, `server_ip=10.0.10.57` (private subnet),
  Postgres 16.13, `ssl=true`, and counts matching the seed. This pays
  off the DB connection test owed since Session 2.

Not yet verified: a real HTTPS MCP request from outside AWS. That comes
in 3b, with CloudFront.

**Process note.** Verification went beyond read-only calls this time:
the seed task (`run-task`) and the cleanup of the bad image push
(`batch-delete-image`) both changed things in AWS. Both were one-off
operations, not resources, so Terraform's view of the stack isn't
affected.

**Torn down** from a saved `plan -destroy`: 45 resources, including the
ECR repository with its image. Afterwards I checked that state was
empty and that no ECS clusters, load balancers, target groups, RDS
instances or manual snapshots, ECR repositories, secrets (including any
scheduled for deletion), non-default VPCs, unattached network
interfaces, app log groups, `meridian-poc` IAM roles or Elastic IPs
were left.

### 2026-10-08: Session 3b, CloudFront in front of the ALB (blocked)

**Design.** Claude read the CloudFront VPC origin docs and the app's
`src/server.ts` before proposing anything, and the app code changed my
plan: the `x-api-key` check is inside each tool handler, so a missing or
wrong key is HTTP 200 with `isError: true`, not a 401, and `tools/list`
needs no key. The negative checks were rewritten to match. I approved
two decisions: the ALB admits only the VPC origin's AWS-managed security
group (not CloudFront's managed prefix list, which would admit any
distribution), and a new `modules/edge` owns that ingress rule, to avoid
a network → compute → network dependency cycle.

**Built.** `modules/edge` (VPC origin, security group lookup, ingress
rule, distribution), removal of the 80/443-from-anywhere ALB rules from
`modules/network`, wiring and a `cloudfront_url` output in `envs/poc`.
`terraform validate` and `fmt` passed.

**Models.** Opus 5.5 did the design walkthrough and wrote the modules.
I then switched to Sonnet 5.5 (per the model-usage rules) for bring-up,
the image-push debugging, plan review and the destroy. Claude
recommended switching back to Opus for a review before `terraform
destroy`; I chose to go ahead on Sonnet. The destroy plan was reviewed
(45 resources, all this project's) and the stack holds only seed data.

**Verified for real, and what was not:**

- full plan: 44 to add, 0 to change, 0 to destroy; reviewed the ALB
  ingress rule (SG reference, no CIDR), the distribution settings and
  the VPC origin config before applying,
- 43 of 44 resources applied, including the VPC origin (8m14s), the
  security group lookup (one match) and the ingress rule, and the ECS
  service came up healthy,
- `CreateDistribution` failed with 403 "Your account must be verified
  before you can add new CloudFront resources" (RequestID
  `6b8ffae6-3974-4fc8-aa41-22c6e8a88351`); `get-account-plan-state`
  showed FREE/ACTIVE with $119.88 credits left, so it isn't the spend
  limit.

Not verified: the CloudFront URL, an MCP tool call through it, and all
the negative checks. Session 3b is not done.

**What went wrong, and what was caught:**

- My pre-check covered the supported-services list and the service
  control policy but not account verification, which is a separate gate.
  Claude's plan flagged the Access Denied risk but attributed it to the
  spend-limit policy.
- `docker push` timed out ("timeout awaiting response headers") on
  large layers of the 554MB `npm install` image, on a different layer
  each run, including from my own terminal. `docker buildx build
  --output type=image,...,push=true` succeeded in 6m52s. That points at
  Docker Desktop's containerd pusher, though I didn't isolate it from a
  slow upload link. The image is that large because `npm install`
  includes dev dependencies, which joins the app-repo follow-ups.
- Claude's first build command mis-tagged the image (`$REPO:e5cbf50` is
  a zsh modifier), which showed up as a failed push to a repo that did
  exist. Fixed with `${REPO}:${SHA}` and the bad local tag removed.

**Support.** I opened an AWS Support case with the error and RequestID
and am waiting on it. Option B would hit the same block; option C
(domain + ACM, no CloudFront) is the only alternative and decision 7
ruled it out for a POC.

**Torn down** from a saved `plan -destroy`: 45 resources, including the
ECR repository and image, so the next bring-up needs the image pushed
again. The VPC origin took 7m8s to delete. Afterwards I checked that
state was empty and that no RDS instances or manual snapshots, load
balancers or target groups, ECS clusters, ECR repositories, secrets
(including any scheduled for deletion), non-default VPCs or security
groups (so AWS's managed `CloudFront-VPCOrigins-Service-SG` was cleaned
up with the origin and didn't block the VPC delete), network interfaces,
Elastic IPs or app log groups were left. Doing this check, my first
attempt used a zsh variable for the CLI flags, which didn't word-split
and made every command error; I caught it because the outputs were
empty, not zero, and reran it.

### 2026-10-13: Session 3b retry, still blocked, plus a secrets race

**Retry.** AWS Support replied at 10:31 UTC that the account was
verified for CloudFront. I re-ran the bring-up runbook from an empty
state: ECR only, the ARM64 image from the app repo's `main` (`200056b`,
docs-only change since `e5cbf50`, pushed with `buildx` in ~8 minutes),
then the full plan (44 to add, 0 to change, 0 to destroy) and apply.

**Models.** Opus 5.5 read CLAUDE.md and planned the session. Claude
recommended Sonnet for the rest, since it was a runbook re-run on
reviewed code; I switched and stayed on Sonnet through the destroy.

**Verified for real, and what was not:**

- VPC origin (8m12s), security group lookup and ALB ingress rule
  applied again,
- the ECS service reached steady state with the target registered;
  the app logs showed `prisma migrate deploy` applying the migration
  and the server listening on 3001,
- `CreateDistribution` returned the same 403 three times, twice after
  Support's message (RequestIDs `044506f2-e583-4dcf-a60c-410a75a93512`
  and `cf36ba35-4ed6-44b7-abec-b02d9e1901b6`). Verification has not
  taken effect for this account. I opened a new case that cites the
  first one.

Not verified: the CloudFront URL, an MCP tool call, the negative
checks. Session 3b is still not done. I skipped the seed task and the
partial negative checks and destroyed (45 resources, all this project's;
a read-back found no RDS, ALB, VPC, VPC origin or secrets left).

**What went wrong, and what was caught:**

- The first apply failed twice over. Besides the CloudFront 403, the
  ECS service errored with "No rollback candidate" because its first
  task started before the `database-url` secret had a value
  (`can't find the specified secret value for staging label:
  AWSCURRENT`). ECS retried and the second task was healthy, but
  Terraform had already marked the service failed and tainted it. This
  ordering gap existed in 3a and didn't surface there, so it was luck,
  not design. Fix: `secret_arns` in `modules/secrets/outputs.tf` now
  `depends_on` the secret versions, so the compute module waits for the
  values. I could not reproduce the race on demand, so the fix is
  validated but not proven.
- I untainted the healthy service so the next plan was one resource
  (the distribution) instead of destroying and recreating the service.
- The first pair of diagnostic commands failed on my shell, not on AWS:
  a `$P` variable holding `--profile ... --region ...` isn't split in
  zsh, and I used the wrong log group name (`/ecs/meridian-poc/mcp-server`,
  not `meridian-poc/app`).

### 2026-11-02: Session 3b done, CloudFront unblocked and verified

**Probe first.** AWS Support told me CloudFront was unblocked. Since a
"resolved" case had still left me blocked on 2026-10-13, I didn't
stand up the stack to find out. Claude created a *disabled* throwaway
distribution with the CLI against `example.com`. `CreateDistribution`
succeeded (the same call that had returned 403 twice). Claude waited
for it to finish deploying, deleted it, and confirmed the account had
no distributions left. Plan still FREE/ACTIVE, $119.82 credits.

**Bring-up.** Image `e5cbf50`, my choice, so this run differed from
3a only in the CloudFront change. `main` was at `200056b`, which Claude
checked is docs-only on top of it. Claude built from a `git archive`
export of that commit, so the app repo's checkout was untouched. ECR
first (2 to add), `buildx` push, then the full plan: 44 to add, 0 to
change, 0 to destroy. Claude reviewed the plan for RDS
`publicly_accessible = false` and encryption, `internal = true` on the
ALB, `https-only` viewers, and SG references on every ingress rule (the
only `0.0.0.0/0` is the app's outbound 443). I approved the bring-up
at the step level rather than reading each plan myself. Apply times:
RDS 8m32s, VPC origin 8m11s, distribution 2m43s. The seed task wrote
20 accounts, 60 tickets and 1 incident.

**Models.** Opus 5.5 ran the whole session. The runbook re-run and
checks are Sonnet work under the model rules, and Claude only flagged
this at the start, not when the bring-up began; I stayed on Opus. The
pre-destroy review is Opus work under the same rules.

**Verified for real**, through `https://d1g7kfmcvp4vw.cloudfront.net`:

- `/health` returned 200,
- `tools/list` with no key listed all 8 tools,
- `tools/call list_active_incidents` with the agent key (read from
  Secrets Manager into a shell variable, never printed) returned the
  seeded SEV2 incident: CloudFront → VPC origin → internal ALB →
  Fargate → RDS, end to end,
- no key and wrong key on `tools/call`: HTTP 200, `isError: true`,
  `UNAUTHORIZED`, as the app is designed to do,
- plain `http://` got 403 from CloudFront, no redirect,
- the ALB name resolved only to `10.0.10.198` / `10.0.11.134` and timed
  out from my laptop,
- the task's public IP on 3001 timed out.

Session 3b is done.

**What went wrong, and what was caught:**

- The 2026-10-13 secrets-race fix is now proven: on a fresh apply the
  first task came up healthy and a follow-up plan showed no changes
  and nothing tainted.
- Claude's first probe command failed because `aws` isn't on the
  shell's PATH (it's in `~/.local/bin`), and the second because its
  scratch directory didn't exist yet. Nothing was created by either.
- My `terraform.tfvars` still held `image_tag = "200056b"` from the
  last retry; Claude caught that before planning and set it to
  `e5cbf50`.
- Plan review flagged one known limit, not a regression: with the
  default `*.cloudfront.net` certificate the viewer TLS minimum is
  fixed at `TLSv1`. Raising it needs option C (domain + ACM).
- Prisma's OpenSSL warning is still in the logs, including the seed
  task. Still an app-repo follow-up.

**Torn down** from a saved `plan -destroy` that Claude reviewed before I
approved it: 46 resources (the 44 plus the two ECR resources), all in
this project's modules. Distribution 3m48s, RDS 1m51s, VPC origin
8m36s. Afterwards state was empty, and a read-back found no RDS
instances or manual snapshots, load balancers, target groups, ECS
clusters, ECR repositories, secrets (including scheduled deletions),
CloudFront distributions or VPC origins, non-default VPCs, Elastic IPs,
network interfaces or app log groups.

### 2026-11-03: Session 4, GitHub Actions pipeline

**Design first, and an assumption that failed.** Opus 5.5 did the design
walkthrough, as the model rules say for IAM shape decisions. It read both
repos first: the app repo had no CI at all, tests need a real Postgres,
and `prisma` and `tsx` are dev dependencies that production uses (boot
migration, seed). I chose one approval gate and moving `tsx` into
`dependencies`. Before writing any Terraform, Claude checked the plan's
OIDC assumption against the live account and found the SCP deny on IAM
providers. I chose option A, a session-scoped IAM user key (decision 11).

**Models.** Opus 5.5 through writing `modules/ci`; I then switched to
Sonnet 5.5 for the docs, the app-repo work, the bring-up and the
verification, then back to Opus 5.5 for the pre-destroy review and the
`force_destroy` fix, as the model rules say for anything hard to undo.

**Built, infra repo.** `modules/ci`: the user `meridian-poc-github-deploy`
(path `/ci/`) with a six-statement inline policy. ECR
push and scan-read are on the one repository, `UpdateService` is on the
one service, `PassRole` is limited to the two task roles with
`iam:PassedToService`, and the only `*` resources are the three actions
AWS can't scope. No `aws_iam_access_key` resource, since it would write
the secret into state. Policy ARNs are built from `name_prefix` so the
`-target` ECR bootstrap doesn't drag the stack in. `ignore_changes` on
the service's task definition. Decision 11 and a runbook step for the
key.

**Built, app repo.** Multi-stage `node:24-slim` image. Built locally and
run against a throwaway Postgres 16 before the workflow existed:
migration applied on boot, `/health` 200, the seed wrote 20 / 60 / 1, the
container runs as `node`, vitest is absent. The workflow runs `test` on
every push and PR, and `release` only from a manual dispatch on `main`,
behind the `poc` environment: ARM64 build on a native runner, push tagged
with the git short SHA, scan gate, new task-definition revision, wait for
stability, optional `/health` check. Actions pinned to commit SHAs,
actionlint clean. The PR's `test` job passed on GitHub's runners.

**Bring-up.** I set `image_tag` to the merged `main` SHA `0a88943`.
Claude built from a `git archive` of that commit, ECR first (2 to add),
`buildx` push, then the full plan: 46 to add, 0 to change, 0 to destroy.
Claude checked the CI policy statement by statement and that no
credential value appears anywhere in the plan; the task definition's
image tag couldn't be checked in the plan because the container
definitions embed secret ARNs not yet known. I approved the apply. The
service came up healthy on task definition revision 5, and the seed
task wrote 20 accounts, 60 tickets and 1 incident. I created the CI key
in a separate terminal, so it never entered the conversation, and added
it as the `poc` environment's two secrets.

**Image scan.** The new image scanned at 0 critical, 5 high, 5 medium,
2 low, against 7 critical and 33 high for the Node 20 image, and is 180
MB compressed against about 299 MB. Prisma's OpenSSL warning no longer
appears in any task log on the live stack (two service tasks and the
seed).

**The pipeline, run twice.** First dispatch (`3b57c48`, a docs commit):
build and push worked, the scan gate failed as described above, nothing
deployed. I fixed it on a branch, PR #3 passed its test job, and merged
it. Second dispatch (`5efb174`) built and pushed a fresh image, passed
the gate, and deployed. The IAM policy needed no changes on its first
real use.

**Verified for real**, against AWS after the run rather than from the
green tick:

- the service was on revision 6 with image `5efb174`, one running task,
  one `COMPLETED` deployment, and the ALB target healthy,
- `/health` returned 200 through CloudFront, and `tools/call
  list_active_incidents` with the agent key still returned the seeded
  incident (the database was untouched by the deploy),
- a wrong key got `UNAUTHORIZED`,
- the new task's log showed "No pending migrations to apply",
- `terraform plan -detailed-exitcode` exited 0, "No changes", with the
  service on a revision Terraform didn't create. That is
  `ignore_changes` working.

Earlier in the session the 3b negative checks were re-run on the fresh
stack: plain `http://` got 403, the ALB resolved only to `10.0.x.x` and
timed out from outside, and the task's public IP on 3001 timed out.

**Still open.** The 5 HIGH scan findings aren't triaged. The pipeline's
`test` and `release` jobs both ran only on this one stack; nothing has
tested a rollback of a bad image yet, though the circuit breaker is on.

**Torn down** from a saved `plan -destroy` that Claude reviewed on Opus
before I approved it: 48 to destroy (the 46 plus the two ECR resources),
all in this project's modules, with RDS skipping its final snapshot and
the secrets on a zero-day recovery window. Distribution 3m17s, service
3m32s, RDS 2m52s, VPC origin 6m56s. 47 of 48 went; the CI user failed
on the SCP, as described above. Claude then set `force_destroy = false`,
applied that as a state-only change (plan: one in-place update, nothing
else), and destroyed the user from a targeted plan. That called only
`DeleteUser` and succeeded. Claude also deregistered task-definition
revision 6, which the pipeline had registered outside state. Afterwards
state was empty, and a read-back found no RDS instances or manual
snapshots, load balancers, target groups, ECS clusters or active task
definitions, ECR repositories, secrets (including scheduled deletions),
CloudFront distributions or VPC origins, non-default VPCs, Elastic IPs,
network interfaces, app log groups, `meridian-poc-*` roles, or the CI
user. I removed the two GitHub environment secrets, which were dead
once the key was deleted.
