# Ewake — self-hosted deployment

Deploy Ewake into **your own AWS account**. Everything runs on your
infrastructure — your VPC, your RDS, your ECS cluster. Nothing phones home
at runtime. The only dependency on Ewake is container images and frontend
assets, which your account pulls cross-account from Ewake's ECR and S3.
Ewake grants that access to your account ID before your first apply.

## Prerequisites

1. **A supported region.** Today that is **`eu-west-3`** (Paris) only.
   Ewake's container images are published there; any other region fails at
   image pull. Terraform rejects unsupported values at `plan`. If you need
   a different region, let us know — adding one is quick on our side.

2. **A dedicated AWS account.** We recommend a standalone account so the
   deployment's VPC, IAM roles, and security groups don't overlap with your
   other workloads.

3. **A domain** (or subdomain — e.g. `ewake.yourcompany.com`) delegated to
   a **Route53 hosted zone in the same AWS account**. The install creates
   an ACM certificate validated against that zone. See [Route53 setup](#route53-hosted-zone)
   below.

4. **An OIDC identity provider** (Okta, Entra ID, Google Workspace, Auth0,
   or any spec-compliant provider). You'll register Ewake as an application
   in your IdP and configure SSO connectors — see [SSO setup](#4-sso--single-sign-on).

5. **AWS Bedrock model access.** Enable the following models in the
   `eu-west-3` region via the AWS Console → Bedrock → Model access:
   - `eu.anthropic.claude-sonnet-4-6-20250514`
   - `eu.anthropic.claude-sonnet-4-5-20250514`
   - `eu.anthropic.claude-haiku-4-5-20251001`
   - `eu.anthropic.claude-opus-4-20250514`
   - `cohere.embed-multilingual-v3`

   Without these grants the agents fail with an opaque AWS Marketplace
   error at runtime.

6. **Terraform >= 1.10** and the **AWS CLI**, both authenticated as the
   same principal. Terraform locks state with an S3 `.tflock` object
   (older versions reject this at `init`).

## Setup

### State bucket

Terraform needs a versioned S3 bucket for state before it can `init`.
Create it once, in the region you'll deploy to:

```sh
export AWS_REGION=eu-west-3
aws s3 mb "s3://your-company-ewake-state" --region "$AWS_REGION"
aws s3api put-bucket-versioning \
  --bucket "your-company-ewake-state" \
  --versioning-configuration Status=Enabled
```

The Terraform user needs `s3:GetObject`, `s3:PutObject` and
`s3:DeleteObject` on this bucket.

> **Security note:** Terraform state contains sensitive values, including
> SSO connector client secrets (written into the ECS task definition at
> plan time). Enable server-side encryption on the bucket (SSE-S3 or
> SSE-KMS), restrict access to the Terraform operator, and treat the
> state file as holding credentials.

### Route53 hosted zone

Create a Route53 hosted zone for your domain in this AWS account, then
delegate to it from your DNS registrar (or parent Route53 zone):

```sh
ZONE_ID=$(aws route53 create-hosted-zone \
  --name "ewake.yourcompany.com" \
  --caller-reference "ewake-$(date +%s)" \
  --query 'HostedZone.Id' --output text | sed 's|/hostedzone/||')

aws route53 get-hosted-zone --id "$ZONE_ID" \
  --query 'DelegationSet.NameServers' --output text
# → add those 4 NS records at your registrar / parent zone
```

Confirm delegation propagates before running apply — the ACM certificate
validation writes DNS records into this zone and blocks until they resolve
(up to 45 minutes):

```sh
dig +short NS ewake.yourcompany.com @8.8.8.8
```

### DLM role (if your account already has one)

If your account has ever used AWS Data Lifecycle Manager — even an
unrelated EBS lifecycle policy — it already has the
`AWSDataLifecycleManagerDefaultRole` that this deployment creates, and
the first apply will fail with `EntityAlreadyExists`. Import it first:

```sh
aws iam get-role --role-name AWSDataLifecycleManagerDefaultRole \
  && terraform import aws_iam_role.dlm_default AWSDataLifecycleManagerDefaultRole
```

A `NoSuchEntity` response means the role doesn't exist yet — nothing to
import, proceed to the next step.

## Configuration

Copy `terraform.tfvars.example` to `terraform.tfvars` and fill in your
values:

```hcl
aws_region  = "eu-west-3"
tenant_name = "yourcompany"

company = {
  name      = "yourcompany"
  public_id = "yourcompany"
  domain    = "yourcompany.com"

  sso_connectors = ["google"]
}

root_domain    = "ewake.yourcompany.com"
hosted_zone_id = "Z0123456789ABCDEFGHIJ"
azs            = ["eu-west-3a", "eu-west-3b"]
```

**Naming rules:**
- `tenant_name`: lowercase letters and digits only (no hyphens), starts
  with a letter, max 21 characters.
- `company.name`: same rules, max 33 characters.
- Both typically use your company's short name (e.g. `acme`, `qonto`).

**Optional overrides** (defaults shown):

| Variable | Default | Notes |
|---|---|---|
| `release_channel` | `"stable"` | `"latest"` for pre-release builds |
| `vpc_cidr` | `"10.10.0.0/16"` | Change if it collides with peering |
| `rds_instance_class` | `"db.t4g.small"` | Scale up for larger teams |
| `rds_multi_az` | `true` | `false` for cost savings in non-prod |
| `neo4j_instance_type` | `"t4g.small"` | Must be a Graviton (arm64) type |

> **Capacity note:** `db.t4g.small` and `t4g.small` can be
> capacity-constrained in some AZs. If the first apply stalls on RDS or
> Neo4j creation with `insufficient-capacity`, try `db.t4g.medium` /
> `t4g.medium`, or pick different AZs.

### Private deployments (no public ingress)

By default the ALB is internet-facing and accepts 443/80 from anywhere. To keep
the deployment private — an isolated account, or a security review that will not
accept a public dashboard — set both:

```hcl
alb_internal      = true
alb_ingress_cidrs = ["10.10.0.0/16"]   # your vpc_cidr, or a VPN range
```

Set them **together**. `alb_internal` moves the load balancer to the private
subnets and drops its public IPs; `alb_ingress_cidrs` is what actually refuses a
packet. Either alone leaves a gap.

You still need a real, publicly-delegated `hosted_zone_id`. ACM validates by
reading a DNS record, never by connecting to the load balancer, so a private ALB
and a public zone are not in conflict — and without a validating certificate the
apply cannot create the HTTPS listener that the rest of the stack depends on.
The dashboard's DNS record simply resolves to private addresses.

#### Reaching a private dashboard

The VPC already carries `ssm`, `ssmmessages` and `ec2messages` interface
endpoints, and the Neo4j instance runs in a private subnet with
`AmazonSSMManagedInstanceCore`. That is enough to port-forward without a VPN,
a bastion or any inbound rule:

```sh
INSTANCE=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*neo4j*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

aws ssm start-session --target "$INSTANCE" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=<company.name>.<root_domain>,portNumber=443,localPortNumber=8443"
```

Then map the hostname to your loopback so the certificate still matches:

```
127.0.0.1  <company.name>.<root_domain>
```

in `/etc/hosts`, and open `https://<company.name>.<root_domain>:8443`. Users need
`ssm:StartSession` on that instance and nothing else — no inbound access, no
credentials on the box.

## First apply

```sh
terraform init \
  -backend-config="bucket=your-company-ewake-state" \
  -backend-config="key=ewake/terraform.tfstate" \
  -backend-config="region=eu-west-3"

terraform plan
terraform apply
```

The first apply takes roughly 15–20 minutes (RDS and Neo4j dominate).
When it completes, `terraform output dashboard_url` gives you your
Ewake dashboard URL.

## Post-install

### 1. Verify the dashboard loads

Open the URL from `terraform output dashboard_url` — the login screen
should appear. If the page doesn't load, check that DNS delegation
propagated (the ACM cert validation can silently time out).

### 2. Configure SSO

Login requires at least one SSO connector. The setup is a three-step
process — two applies with a secret write in between.

**Step 1.** List the connector ID in `sso_connectors` in your tfvars
and apply. This creates an empty Secrets Manager secret that Terraform
owns:

```hcl
company = {
  ...
  sso_connectors = ["google"]   # or "okta", "github", etc.
}
```

```sh
terraform apply
```

> After this apply the dashboard is up but **nobody can log in**. The
> secret holds a placeholder that Dex rejects on purpose. The sidecar
> dies at startup, but it is non-essential so the service reports
> healthy — this is expected, not a fault. Proceed to step 2.

**Step 2.** Register an OIDC application in your identity provider with
the redirect URI:

```
https://<company.name>.<root_domain>/sso/callback
```

Then write the connector JSON into the secret Terraform created. The
secret path is `ewake/<tenant_name>/<company.name>/sso/<connector-id>`:

```sh
cat > connector.json << 'EOF'
{
  "type": "oidc",
  "id": "google",
  "name": "Google",
  "config": {
    "clientID": "....apps.googleusercontent.com",
    "clientSecret": "...",
    "redirectURI": "https://yourcompany.ewake.yourcompany.com/sso/callback",
    "hostedDomains": ["yourcompany.com"]
  }
}
EOF

aws secretsmanager put-secret-value \
  --secret-id "ewake/yourcompany/yourcompany/sso/google" \
  --secret-string file://connector.json
```

For other providers, replace `"type": "oidc"` as needed — see
[Connector examples](#connector-examples) below.

**Step 3.** Apply again so Terraform reads the real secret and compiles
it into the container environment, then force a redeploy:

```sh
terraform apply
aws ecs update-service \
  --cluster <tenant_name> --service <company.name> \
  --task-definition <tenant_name>-<company.name>-reactive \
  --force-new-deployment
```

The login screen should now show your SSO provider.

Your IdP client secret stays in Secrets Manager **in your AWS account**.
It is also present in the ECS task definition and in Terraform state
(Terraform reads the secret at plan time to build the container config).
Treat your state file accordingly.

#### Connector examples

**Generic OIDC (Okta, Entra ID, Auth0, Ping, any OIDC provider):**

```json
{
  "type": "oidc",
  "id": "okta",
  "name": "Okta",
  "config": {
    "issuer": "https://yourcompany.okta.com",
    "clientID": "0oa...",
    "clientSecret": "...",
    "redirectURI": "https://yourcompany.ewake.yourcompany.com/sso/callback",
    "scopes": ["openid", "profile", "email"]
  }
}
```

For Microsoft Entra, use
`"issuer": "https://login.microsoftonline.com/<tenant-id>/v2.0"`.
Use a specific tenant ID, not `common`.

**Google:**

```json
{
  "type": "google",
  "id": "google",
  "name": "Google",
  "config": {
    "clientID": "....apps.googleusercontent.com",
    "clientSecret": "...",
    "redirectURI": "https://yourcompany.ewake.yourcompany.com/sso/callback",
    "hostedDomains": ["yourcompany.com"]
  }
}
```

**GitHub:**

```json
{
  "type": "github",
  "id": "github",
  "name": "GitHub",
  "config": {
    "clientID": "...",
    "clientSecret": "...",
    "redirectURI": "https://yourcompany.ewake.yourcompany.com/sso/callback"
  }
}
```

GitHub allows only one redirect URI per OAuth App, so each deployment
needs its own: Settings → Developer settings → OAuth Apps → New.

### 3. Sign in

The login screen shows the SSO providers you configured above. Click
one and authenticate through your IdP.

### 4. Connect Slack

From the dashboard, open the Slack integration and choose **"From a
manifest"**. Ewake generates an app manifest; create the app in your
Slack workspace from it, install it, and paste the bot token + signing
secret back into the dialog.

Both credentials are stored in Secrets Manager **in your AWS account**.
Inbound Slack events hit your deployment directly and are
signature-verified locally — nothing routes through Ewake.

### 5. Token / IAM-role integrations

Datadog, GitLab, Grafana, Prometheus, Loki, Jira, Linear, and PagerDuty
connect from the dashboard with an API token or IAM role you provide.
No Ewake callback is involved.

### 6. Ambient agents

The ambient agents (knowledge graph, incident indexing, release watch,
log/metric/span analysis) are deployed as Lambdas but run on schedules
created from the dashboard, not by Terraform. A fresh install has zero
schedules — add them after connecting your integrations.

### 7. Integrations not yet available

GitHub App, GitHub SSO, Microsoft SSO, Google SSO, and Notion connect
through OAuth flows whose callback URL is registered against
Ewake-hosted infrastructure. These are not available in self-hosted
deployments yet.

## Updates

To update to the latest stable release:

```sh
terraform apply
```

This applies database migrations first (as a one-off ECS task), then
rolls the service. Both steps are skipped when the image tag hasn't
changed.

To pin a specific build (for rollback, or a hotfix Ewake gave you):

```hcl
app_image_tag = "ewake-v0.145.0"   # or "sha-1a2b3c4d"
```

`app_image_tag` pins the reactive server and its database migrations
together. It does **not** pin Lambda images (those follow
`release_channel`) or sidecars (Dex, CloudWatch MCP, log clustering —
those track `:latest`). A rollback to an older `app_image_tag` runs
that server version against current Lambda and sidecar images. Leave
`app_image_tag` unset (or `null`) to follow `release_channel`.

### One-time: moving the scheduled Lambdas onto the bundled image

**Only deployments first applied before Ewake v0.150.0 need this.** A fresh
deployment creates these functions on the bundled image already — skip ahead.

The nine scheduled Lambdas (`knowledge-graph`, `incident-indexing`,
`release-watch`, the Datadog and Loki analysers, and the two discovery
loops) used to run from one ECR repository each. They now share a single
`ewake-lambdas` image and select their handler with `image_config`. The
old per-Lambda repositories are no longer built, so a deployment left on
them silently freezes on its last image.

`terraform apply` alone will **not** move them. Every Lambda in this stack
carries `lifecycle { ignore_changes = [image_uri] }`, so changing the image
is invisible to a normal plan. Replace them explicitly, once:

```sh
terraform apply $(for l in \
  datadog-log-analysis loki-log-analysis datadog-metric-analysis \
  datadog-span-analysis knowledge-graph incident-indexing \
  release-watch custom-mcp-discovery kubernetes-discovery; do
    printf ' -replace=module.company.module.scheduled_lambdas.aws_lambda_function.%s' "${l//-/_}"
  done)
```

The plan should show nine functions replaced and nothing else. Each one is
recreated in place under the same name and schedule; the EventBridge rules
that invoke them are untouched. Expect a cold start on the next scheduled
run, no other downtime.

Verify afterwards that all nine report the bundled image:

```sh
aws lambda get-function --function-name <tenant_name>-<company.name>-knowledge-graph \
  --query 'Code.ImageUri' --output text
# → ...amazonaws.com/ewake-lambdas:stable
```

If a function still shows `ewake-lambda-knowledge-graph`, the replace did
not take — re-run rather than leaving it, since the old repository can be
deleted on the Ewake side at any point after every deployment has moved.

## Tearing down

`terraform destroy` alone won't work — three resources have deletion
protection to prevent accidental data loss.

1. **Disable RDS deletion protection:**

   ```sh
   aws rds modify-db-instance \
     --db-instance-identifier <tenant_name> \
     --no-deletion-protection --apply-immediately
   ```

2. **Lift `prevent_destroy`** on the Neo4j EBS volume
   (`modules/company_stack/neo4j.tf`) and the DLM role (`dlm.tf`).
   Comment out the `lifecycle` blocks for the duration of the destroy.

3. **Run `terraform destroy`.** Expect ~15 min.

4. **Manual cleanup** (not in Terraform state):
   - CloudWatch log groups recreated mid-destroy by ECS/Lambda
   - Secrets Manager entries with 30-day recovery windows
   - The Route53 hosted zone (created out-of-band)
   - The state bucket

## What's not included

- **No orchestrator** — your deployment is self-contained. Slack events
  arrive directly; API keys authenticate against your instance.
- **No telemetry to Ewake** — no logs, metrics, traces, or usage data
  leaves your account.
- **No shared infrastructure** — every RDS, Neo4j, ECS task, Lambda, and
  log group is in your account. Snapshots stay in your account.
