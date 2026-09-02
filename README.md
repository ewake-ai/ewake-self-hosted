# Ewake — self-hosted deployment

Terraform to deploy Ewake into your own AWS account: your VPC, your RDS, your
ECS cluster, your Neo4j volume.

The deployment pulls container images and frontend assets from Ewake's ECR and
S3 in another account. Ewake grants your account ID access to those before your
first apply. Nothing else leaves your account at runtime: no logs, metrics,
traces or usage data, and no shared infrastructure between deployments.

- [Prerequisites](#prerequisites)
- [Setup](#setup)
- [Configuration](#configuration)
- [Private deployments](#private-deployments)
- [First apply](#first-apply)
- [Post-install](#post-install)
- [Updating](#updating)
- [Tearing down](#tearing-down)

## Prerequisites

Six items. Numbers 2 to 5 usually need another team, so request them first.

| # | What you need | Usually owned by |
| - | ------------- | ---------------- |
| 1 | Terraform >= 1.10 and the AWS CLI | you |
| 2 | An AWS account in `eu-west-3` | your cloud team |
| 3 | A domain delegated to a Route53 zone in that account | your DNS team |
| 4 | An OIDC identity provider | your identity team |
| 5 | Bedrock access to five models | your AWS account owner |
| 6 | Network access, if the deployment is private | your network team |

### 1. Terraform and the AWS CLI

Terraform 1.10 or newer, plus the AWS CLI. Both must authenticate as the same
principal. Terraform locks state with an S3 `.tflock` object, which older
versions reject at `init`.

### 2. An AWS account in `eu-west-3`

`eu-west-3` (Paris) is the only supported region today, because Ewake publishes
its images there. Any other region fails when pulling images, and Terraform
rejects an unsupported region at `plan`. Contact Ewake if you need another
region.

Use a dedicated account. This keeps the deployment's VPC, IAM roles and
security groups separate from your other workloads.

### 3. A domain delegated to Route53

A domain or subdomain — for example `ewake.example.com` — delegated to a
Route53 hosted zone **in the same AWS account**. The install creates an ACM
certificate and validates it against that zone.

If you cannot delegate a public zone, bring your own certificate instead. See
[If you cannot delegate a public zone](#if-you-cannot-delegate-a-public-zone).

### 4. An OIDC identity provider

Okta, Entra ID, Google Workspace, Auth0, or any spec-compliant provider. You
register Ewake as an application there. See [Configure SSO](#2-configure-sso).

You can also start without one. Ewake then serves a username and password form,
and Terraform generates an admin password into Secrets Manager under
`ewake/<tenant_name>/<company.name>/app`, key `ADMIN_PASSWORD`. Read it from
Secrets Manager. Adding a connector later switches login over.

### 5. Bedrock access to five models

Your account needs a Marketplace agreement for **all five** of these models in
`eu-west-3`:

```
eu.anthropic.claude-opus-4-5-20251101-v1:0
eu.anthropic.claude-sonnet-4-6
eu.anthropic.claude-sonnet-4-5-20250929-v1:0
eu.anthropic.claude-haiku-4-5-20251001-v1:0
cohere.embed-multilingual-v3
```

The `eu.` prefix is a cross-region inference profile. The AWS Console lists each
one under its underlying model name.

Enable all five. If some are missing, Ewake still replies but cannot complete
its work, and the underlying error is an AWS Marketplace one rather than an
obvious failure.

**Check whether an agreement is missing.** Use the base model ID, not the `eu.`
profile ID:

```sh
aws bedrock get-foundation-model-availability --region eu-west-3 \
  --model-id anthropic.claude-haiku-4-5-20251001-v1:0
```

`agreementAvailability: NOT_AVAILABLE` is the field that matters. Ignore
`authorizationStatus`, `entitlementAvailability` and `regionAvailability`.

**Accept an agreement.** Two commands per model, again with the base model ID:

```sh
MODEL=anthropic.claude-haiku-4-5-20251001-v1:0

token=$(aws bedrock list-foundation-model-agreement-offers --region eu-west-3 \
  --model-id "$MODEL" --query 'offers[0].offerToken' --output text)

aws bedrock create-foundation-model-agreement --region eu-west-3 \
  --model-id "$MODEL" --offer-token "$token"
```

`create-foundation-model-agreement` accepts the vendor's licence terms for your
account, so your account owner should run it.

If the error names `aws-marketplace:ViewSubscriptions` or
`aws-marketplace:Subscribe`, the agreement is missing. Bedrock returns that
message whatever IAM permissions the caller holds, so check the agreement
before auditing the role.

**Verify by calling each model**, rather than by reading the console:

```sh
aws bedrock-runtime invoke-model --region eu-west-3 \
  --model-id eu.anthropic.claude-haiku-4-5-20251001-v1:0 \
  --content-type application/json \
  --body "$(echo '{"anthropic_version":"bedrock-2023-05-31","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' | base64)" \
  /dev/null
```

### 6. Network access, if the deployment is private

Skip this if the load balancer will be internet-facing.

If you set `alb_internal = true`, users reach the dashboard over your own
network. See [Private deployments](#private-deployments).

## Setup

### State bucket

Terraform needs a versioned S3 bucket for state before `init`. Create it once:

```sh
export AWS_REGION=eu-west-3
aws s3 mb "s3://your-company-ewake-state" --region "$AWS_REGION"
aws s3api put-bucket-versioning \
  --bucket "your-company-ewake-state" \
  --versioning-configuration Status=Enabled
```

The Terraform principal needs `s3:GetObject`, `s3:PutObject` and
`s3:DeleteObject` on this bucket.

> **Terraform state holds credentials.** It contains SSO connector client
> secrets, which are read at plan time to build the container configuration.
> Enable server-side encryption (SSE-S3 or SSE-KMS), restrict access to the
> Terraform operator, and treat the state file as a secret.

### Route53 hosted zone

Create the hosted zone in this AWS account, then delegate to it from your
registrar or parent zone:

```sh
ZONE_ID=$(aws route53 create-hosted-zone \
  --name "ewake.example.com" \
  --caller-reference "ewake-$(date +%s)" \
  --query 'HostedZone.Id' --output text | sed 's|/hostedzone/||')

aws route53 get-hosted-zone --id "$ZONE_ID" \
  --query 'DelegationSet.NameServers' --output text
```

Add those four NS records at your registrar or parent zone. Confirm delegation
resolves before you apply — certificate validation writes records into this zone
and waits for them, for up to 45 minutes:

```sh
dig +short NS ewake.example.com @8.8.8.8
```

### If you cannot delegate a public zone

ACM validates domain control over **public** DNS. It cannot see a private hosted
zone, or a zone whose parent has not delegated to it. Pointing `hosted_zone_id`
at either does not fail quickly: validation waits for the full timeout, and the
dashboard is unavailable until it completes.

In that case, take DNS out of Terraform:

```hcl
hosted_zone_id      = null
acm_certificate_arn = "arn:aws:acm:eu-west-3:...:certificate/..."
company_host        = "ewake.example.com"
```

Terraform then creates no DNS records and issues no certificate. You own two
things, and the deployment will not warn you if either lapses:

1. **The A record.** Point `company_host` at the `alb_dns_name` output, wherever
   your resolution happens. With `alb_internal = true` the load balancer has
   private addresses, so a private hosted zone is the usual place.
2. **Certificate renewal.** The DNS record that proved control must stay in
   place. ACM re-reads it to renew, about eleven months later. Deleting it
   breaks renewal with no error at apply time.

To issue the certificate, request it in the same region and publish the
validation record wherever your domain resolves publicly. The hostname itself
never needs to be publicly resolvable — only the validation record:

```sh
aws acm request-certificate --region eu-west-3 \
  --domain-name ewake.example.com --validation-method DNS \
  --query CertificateArn --output text

aws acm describe-certificate --region eu-west-3 --certificate-arn "$ARN" \
  --query 'Certificate.DomainValidationOptions[].ResourceRecord'
```

After apply, `terraform output dns_wiring` prints every value the edge depends
on and which half is yours. `terraform output manual_dns_steps` lists what is
still outstanding. Keep that output.

### DLM role, if your account already has one

If this account has ever used AWS Data Lifecycle Manager, it already has the
`AWSDataLifecycleManagerDefaultRole` that this deployment creates, and the first
apply fails with `EntityAlreadyExists`. Import it first:

```sh
aws iam get-role --role-name AWSDataLifecycleManagerDefaultRole \
  && terraform import aws_iam_role.dlm_default AWSDataLifecycleManagerDefaultRole
```

A `NoSuchEntity` response means there is nothing to import. Continue.

## Configuration

Copy `terraform.tfvars.example` to `terraform.tfvars` and fill it in:

```hcl
aws_region  = "eu-west-3"
tenant_name = "yourcompany"

company = {
  name      = "yourcompany"
  public_id = "yourcompany"
  domain    = "yourcompany.com"

  sso_connectors = ["google"]
}

app_image_tag  = "ewake-v0.164.0"
root_domain    = "ewake.example.com"
hosted_zone_id = "Z0123456789ABCDEFGHIJ"
azs            = ["eu-west-3a", "eu-west-3b"]
```

**Naming rules**

- `tenant_name`: lowercase letters and digits only, starts with a letter,
  maximum 21 characters.
- `company.name`: same rules, maximum 33 characters.
- Both are usually your company's short name.

**`app_image_tag` is required and must name a version.** A moving tag such as
`stable` or `latest` is rejected. Only an apply from this repository migrates the
database, and the application refuses to serve a schema older than its own, so a
tag that moves underneath you turns the next task replacement into an outage. See
[Updating](#updating).

**Optional overrides**

| Variable | Default | Notes |
| --- | --- | --- |
| `vpc_cidr` | `10.10.0.0/16` | Change if it overlaps a network you peer with |
| `rds_instance_class` | `db.t4g.small` | Increase for larger teams |
| `rds_multi_az` | `true` | `false` costs less in non-production |
| `neo4j_instance_type` | `t4g.small` | Must be a Graviton (arm64) type |

Choose `vpc_cidr` carefully. Changing it later requires a rebuild, not an
apply: AWS cannot remove a VPC's primary CIDR, and both RDS and the Neo4j
volume are protected against deletion.

> `db.t4g.small` and `t4g.small` are sometimes capacity-constrained. If the
> first apply stalls on RDS or Neo4j with `insufficient-capacity`, use
> `db.t4g.medium` / `t4g.medium`, or different availability zones.

## Private deployments

By default the load balancer is internet-facing and accepts 443 and 80 from
anywhere. To keep the deployment private, set both:

```hcl
alb_internal      = true
alb_ingress_cidrs = ["10.10.0.0/16"]   # your vpc_cidr, or a VPN range
```

Set them together. `alb_internal` moves the load balancer to the private subnets
and removes its public addresses. `alb_ingress_cidrs` is what actually refuses a
packet. Either one alone leaves a gap.

> **Choose `alb_internal` before your first apply. You cannot change it later.**
>
> A load balancer's scheme is immutable in AWS. If you change `alb_internal` on
> a running deployment, Terraform deletes the listeners, then fails to create
> the replacement because the old load balancer still holds the name:
>
> ```
> Error: ELBv2 Load Balancer (<tenant>-tenant-alb) already exists
> ```
>
> The deployment is then down, mid-apply, with no listeners and no new load
> balancer. To recover, delete the load balancer yourself and apply again:
>
> ```sh
> aws elbv2 delete-load-balancer --load-balancer-arn \
>   $(aws elbv2 describe-load-balancers --names <tenant>-tenant-alb \
>       --query 'LoadBalancers[0].LoadBalancerArn' --output text)
> terraform apply
> ```
>
> Do not use `terraform destroy -target=aws_lb.this`. It cascades into the whole
> company module, including the Neo4j volume.
>
> The replacement has a new DNS name and hosted-zone ID. If you own the DNS
> record, repoint it using `terraform output dns_wiring`.

`alb_ingress_cidrs` has none of that cost. It is security-group rules, editable
at any time with no replacement and no downtime. If you are unsure, start
internet-facing and narrow `alb_ingress_cidrs`.

### Connecting your network through a transit gateway

Use this when the deployment is private and your users reach it from your
corporate network or VPN.

```hcl
transit_gateway_id     = "tgw-0123456789abcdef0"
transit_gateway_routes = ["10.38.0.0/23"]   # CIDRs reached through the gateway
alb_ingress_cidrs      = ["10.10.0.0/16", "10.38.0.0/23"]
```

This deployment creates the VPC attachment and adds one route per CIDR to every
private route table. That is one half of the path. The other half belongs to
whoever owns the transit gateway.

**What your network team must provide**

| # | Item | Why |
| - | ---- | --- |
| 1 | The transit gateway shared with this account, through AWS RAM | Terraform cannot attach to a gateway the account cannot see |
| 2 | Acceptance of the VPC attachment this deployment creates | Cross-account attachments are pending until the owner accepts, unless auto-accept is on |
| 3 | Association and propagation for the attachment in the gateway's route table | The owner's side; this deployment does not manage it |
| 4 | A route back to `vpc_cidr` from your network | Without it, requests arrive and replies never return |
| 5 | The client CIDRs, for `transit_gateway_routes` and `alb_ingress_cidrs` | Outbound routes and the security group both need them |
| 6 | DNS resolution for `company_host` to the load balancer's private addresses | A private load balancer is not in public DNS |

Confirm the account can see the gateway before you apply:

```sh
aws ec2 describe-transit-gateways --region eu-west-3 \
  --query 'TransitGateways[].[TransitGatewayId,State,OwnerId]' --output table
```

If the gateway has default route-table association and propagation enabled, AWS
does items 3 and 4 automatically when the attachment is accepted.

Check the attachment state after applying:

```sh
aws ec2 describe-transit-gateway-vpc-attachments --region eu-west-3 \
  --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)" \
  --query 'TransitGatewayVpcAttachments[].[TransitGatewayAttachmentId,State]' --output text
```

`pendingAcceptance` means item 2 is outstanding. `available` means the
attachment is up, which does not by itself prove items 3 and 4 — test with a
request from a client network.

### Inbound webhooks on a private deployment

A private load balancer has no route from the internet, so Slack and Datadog
cannot deliver to it. The dashboard is unaffected, because your users reach it
over your own network. Only integrations that call in need a public entry point.

If you already run one — an API gateway, a reverse proxy, a CDN — point it at
the load balancer and name it:

```hcl
public_inbound_base_url = "https://ewake-inbound.example.com"
```

The Slack manifest and the Datadog webhook are then registered against that URL,
and the dashboard host stays private. Leave it unset when the load balancer is
internet-facing.

If you do not run one, set `public_inbound_gateway = true`. The deployment then
creates an API Gateway that routes only the paths a third party calls. Anything
else returns 404 at the gateway and never reaches the VPC:

| Path | Called by |
| ---- | --------- |
| `POST /api/v1/slack/events` | Slack |
| `POST /api/v1/slack/interactive` | Slack buttons and modals |
| `POST /api/webhook/datadog/{token}` | Datadog monitors |
| `GET /android-chrome-512x512.png` | Slack, rendering a message block |
| `POST /api/v1/events/deployment` | your CI |

The dashboard, the API and SSO are deliberately not routed. Reach those over
your own network.

## First apply

```sh
terraform init \
  -backend-config="bucket=your-company-ewake-state" \
  -backend-config="key=ewake/terraform.tfstate" \
  -backend-config="region=eu-west-3"

terraform plan
terraform apply
```

The first apply takes about 15 to 20 minutes. RDS and Neo4j take most of it.

### The first apply fails once. Run it again.

On a new install, the apply stops on the `db-migrate` task with an error like:

```
Error: local-exec provisioner error
db-migrate exited ... unable to assume the role ...
verify that the role being passed has the proper trust relationship
```

The trust policy the message names is correct. Terraform creates the IAM role
and runs the database migration a few seconds later, before IAM has finished
propagating the role.

Run `terraform apply` again. It continues from where it stopped, and nothing
needs to be changed. This happens on every new install.

If the same error appears on a third apply, it is not this. Check that the
`db-migrate` task role exists and that its trust policy allows
`ecs-tasks.amazonaws.com`.

### After the apply completes

```sh
terraform output dashboard_url
```

That is your dashboard URL. Continue with [Post-install](#post-install).

## Post-install

### 1. Check the dashboard loads

Open `terraform output dashboard_url`. The login screen should appear. If the
page does not load, check that DNS delegation has propagated — certificate
validation can time out silently.

### 2. Configure SSO

Login needs at least one SSO connector. This is two applies with a secret write
in between.

**Step 1 — create the secret.** List the connector ID in `sso_connectors` and
apply:

```hcl
company = {
  # ...
  sso_connectors = ["google"]   # or "okta", "github", and so on
}
```

```sh
terraform apply
```

After this apply the dashboard is up but nobody can log in. The secret holds a
placeholder that is rejected on purpose, and the SSO sidecar exits at startup.
The service still reports healthy. This is expected. Continue to step 2.

**Step 2 — register the application and write the secret.** In your identity
provider, register an OIDC application with this redirect URI:

```
https://<company.name>.<root_domain>/sso/callback
```

Then write the connector JSON to
`ewake/<tenant_name>/<company.name>/sso/<connector-id>`:

```sh
cat > connector.json << 'EOF'
{
  "type": "oidc",
  "id": "google",
  "name": "Google",
  "config": {
    "clientID": "....apps.googleusercontent.com",
    "clientSecret": "...",
    "redirectURI": "https://yourcompany.ewake.example.com/sso/callback",
    "hostedDomains": ["yourcompany.com"]
  }
}
EOF

aws secretsmanager put-secret-value \
  --secret-id "ewake/yourcompany/yourcompany/sso/google" \
  --secret-string file://connector.json
```

**Step 3 — apply again and redeploy.** Terraform reads the real secret and
compiles it into the container configuration:

```sh
terraform apply
aws ecs update-service \
  --cluster <tenant_name> --service <company.name> \
  --task-definition <tenant_name>-<company.name>-reactive \
  --force-new-deployment
```

The login screen now shows your provider.

Your client secret stays in Secrets Manager in your AWS account. It is also
present in the ECS task definition and in Terraform state, because Terraform
reads it at plan time. Protect the state file accordingly.

#### Connector examples

Generic OIDC — Okta, Entra ID, Auth0, Ping:

```json
{
  "type": "oidc",
  "id": "okta",
  "name": "Okta",
  "config": {
    "issuer": "https://yourcompany.okta.com",
    "clientID": "0oa...",
    "clientSecret": "...",
    "redirectURI": "https://yourcompany.ewake.example.com/sso/callback",
    "scopes": ["openid", "profile", "email"]
  }
}
```

For Microsoft Entra, use
`"issuer": "https://login.microsoftonline.com/<tenant-id>/v2.0"`. Use a specific
tenant ID, not `common`.

Google:

```json
{
  "type": "google",
  "id": "google",
  "name": "Google",
  "config": {
    "clientID": "....apps.googleusercontent.com",
    "clientSecret": "...",
    "redirectURI": "https://yourcompany.ewake.example.com/sso/callback",
    "hostedDomains": ["yourcompany.com"]
  }
}
```

GitHub:

```json
{
  "type": "github",
  "id": "github",
  "name": "GitHub",
  "config": {
    "clientID": "...",
    "clientSecret": "...",
    "redirectURI": "https://yourcompany.ewake.example.com/sso/callback"
  }
}
```

GitHub allows one redirect URI per OAuth App, so each deployment needs its own.

### 3. Connect Slack

In the dashboard, open the Slack integration and choose **From a manifest**.
Ewake generates the manifest. Create the app in your Slack workspace from it,
install it, then paste the bot token and signing secret back into the dialog.

Both are stored in Secrets Manager in your account. Inbound Slack events reach
your deployment directly and are signature-verified locally.

### 4. Connect other integrations

Datadog, GitLab, Grafana, Prometheus, Loki, Jira, Linear and PagerDuty connect
from the dashboard using an API token or IAM role that you provide.

Not available in self-hosted deployments yet: GitHub App, GitHub SSO, Microsoft
SSO, Google SSO and Notion. These use OAuth flows whose callback URL is
registered against Ewake-hosted infrastructure.

### 5. Schedule the ambient agents

The ambient agents — knowledge graph, incident indexing, release watch, and the
log, metric and span analysers — are deployed as Lambdas, but their schedules
are created from the dashboard, not by Terraform. A new install has no
schedules. Add them after connecting your integrations.

## Updating

Check out the repository tag you want, set `app_image_tag`, then:

```sh
terraform plan
terraform apply
```

The apply runs database migrations first, as a one-off ECS task, then rolls the
service. Both steps are skipped when the image tag has not changed.

`app_image_tag` pins the server, its database migrations and every Lambda, so
the deployment moves as one version. It does not pin the sidecars — the SSO
sidecar, CloudWatch MCP and log clustering track `latest`.

Each release of this repository states the minimum application version it needs.
Upgrade the repository and the image together.

To roll back, set `app_image_tag` to the previous version and apply. Note that
database migrations are not reversed, so roll back to a version whose schema the
database still satisfies.

Some upgrades need a one-time step before the apply succeeds, and changing the
hostname of a running deployment is a two-apply procedure. Both are in
[UPGRADING.md](UPGRADING.md).

## Tearing down

`terraform destroy` alone does not work. Three resources are protected against
deletion.

1. **Disable RDS deletion protection:**

   ```sh
   aws rds modify-db-instance \
     --db-instance-identifier <tenant_name> \
     --no-deletion-protection --apply-immediately
   ```

2. **Remove `prevent_destroy`** from the Neo4j EBS volume
   (`modules/company_stack/neo4j.tf`) and the DLM role (`dlm.tf`). Comment out
   the `lifecycle` blocks for the duration of the destroy. Take a snapshot first
   if the graph data matters.

3. **Run `terraform destroy`.** Allow about 45 minutes.

   Most of that time is outside Terraform's control. AWS releases Lambda network
   interfaces 20 to 40 minutes after the functions are deleted, and nothing —
   security groups, subnets, the VPC — can be deleted until they are gone.
   Terraform also times out after 10 minutes waiting for VPC endpoints that AWS
   is still deleting. That is a timeout, not a failure: run `terraform destroy`
   again and it finishes in seconds.

4. **Clean up manually.** These are not in Terraform state:

   - CloudWatch log groups recreated mid-destroy by ECS and Lambda
   - Secrets Manager entries, which keep a 30-day recovery window
   - The Route53 hosted zone, created outside Terraform
   - The state bucket

> **Delete the integration secrets if you intend to reinstall.** They are named
> `ewake/<tenant_name>/<company.name>/integrations/...` and they outlive the
> database. A reinstall writes new ones, and the old entries remain in their
> recovery window, where they can block a later install that wants the same
> name. Use `aws secretsmanager delete-secret --force-delete-without-recovery`
> if you are sure.

## Support

Contact Ewake with your `tenant_name`, the repository tag and the
`app_image_tag` you are running, plus the failing `terraform plan` or `apply`
output.
