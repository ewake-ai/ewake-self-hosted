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
   `eu-west-3` region via the AWS Console → Bedrock → Model access. These are
   the exact IDs the runtime invokes (`src/common/utils/LLM/models.ts`); the
   `eu.` prefix is a cross-region inference profile, so the console lists each
   one under its underlying model name:
   - `eu.anthropic.claude-opus-4-5-20251101-v1:0`
   - `eu.anthropic.claude-sonnet-4-6`
   - `eu.anthropic.claude-sonnet-4-5-20250929-v1:0`
   - `eu.anthropic.claude-haiku-4-5-20251001-v1:0`
   - `cohere.embed-multilingual-v3`

   Enable all five. A partial grant fails in a way that reads like a product
   bug rather than a missing entitlement: the parent agent runs on Opus, so it
   answers, while every sub-agent runs on Haiku with Sonnet 4.5 behind it — so
   an account missing those two returns a fluent reply that has investigated
   nothing, and buries the cause in an AWS Marketplace error naming
   `aws-marketplace:ViewSubscriptions`.

   Verify with a call per model rather than by reading the console:

   ```bash
   aws bedrock-runtime invoke-model --region eu-west-3 \
     --model-id eu.anthropic.claude-haiku-4-5-20251001-v1:0 \
     --content-type application/json \
     --body "$(echo '{"anthropic_version":"bedrock-2023-05-31","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' | base64)" \
     /dev/null
   ```

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

### If you can't delegate a public zone

The section above assumes you can delegate a zone to this AWS account and
that it resolves publicly. Not every organisation can. A common shape is a
hostname that lives in a **private** hosted zone, or in a parent zone owned
by a different team in a different account.

ACM validates domain control over **public** DNS. It cannot see a private
hosted zone, and it cannot see a zone whose parent has not delegated to it.
Pointing `hosted_zone_id` at either one does not fail fast: certificate
validation blocks for the full timeout and takes the dashboard with it,
because the whole stack sits behind the HTTPS listener.

If that is your situation, take DNS out of Terraform's hands entirely:

```hcl
hosted_zone_id      = null
acm_certificate_arn = "arn:aws:acm:eu-west-3:...:certificate/..."
company_host        = "ewake.yourcompany.com"
```

Terraform then creates no zone records and issues no certificate. You own
two things, and **nothing in this stack will tell you if either lapses**:

1. **The A record.** Point `company_host` at the `alb_dns_name` output,
   wherever your resolution actually happens — a private hosted zone, an
   internal resolver, your parent zone. With `alb_internal = true` the ALB
   has private addresses, so a private zone is the natural home for it.
2. **Certificate renewal.** Whatever DNS record proved control when the
   certificate was issued has to stay in place: ACM re-reads it to renew,
   roughly eleven months later. Deleting it breaks renewal silently.

To issue that certificate, request it in the same region as the deployment
and publish the validation record wherever your domain resolves publicly —
this can be a flat CNAME in the parent zone; the name itself never has to be
publicly resolvable, only the validation record:

```sh
aws acm request-certificate --region eu-west-3 \
  --domain-name ewake.yourcompany.com --validation-method DNS \
  --query CertificateArn --output text
# then read the record to publish:
aws acm describe-certificate --region eu-west-3 --certificate-arn "$ARN" \
  --query 'Certificate.DomainValidationOptions[].ResourceRecord'
```

After apply, `terraform output dns_wiring` prints every value the edge
depends on and which half is yours; `terraform output manual_dns_steps`
lists what is still outstanding. Capture that output somewhere durable — it
is the record of what the working configuration was.

### Moving a running deployment to a new subnet range

A VPC's primary CIDR cannot be changed, so editing `vpc_cidr` on a live
deployment replaces the VPC and everything in it — including the load balancer,
whose DNS name you or your customer holds a record for. Use `subnet_cidr`
instead. It is associated to the VPC as a secondary CIDR and the subnets are
carved from it, so **the ALB keeps its ARN and DNS name and no DNS record has to
be repointed.**

```hcl
vpc_cidr    = "10.10.0.0/16"   # leave alone — the primary stays, empty
subnet_cidr = "10.80.0.0/20"   # the subnets move here
```

Everything moves in place — ALB, ECS, NAT gateways, VPC endpoints, route tables,
every Lambda — with two exceptions that terraform cannot sequence for you.

**Both come from the same cause.** `aws_ecs_service` carries
`create_before_destroy`, and terraform propagates that to everything the service
depends on: task definition -> `aws_db_instance` (its `POSTGRES_HOST`) and
`aws_instance.neo4j` (its `NEO4J_URI`) -> subnet group -> subnets. So the
database and the Neo4j box are both planned create-before-destroy, and both are
singletons AWS will not let you have two of. There is no lifecycle setting that
opts out.

**Before the apply, do these two things.**

1. **Delete the database.** RDS cannot change subnets inside one VPC at all —
   `ModifyDBInstance` answers *"Choose a DB subnet group in different VPC"* — and
   a replacement fails on the fixed `identifier` with `DBInstanceAlreadyExists`.
   Snapshot first if it holds anything you need; terraform recreates it in the
   new subnets and `db-migrate` reruns automatically.

   ```sh
   aws rds modify-db-instance --db-instance-identifier <tenant> \
     --no-deletion-protection --apply-immediately
   aws rds delete-db-instance --db-instance-identifier <tenant> \
     --final-db-snapshot-identifier <tenant>-premove
   ```

   Also set `rds_deletion_protection = false` for this apply, and back to `true`
   after.

2. **Terminate the Neo4j instance.** Its EBS volume can only attach to one
   instance, so the new box cannot mount it while the old one holds it
   (`VolumeInUse`). The volume itself is never destroyed — it carries
   `prevent_destroy`, and the boot script only formats a disk with no filesystem,
   so the graph survives and remounts on the new instance.

   ```sh
   aws ec2 terminate-instances --instance-ids <neo4j instance id>
   ```

Then apply. Expect roughly 25 minutes, most of it RDS creation.

**Verify afterwards** — the point of the exercise is the first line:

```sh
aws elbv2 describe-load-balancers --names <tenant>-tenant-alb \
  --query 'LoadBalancers[0].DNSName'          # unchanged
terraform plan                                 # "No changes"
```

If a task cannot start with `unable to retrieve secret from asm` or an ECR
timeout, the interface-endpoint security group is not admitting the new range —
check it lists both CIDRs before looking anywhere else. That one line presents as
four unrelated failures: a bootstrap Lambda that hangs for its full timeout, ECR
pull timeouts, `password authentication failed`, and finally *"Database schema is
behind this image"*.

### Changing the hostname of a running deployment

Do it in two applies, never one. The first is additive and safe; the second
removes the old name once you have confirmed the new one works.

**Apply 1** — serve both names. Leave `root_domain`, `hosted_zone_id` and
`company_host` exactly as they are, and add:

```hcl
extra_certificate_arns = ["arn:...:certificate/<cert for the new name>"]
alb_extra_host_headers = ["new.yourcompany.com"]
```

`extra_certificate_arns` makes the TLS handshake succeed on the new name;
`alb_extra_host_headers` makes the request actually route. They are separate
settings because they are separate failure modes — a certificate with no
host header gives you a clean handshake followed by the listener's `404 no
route`, which looks like a working migration until someone tries it.

**Apply 2** — once the new name loads, move `company_host`, `root_domain`
and `hosted_zone_id`/`acm_certificate_arn` over and empty both extra lists.
This one destroys the old certificate and A record, and replaces the reactive
task definition, since the dashboard URL is baked into its environment.

Don't collapse the two. If Terraform manages the old certificate, an apply
that both drops it and still needs it on the listener fails on
`ResourceInUseException`.

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

**Decide `alb_internal` before your first apply.** A load balancer's scheme is
immutable in AWS, and this one cannot be changed in place afterwards — not
disruptively, but *not at all*. Terraform destroys the listeners, then fails to
create the replacement because the old load balancer still holds the name:

```
Error: ELBv2 Load Balancer (<tenant>-tenant-alb) already exists
```

That leaves the deployment **down, mid-apply**: no listeners, and no new load
balancer. The name collides because the replacement is created before the old one
is removed, which the ECS service and target group require of everything they
depend on.

Recovering means deleting the load balancer yourself, between two applies:

```sh
aws elbv2 delete-load-balancer --load-balancer-arn \
  $(aws elbv2 describe-load-balancers --names <tenant>-tenant-alb \
      --query 'LoadBalancers[0].LoadBalancerArn' --output text)
terraform apply
```

Do not reach for `terraform destroy -target=aws_lb.this` instead — it cascades into
the whole company module, including the Neo4j volume, and stops on its
`prevent_destroy` guard having already planned the rest.

The replacement comes back with a **new DNS name and a new hosted-zone ID**. If
Terraform owns your record it updates it for you; if you own it
(`hosted_zone_id = null`) your hostname points at a load balancer that no longer
exists until you repoint it by hand, and `terraform output dns_wiring` is where the
new target comes from.

So treat the scheme as part of the deployment's shape, chosen once. If you expect
to need both at different times, start public and narrow `alb_ingress_cidrs`
instead — that list is editable in place, with no replacement and no outage.

#### Inbound webhooks on a private deployment

A private ALB has no route from the internet, so Slack and Datadog cannot deliver
to it. The dashboard is unaffected — your users reach it over your own network —
but any integration that calls *in* needs a public entry point in front.

If you already run one (an API gateway, a reverse proxy, a CDN) point it at the
ALB and name it here:

```hcl
public_inbound_base_url = "https://ewake-inbound.example.com"
```

The Slack manifest and the Datadog webhook are then registered against that URL
instead of the dashboard host, which stays private. Leave it unset when the ALB is
public — both roles are the same name then, and this is the only difference
between them.

`alb_ingress_cidrs` has none of that cost — it is security-group rules, changeable
in place at any time. Tightening or widening who can reach an existing deployment
is always cheap; changing whether it is public is not.

A private ALB does not require a private DNS story. If you *can* delegate a public
zone, keep `hosted_zone_id` set: ACM validates by reading a DNS record, never by
connecting to the load balancer, so a private ALB and a public zone are not in
conflict, and the dashboard's record simply resolves to private addresses.

If you cannot, set `hosted_zone_id = null` and supply your own certificate — see
[If you can't delegate a public zone](#if-you-cant-delegate-a-public-zone). That
combination (internal ALB, customer-owned record in a private zone, customer-issued
certificate) is a supported shape and is what at least one production deployment
runs. Either way you need a certificate before the apply can create the HTTPS
listener the rest of the stack sits behind.

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

### One-time: upgrading a deployment first applied before v1.0.0

**Only deployments whose last apply predates the v1.0.0 tag need this.** Check
with `terraform state list | grep aws_route.` — if that prints nothing, you are
here. A fresh deployment is already correct; skip ahead.

v1.0.0 pulled the default routes out of the route tables into standalone
`aws_route` resources, and put the certificate behind a `count`. Terraform cannot
work out on its own that the routes it wants to create are the ones AWS already
has, so `terraform apply` fails with:

```
Error: creating Route in Route Table (rtb-...): RouteAlreadyExists
```

Fix it with three imports — but **do the two state moves first**. Terraform
migrates `this` to `this[0]` automatically during plan and apply, and *not*
during import, so importing first fails with `aws_acm_certificate.this is empty
tuple`:

```sh
terraform state mv 'aws_acm_certificate.this'            'aws_acm_certificate.this[0]'
terraform state mv 'aws_acm_certificate_validation.this' 'aws_acm_certificate_validation.this[0]'
```

Then find your route table IDs and import the default route from each:

```sh
terraform state show aws_route_table.public     | grep -m1 '^    id'
terraform state show 'aws_route_table.private[0]' | grep -m1 '^    id'
terraform state show 'aws_route_table.private[1]' | grep -m1 '^    id'

terraform import 'aws_route.public_default'     '<public-rtb-id>_0.0.0.0/0'
terraform import 'aws_route.private_default[0]' '<private-rtb-id-0>_0.0.0.0/0'
terraform import 'aws_route.private_default[1]' '<private-rtb-id-1>_0.0.0.0/0'
```

`private_default[N]` matches `aws_route_table.private[N]`, which follows the
order of `azs` — read the IDs out of state as above rather than guessing from the
console.

Then `terraform plan` should show no route creations, and you can apply
normally.

> The ALB security group is replaced during this upgrade: its description
> changed, and descriptions are immutable in AWS. That is expected and takes
> seconds. Deployments that last applied on v1.1.0 or earlier with a fixed group
> name would have failed here with `InvalidGroup.Duplicate`; v1.1.1 switched the
> group to a generated name so the replacement can happen in place.

### One-time: moving the scheduled Lambdas onto the bundled image

**Only deployments first applied before Ewake v0.150.0 need this.** A fresh
deployment creates these functions on the bundled image already — skip ahead.

The nine scheduled Lambdas (`knowledge-graph`, `incident-indexing`,
`release-watch`, the Datadog and Loki analysers, and the two discovery
loops) used to run from one ECR repository each. They now share a single
`ewake-lambdas` image and select their handler with `image_config`. The
old per-Lambda repositories are no longer built, so a deployment left on
them silently freezes on its last image.

Worse once the old repository is actually deleted on the Ewake side, which
has now happened: AWS Lambda re-validates the *current* code artifact on
every configuration change, so a function still pointing at a repository
that no longer exists cannot be updated at all. Any apply that touches these
functions — even one that only adds an environment variable — fails with:

```
Error: updating Lambda Function (<tenant>-<company>-knowledge-graph) configuration:
ResourceConflictException: ... AWS Lambda does not have permission to access the
provided code artifact. Please configure the required permissions in the ECR repository.
```

The message points at ECR permissions, which is misleading — the grant is
fine, the repository is gone. The replace below is the fix; it recreates each
function against the bundled image rather than trying to update one that
cannot be read.

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
not take — re-run rather than leaving it. The old repositories have already
been deleted, so a function left behind is wedged rather than merely stale.

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
