# Ewake — self-hosted (BYOC) install

This Terraform root stands up an Ewake deployment inside **your own AWS
account**. Nothing in it phones home to Ewake at runtime — the platform
runs on your VPC, your RDS, your ECS cluster. The one dependency it keeps
on the Ewake side is container images and frontend assets, which your
account pulls cross-account from Ewake's ECR + S3. Ewake attaches those
grants to your account ID before your first apply.

If anything below is unclear, tell your Ewake contact — this install path
is early days and the docs will improve with every customer.

> **Status: login is not shipped yet.** Everything in this document works
> except authentication. The stack installs, the dashboard serves, Slack
> events are received and verified — but there is currently no way to sign
> in, and every configuration screen sits behind sign-in. That means no
> integrations can be connected and no ambient schedules created until the
> login work lands. Talk to your Ewake contact about timing before you plan
> a rollout around this. The rest of this README describes the install as it
> behaves today, and flags the pending pieces inline.

## Prerequisites

0. A **supported region**. Today that is **`eu-west-3`** only. Ewake's
   container images are published there and nowhere else, so any other
   region fails at image pull. Terraform rejects an unsupported value at
   `plan`, before it creates anything. Ask your Ewake contact if you need
   a different region — adding one is a small change on our side, but it
   has to happen before you install.
1. An **AWS account** you're prepared to dedicate to this deployment.
2. A **root domain** (or subdomain — e.g. `ewake.acme.corp`) delegated
   to a **Route53 hosted zone in the same AWS account** as this install.
   The install creates its own ACM cert against that zone; you just need
   the zone ready. See "One-time bootstrap" below for the exact
   `create-hosted-zone` + parent-registrar-NS-delegation flow.
3. An **OIDC IdP** (Okta, Entra, Google Workspace, Auth0, Ping, Keycloak —
   any spec-compliant provider). Worth having ready, but **nothing consumes
   it yet** — see "Login" under Post-install.
4. **Terraform ≥ 1.10** locally — the state backend locks through an S3
   `.tflock` object, which earlier versions reject at `init`. AWS
   credentials that can create VPCs, RDS, IAM roles, and Secrets Manager
   entries.
5. The **AWS CLI**, authenticated as the same principal. Needed beyond the
   bootstrap steps below: `apply` shells out to it to run the database
   migration and wait for its exit code.

`ewake_aws_account_id` used to be listed here as something to request from
Ewake. It now defaults to the correct value — you only set it if Ewake
explicitly tells you to.

## One-time bootstrap

Terraform needs a state bucket before it can `init`. Locking uses a
`.tflock` object inside that same bucket, so there is no separate
DynamoDB table to create. Create the bucket once, in the region you'll
deploy to, and keep versioning on — it is what makes a corrupted state
recoverable:

```sh
export AWS_REGION=eu-west-3     # your chosen region
export CUSTOMER=acme            # your short name
aws s3 mb "s3://${CUSTOMER}-ewake-terraform-state" --region "$AWS_REGION"
aws s3api put-bucket-versioning \
  --bucket "${CUSTOMER}-ewake-terraform-state" \
  --versioning-configuration Status=Enabled
```

Whoever runs Terraform needs `s3:GetObject`, `s3:PutObject` and
`s3:DeleteObject` on this bucket — the lock is taken and released as an
object. If you'd rather lock through DynamoDB, create a table separately
and swap `use_lockfile` for `dynamodb_table` in `backend.tf`.

### Route53 hosted zone

Create a Route53 hosted zone for `root_domain` in this AWS account, then
delegate to it from whoever owns the parent zone (your DNS registrar for
a bare domain, or another Route53 zone if it's a subdomain):

```sh
export ROOT_DOMAIN=ewake.acme.corp
ZONE_ID=$(aws route53 create-hosted-zone \
  --name "$ROOT_DOMAIN" \
  --caller-reference "byoc-$(date +%s)" \
  --query 'HostedZone.Id' --output text | sed 's|/hostedzone/||')
aws route53 get-hosted-zone --id "$ZONE_ID" \
  --query 'DelegationSet.NameServers' --output text
# → paste those 4 NS records at your registrar (or in the parent Route53 zone)
# → confirm delegation propagates before apply:
dig +short NS "$ROOT_DOMAIN" @8.8.8.8
```

Then set `hosted_zone_id = "$ZONE_ID"` in `terraform.tfvars`. The Route53
zone must exist before `terraform apply` — the ACM cert validation writes
DNS records into it, and `terraform apply` blocks on those records
resolving publicly (up to 45 min timeout before it fails with an opaque
"certificate not validated" error). Do the `dig` check above before
running apply.

### DLM role import (rarely needed)

If your account has ever used Data Lifecycle Manager — even a single
console "Create default IAM role" click for an unrelated EBS lifecycle,
or an old Cloud SQL migration — it already has the role this root
creates, and the first apply will stop with `EntityAlreadyExists`.
Import it before applying:

```sh
aws iam get-role --role-name AWSDataLifecycleManagerDefaultRole \
  && terraform import aws_iam_role.dlm_default AWSDataLifecycleManagerDefaultRole
```

A `NoSuchEntity` from the first command means you have no such role and
nothing to import; any other error is real and worth reading.

## Configuration

Copy `terraform.tfvars.example` (below) into `terraform.tfvars` and fill
in your values:

```hcl
aws_region  = "eu-west-3"
tenant_name = "acme"
company = {
  name      = "acme"
  public_id = "acme"                    # short slug, used in S3 paths
  domain    = "acme.com"                # your email domain
}
root_domain    = "ewake.acme.corp"
hosted_zone_id = "Z0123456789ABCDEFGHIJ"
azs            = ["eu-west-3a", "eu-west-3b"]   # two AZs in aws_region

# Given to you by Ewake:
ewake_aws_account_id = "123456789012"

# Optional overrides (defaults shown):
# release_channel     = "stable"         # or "latest" for dogfood builds
# vpc_cidr            = "10.10.0.0/16"
# rds_instance_class  = "db.t4g.small"
# rds_multi_az        = true
```

## First apply

```sh
cd terraform/roots/byoc

terraform init \
  -backend-config="bucket=${CUSTOMER}-ewake-terraform-state" \
  -backend-config="key=byoc/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}"

terraform plan
terraform apply
```

The first apply takes roughly 15–20 minutes (RDS + Neo4j EC2 dominate).
When it completes, `terraform output dashboard_url` serves the dashboard
over HTTPS — though you can't sign in yet (see below).

## Post-install

### 1. Login — NOT AVAILABLE YET

**There is currently no way to sign in to a byoc deployment.** The stack
installs and serves, but authentication has not shipped.

This matters more than it sounds, because every configuration screen is
behind the session check. Until login lands you cannot connect any
integration, create any ambient schedule, or reach the admin screens — so
a byoc install is not yet a usable product, only a correct one.

Login is being built on a **Dex sidecar** running inside the reactive task.
When it lands, this section will describe registering an OIDC application
in your own IdP and pointing Dex at it; your IdP client secret will stay in
your AWS account and never reach Ewake. The `oidc_secret_arn` variable in
`terraform.tfvars` is a placeholder reserved for that work — **it is not
read by anything today**, and setting it has no effect.

Ask your Ewake contact where the Dex work stands before planning a rollout.

### 2. Slack — available

This one does work without login *at the infrastructure level*, but the
install flow itself is a dashboard screen, so in practice it is also
blocked until login ships. Recording it here so the mechanism is clear:

From the dashboard, open the Slack integration and choose **"From a
manifest"**. Ewake generates an app manifest; you create the app in your
own workspace from it, install it, and paste the bot token + signing
secret back into the dialog.

Both values are stored in a Secrets Manager entry **in your own AWS
account**. Inbound Slack events hit your deployment directly and are
signature-verified locally against that stored signing secret — no Ewake
infrastructure sits in the path, on install or on receive.

### 3. Integrations requiring OAuth — temporarily unavailable

GitHub App, GitHub SSO, Microsoft SSO, Google SSO and Notion connect
through an OAuth authorization-code flow whose callback URL is registered
against Ewake-hosted infrastructure. A deployment in your account can't
complete that round trip, so these are switched off in byoc.

This is a limitation of the OAuth *connect* flow specifically — not of the
integrations themselves. Anything that authenticates with a token or an IAM
role you supply directly is unaffected (see below).

### 4. Token / IAM-role integrations — available

Datadog, GitLab, Grafana, Prometheus, Loki, Jira, Linear and PagerDuty
connect from the dashboard with a vendor API token or an IAM role you
supply. No Ewake-hosted callback is involved, so these work normally in
byoc — once login ships and you can reach the dashboard to enter them.

### 5. Ambient scraping — available, but must be scheduled

The ambient agents (knowledge graph, incident indexing, release watch, log
and metric analysis) are deployed as Lambdas by this install, but they run
on schedules that are **created from the dashboard, not by Terraform**.
Terraform provisions an empty EventBridge schedule group; a fresh install
has zero schedules and therefore no ambient activity until you add them.
That is expected, not a fault — and it is another thing gated behind login.

## Updates

The deployment pins `release_channel = "stable"` by default and pulls
whatever tag Ewake has published as stable at your `terraform apply`
time. To update:

```sh
terraform apply
```

That applies the database migrations and then rolls the service, in that
order, with no further commands to run. The migration is a one-off ECS
task; `apply` waits for it and fails if it exits non-zero, so a failed
migration stops the release rather than leaving new code against an old
schema. Only then does it point the service at the new task definition and
wait for it to reach steady state. Both steps are skipped when the image
tag has not changed, so a no-op `apply` stays a no-op.

To pin a specific build — a rollback, or a fix Ewake gave you ahead of a
release — set `app_image_tag`, not `release_channel`:

```hcl
app_image_tag = "ewake-v0.145.0"   # or "sha-1a2b3c4d"
```

`release_channel` only accepts `stable` or `latest`; it names the frontend
channel as well as the image tag, and a version string resolves no channel.
`app_image_tag` covers the server and its migrations together, so the two
can never disagree about the schema.

## Tearing down

`terraform destroy` alone will not work — three resources carry
`prevent_destroy` or deletion protection specifically because losing them
silently is worse than an obvious failure. If you actually want the
install gone, you have to opt out of each guard explicitly.

1. **Disable RDS deletion protection.** Terraform's `deletion_protection = true` on the DB instance means `destroy` errors out; skip the final snapshot only if you're sure there's nothing worth keeping.

   ```sh
   aws rds modify-db-instance --db-instance-identifier <tenant_name> \
     --no-deletion-protection --apply-immediately
   ```

2. **Lift `prevent_destroy` on the Neo4j EBS volume and the DLM role.** Both are set in the module — comment them out (`terraform/modules/company_stack/neo4j.tf` on `aws_ebs_volume.neo4j_data`, `terraform/roots/byoc/dlm.tf` on `aws_iam_role.dlm_default`) for the duration of the destroy. Restore the flags afterward.

   If you want to keep DLM lifecycle policies you set up outside this install, `terraform state rm aws_iam_role.dlm_default` first so destroy leaves the role alone.

3. **`terraform destroy`.** Expect ~15 min. Neo4j's EC2 + EBS, the RDS instance, the VPC + NAT gateways, and every Lambda + secret get deleted.

4. **Manual cleanup for a fully empty account.** Terraform leaves a few things behind because they aren't in state:
   - CloudWatch log groups that get recreated by ECS Container Insights or lambdas mid-destroy — delete with `aws logs delete-log-group`.
   - Secrets Manager entries with 30-day recovery windows — `aws secretsmanager delete-secret --force-delete-without-recovery` if you want them gone now.
   - The Route53 hosted zone for `root_domain` (create is out-of-band per "One-time bootstrap"; destroy is too).
   - The state bucket itself.

## What's NOT in this install

- **No login, yet** — authentication has not shipped. Everything behind
  the session check (all integrations, ambient schedules, admin) is
  unreachable until the Dex work lands. This is the one thing standing
  between a correct install and a usable one.
- **No OAuth-based connect flows** — GitHub App, GitHub SSO, Microsoft
  SSO, Google SSO and Notion each complete on an Ewake-hosted callback
  a customer deployment can't reach. Disabled in the dashboard. Slack is
  *not* in this group: it installs from a manifest with credentials you
  supply, and works standalone.
- **No orchestrator** — a byoc deployment is self-contained. Slack events
  arrive directly and are signature-verified locally; API-key callers
  authenticate against this instance. Nothing routes through Ewake.
- **No telemetry to Ewake** — no logs, metrics, traces, or usage
  reporting egresses your account. Datadog / LangSmith / Grafana Cloud
  hooks are all gated off in byoc mode.
- **No shared services** — every RDS, Neo4j, ECS task, Lambda, log
  group is in your account. Snapshots stay in your account.

## Duplication note (for Ewake reviewers)

The tenant-level files here (`vpc.tf`, `vpc_endpoints.tf`,
`security_groups.tf`, `alb.tf`, `ecs_cluster.tf`, `rds.tf`,
`bootstrap_lambda.tf`, `log_clustering.tf`) are direct copies of
`terraform/tenants/*.tf` with `terraform.workspace` and
`local.this_tenant.*` swapped for variables. Any fix to those files
in the SaaS tenants root must be mirrored here — until the extraction
into `terraform/modules/tenant_stack/` lands (deliberately deferred
because moving resources into a module needs `terraform plan`
verification against live SaaS state, which is not something to
guess).
