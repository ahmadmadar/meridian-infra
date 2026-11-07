# Runbook: bring-up and teardown

How to bring the stack up, check it, and tear it down. The stack is
destroyed between sessions (decision 5), so this gets run every time.
A full cycle is about 25 to 30 minutes up and about 15 down.

**You need:** a live `aws login --profile meridian`, Docker running, and
`envs/poc/terraform.tfvars` (copy `terraform.tfvars.example` and fill it
in: `region`, `aws_profile`, `image_tag`, `alert_email`,
`monthly_budget_usd`). `image_tag` is the app repo's git short SHA. The
file is gitignored.

If `aws` isn't found in a non-interactive shell, the CLI lives at
`~/.local/bin/aws`.

## Bring-up

1. **ECR first** (decision 9):

   ```sh
   terraform -chdir=envs/poc plan \
     -target=module.compute.aws_ecr_repository.app \
     -target=module.compute.aws_ecr_lifecycle_policy.app -out=tfplan
   terraform -chdir=envs/poc apply tfplan
   ```

   Review the plan before applying. It should be two resources.

2. **Push the bootstrap image** from the app repo's `main` (tags are
   immutable). This manual push is only the bootstrap: the service needs
   a healthy image before the first full apply can finish, and the
   pipeline can't create it. After that, deploys go through the
   pipeline.

   ```sh
   aws ecr get-login-password --profile meridian --region us-east-2 \
     | docker login --username AWS --password-stdin <account>.dkr.ecr.us-east-2.amazonaws.com
   docker buildx build --platform linux/arm64 --provenance=false --sbom=false \
     --output "type=image,name=<repo_url>:<sha>,push=true" .
   ```

   - Without the two flags, Docker Desktop pushes an image index that the
     scan and the lifecycle rule mishandle.
   - Use `buildx` rather than `docker push`. On Docker Desktop's
     containerd image store, `docker push` timed out ("timeout awaiting
     response headers") on the large layers, on different layers each
     run. The `buildx` push succeeded in about 7 minutes (~299 MB
     compressed).
   - In zsh write `"${REPO}:${SHA}"`. `$REPO:e...` is read as a modifier
     and silently mis-tags the image.
   - To build an older commit without touching the app repo's checkout:
     `git archive <sha> | tar -x -C <dir>` and build from there.
   - Wait for the push to finish before step 3. An apply with no image in
     ECR starts a service that can't pull, and the service ends up
     tainted. Check with
     `aws ecr describe-images --repository-name meridian-poc/mcp-server`.

3. **Everything else:**

   ```sh
   terraform -chdir=envs/poc plan -out=tfplan
   terraform -chdir=envs/poc apply tfplan
   ```

   Review the plan first. Expect 25 to 30 minutes with CloudFront: RDS
   about 10, the VPC origin about 8 (and about as long to delete), and
   the distribution a few more. The apply waits for the service to be
   healthy. Run it in the background or a separate terminal, as the
   10-minute tool timeout is shorter than the apply.

   If the service ever shows as tainted but healthy, `terraform untaint`
   it.

4. **Confirm the SNS email.** The apply sends "AWS Notification -
   Subscription Confirmation" to `alert_email`. Click the link in the
   **newest** one; until you do, alarms are silently dropped. Check:

   ```sh
   aws sns get-topic-attributes --profile meridian --region us-east-2 \
     --topic-arn <arn> --query 'Attributes.[SubscriptionsConfirmed,SubscriptionsPending]'
   ```

   You want `1  0`. The Budget emails directly and doesn't need this.

5. **CI deploy key** (decision 11, only if the app repo's pipeline will
   run this session):

   ```sh
   aws iam create-access-key --profile meridian \
     --user-name "$(terraform -chdir=envs/poc output -raw ci_user_name)"
   ```

   Put `AccessKeyId` and `SecretAccessKey` in the app repo's `poc`
   environment secrets (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`).
   Run it in a separate terminal, not through Claude Code (which would
   put the secret in the transcript), and never save the output to a file
   or commit it. One key serves every pipeline run in a bring-up. The
   key is deleted before destroy (see Teardown), so the GitHub secrets go
   dead; overwrite them at the next bring-up. After the service is up,
   deploys go through the pipeline, not `image_tag`.

6. **Seed the database** (fresh DB each bring-up): `aws ecs run-task`
   with the `task_definition` output, the public subnets, the app
   security group, `assignPublicIp=ENABLED`, and a container override
   command `["npx","tsx","prisma/seed.ts"]`. It should write 20 accounts,
   60 tickets and 1 incident.

7. **Optional, ECS Exec** into a running task (needs the Session Manager
   plugin, `brew install --cask session-manager-plugin`):

   ```sh
   aws ecs execute-command --cluster meridian-poc --task <id> \
     --container mcp-server --interactive --command "sh"
   ```

## Verify it is really up

`apply` exiting 0 is not the check. Verify against AWS and the live
endpoint:

- `terraform plan` shows no changes (exit code 0 with `-detailed-exitcode`).
- The service is 1 running of 1 desired, with a `COMPLETED` rollout, and
  the ALB target is healthy.
- Through `https://<id>.cloudfront.net` (the `cloudfront_url` output):
  `/health` returns 200; `tools/list` returns all 8 tools; `tools/call
  list_active_incidents` with the agent key returns the seeded incident.
- Negative checks: a wrong key on `tools/call` returns HTTP 200 with
  `isError: true` and `UNAUTHORIZED` (the app has no 401, by design);
  plain `http://` gets 403 from CloudFront; the ALB name resolves only to
  `10.0.x.x` and times out from outside; the task's public IP on 3001
  times out.
- All 7 alarms are `OK`, the Budget exists, and the SNS subscription is
  confirmed.
- To prove alarm delivery, force one alarm and watch for the email, then
  for the OK email on the next evaluation:

  ```sh
  aws cloudwatch set-alarm-state --profile meridian --region us-east-2 \
    --alarm-name meridian-poc-alb-target-5xx --state-value ALARM \
    --state-reason "delivery test"
  ```

## Teardown

1. **Delete the CI key first**, or the destroy fails at the very end on
   the IAM user with `DeleteConflict` (safe to re-run once it's gone):

   ```sh
   aws iam list-access-keys --user-name meridian-poc-github-deploy --profile meridian
   aws iam delete-access-key --user-name meridian-poc-github-deploy \
     --access-key-id <id> --profile meridian
   ```

   If no key was created this bring-up, the list is empty and there is
   nothing to do.

2. **Plan and review the destroy.** This is an Opus moment in the model
   rules, since a destroy removes a live database:

   ```sh
   terraform -chdir=envs/poc plan -destroy -out=destroy.tfplan
   ```

   The count should match what was created, and every resource should be
   in this project's modules. RDS skips its final snapshot and the
   secrets use a zero-day recovery window by design.

3. **Apply it:** `terraform -chdir=envs/poc apply destroy.tfplan`. About
   15 minutes, mostly the VPC origin.

4. **Deregister the pipeline's task-definition revisions**, which aren't
   in state:

   ```sh
   aws ecs list-task-definitions --family-prefix meridian-poc-mcp-server --status ACTIVE
   aws ecs deregister-task-definition --task-definition <family:revision>
   ```

5. **Read back that nothing is left.** State is empty, and AWS shows no
   RDS instances or manual snapshots, load balancers, target groups, ECS
   clusters or active task definitions, ECR repositories, secrets
   (including scheduled deletions, `--include-planned-deletion`),
   CloudFront distributions or VPC origins, non-default VPCs, Elastic
   IPs, network interfaces, `/ecs/meridian-poc` log groups,
   `meridian-poc-*` roles, the CI user, `meridian-poc-*` alarms, SNS
   topics, or Budgets.

6. Delete the local `tfplan` and `destroy.tfplan`. They are gitignored,
   but plan files can embed sensitive values.

### CLI gotchas

- `aws cloudfront list-distributions` needs `--no-paginate` when there
  are none, or the CLI prints nothing. `aws budgets describe-budgets`
  does the same. `aws ecr describe-image-scan-findings` also misbehaves
  under auto-pagination.
- An empty result looks the same as a failed one when the CLI prints
  nothing, so check the exit code (`echo $?`) when a read-back looks
  empty.
- In zsh, don't keep multi-word flags in a string variable (`P="--profile
  x --region y"`); it doesn't word-split. Pass the flags directly.

## If something goes wrong

- **Apply fails at CloudFront with 403 "account must be verified".** An
  account-level block, not a config problem. Test it cheaply with a
  disabled throwaway distribution made with the CLI (create, then
  delete). See architecture decision 7, addendum.
- **Sudden Access Denied on things that worked.** The project may be near
  its spend limit, which adds a policy denying `CreateDistribution`,
  `CreateService` and `CreateLoadBalancer`. Check AWS Settings > Billing
  before debugging IAM.
- **Free-plan SCP denials.** `iam:*Provider*` and `iam:*LoginProfile*`
  are denied (no GitHub OIDC; no `force_destroy` on IAM users).
  `budgets:CreateBudget` is allowed.
- **Pipeline deploy needs a new SHA.** Tags are immutable, so an existing
  tag skips the build. Push a new commit to the app repo's `main`.
