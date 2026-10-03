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

**Built.** After a design walkthrough in learning mode (VPC ≈ VNet but
AWS subnets sit in a single AZ; no internet path until you add an IGW
and route, unlike Azure's built-in system routes; security groups ≈
NSGs but allow-only, stateful, attached to network interfaces, and able
to reference each other like ASGs), Claude wrote the network module.
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
