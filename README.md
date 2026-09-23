# Ewake — self-hosted deployment

Terraform to deploy Ewake into your own AWS account: your VPC, your RDS, your
ECS cluster, your Neo4j volume.

The deployment pulls container images and frontend assets from Ewake's ECR and
S3. Ewake grants your account access before your first apply. Nothing else
leaves your account at runtime.

Application documentation is at [docs.ewake.ai](https://docs.ewake.ai/).
For upgrades of an existing deployment, see [UPGRADING.md](UPGRADING.md).

## Prerequisites

| # | What you need |
| - | ------------- |
| 1 | Terraform >= 1.10 and the AWS CLI, authenticated as the same principal |
| 2 | A dedicated AWS account in `eu-west-3` |
| 3 | A domain delegated to a Route53 hosted zone in that account |
| 4 | An OIDC identity provider |
| 5 | Bedrock model access in `eu-west-3` |
| 6 | A Lambda memory quota of 10240 MB |
| 7 | Network access to the deployment, if it is private |

**Region.** `eu-west-3` (Paris) is the only supported region. Terraform rejects
any other at `plan`. Contact Ewake if you need a different one.

**Domain.** For example `ewake.example.com`. The install creates an ACM
certificate and validates it against the zone. If you cannot delegate a public
zone to this account, contact Ewake.

**Identity provider.** Okta, Entra ID, Google Workspace, Auth0, or any
spec-compliant OIDC provider. You can also start without one: Ewake then serves
a username and password form, and Terraform generates an admin password into
Secrets Manager under `ewake/<tenant_name>/<company.name>/app`, key
`ADMIN_PASSWORD`.

**Bedrock.** Contact Ewake for the current list of models. Your AWS account
owner must accept the Marketplace agreement for each one, because that accepts
the vendor's licence terms for your account. Enable all of them.

**Lambda memory quota.** A new AWS account caps Lambda memory at 3008 MB. The
Lambda that runs investigations is sized at the 10240 MB maximum, because an
investigation can fan out to sub-agents and its peak demand is not knowable in
advance. On a capped account the apply fails with

```
ValidationException: 'MemorySize' value failed to satisfy constraint:
Member must have value less than or equal to 3008
```

Raise it before you apply — AWS Support, **Service limit increase → Lambda**,
asking for a function memory limit of 10240 MB in `eu-west-3`. It is usually
granted the same day.

AWS does not expose this limit through an API, so there is no command that
answers it directly. A useful hint is the account's concurrency, which AWS
restricts alongside memory on a new account:

```sh
aws lambda get-account-settings --query 'AccountLimit.ConcurrentExecutions'
```

`1000` is the unrestricted default. Anything lower means the account is still
capped, and its memory limit is almost certainly 3008 as well.

If you cannot raise it, set `reactive_lambda_memory_mb = 3008` and apply. The
deployment works, but a large investigation may still run out of memory. Raise
the quota and then the variable when you can.

**Network access.** Only if you set `alb_internal = true`. See
[Private deployments](#private-deployments).

## Setup

### State bucket

Terraform needs a versioned S3 bucket for state before `init`:

```sh
export AWS_REGION=eu-west-3
aws s3 mb "s3://your-company-ewake-state" --region "$AWS_REGION"
aws s3api put-bucket-versioning \
  --bucket "your-company-ewake-state" \
  --versioning-configuration Status=Enabled
```

The Terraform principal needs `s3:GetObject`, `s3:PutObject` and
`s3:DeleteObject` on this bucket.

> **Terraform state holds credentials**, including SSO client secrets. Enable
> server-side encryption, restrict access to the Terraform operator, and treat
> the state file as a secret.

### Route53 hosted zone

Create the zone in this account, then delegate to it from your registrar or
parent zone:

```sh
ZONE_ID=$(aws route53 create-hosted-zone \
  --name "ewake.example.com" \
  --caller-reference "ewake-$(date +%s)" \
  --query 'HostedZone.Id' --output text | sed 's|/hostedzone/||')

aws route53 get-hosted-zone --id "$ZONE_ID" \
  --query 'DelegationSet.NameServers' --output text
```

Add those four NS records at your registrar. Confirm delegation resolves before
you apply — certificate validation waits for it:

```sh
dig +short NS ewake.example.com @8.8.8.8
```

### DLM role

If this account has ever used AWS Data Lifecycle Manager, the role already
exists and the first apply fails with `EntityAlreadyExists`. Import it first:

```sh
aws iam get-role --role-name AWSDataLifecycleManagerDefaultRole \
  && terraform import aws_iam_role.dlm_default AWSDataLifecycleManagerDefaultRole
```

`NoSuchEntity` means there is nothing to import.

## Configuration

Copy `terraform.tfvars.example` to `terraform.tfvars`:

```hcl
aws_region  = "eu-west-3"
tenant_name = "yourcompany"

company = {
  name      = "yourcompany"
  public_id = "yourcompany"
  domain    = "yourcompany.com"

  sso_connectors = ["google"]
}

app_image_tag  = "ewake-v0.189.0"
root_domain    = "ewake.example.com"
hosted_zone_id = "Z0123456789ABCDEFGHIJ"
azs            = ["eu-west-3a", "eu-west-3b"]
```

`tenant_name` and `company.name` are lowercase letters and digits only, starting
with a letter. Maximum 21 and 33 characters.

`app_image_tag` is required and must name a version. A moving tag such as
`stable` is rejected: only an apply from this repository migrates the database,
and the application refuses to serve an older schema. Each release of this
repository states the minimum version it needs.

Name a recent build rather than copying the line above unchanged. Ewake keeps a
limited number of them, so a version eventually stops being pullable and an
apply pinned to it fails — the release notes list what is current.

| Variable | Default | Notes |
| --- | --- | --- |
| `vpc_cidr` | `10.10.0.0/16` | Changing it later needs a rebuild, not an apply |
| `rds_instance_class` | `db.t4g.small` | Increase for larger teams |
| `rds_multi_az` | `true` | `false` costs less in non-production |
| `neo4j_instance_type` | `t4g.small` | Must be a Graviton (arm64) type |

## Cost options

Two settings exist only to let you trade cost against something you may not
need. Both are safe to leave alone.

`container_insights` sends the ECS Container Insights metrics, billed per metric
series. It is `false`, because nothing in this deployment reads them. Per-task
CPU and memory come from the free `AWS/ECS` namespace either way, so turning it
on buys the per-container breakdown in the ECS console and nothing else.

`vpc_interface_endpoints` carries this deployment's AWS API calls — SSM, Secrets
Manager, ECR and CloudWatch Logs — over PrivateLink endpoints inside the VPC.
It is `true`, because it is the only path that works when egress through the NAT
gateway is filtered, and SSM is how you reach a private deployment at all. Each
endpoint bills hourly in every availability zone you run.

Set it to `false` only when egress from the private subnets is unrestricted. The
same calls then go out through the NAT gateway, which charges for data processed
rather than by the hour, so image pulls move from free to metered. If you are
unsure whether your egress is filtered, leave it on: the failure mode is a
deployment that cannot pull an image or reach Secrets Manager, and you will meet
it on the next task replacement rather than at apply time.

## Private deployments

By default the load balancer is internet-facing. To keep the deployment private,
set both:

```hcl
alb_internal      = true
alb_ingress_cidrs = ["10.10.0.0/16"]   # your vpc_cidr, or a VPN range
```

`alb_internal` moves the load balancer to the private subnets.
`alb_ingress_cidrs` is what refuses a packet. Either one alone leaves a gap.

> **Choose `alb_internal` before your first apply.** A load balancer's scheme is
> immutable in AWS and cannot be changed on a running deployment. Contact Ewake
> if you need to change it. `alb_ingress_cidrs` can be edited at any time.

### Transit gateway

Use this when the deployment is private and users reach it from your corporate
network or VPN.

```hcl
transit_gateway_id     = "tgw-0123456789abcdef0"
transit_gateway_routes = ["10.38.0.0/23"]
alb_ingress_cidrs      = ["10.10.0.0/16", "10.38.0.0/23"]
```

This deployment creates the VPC attachment and adds a route per CIDR to every
private route table. The gateway owner provides the rest:

1. The transit gateway, shared with this account through AWS RAM.
2. Acceptance of the VPC attachment this deployment creates.
3. Association and propagation for the attachment in the gateway's route table.
4. A route back to `vpc_cidr` from your network.
5. The client CIDRs, for `transit_gateway_routes` and `alb_ingress_cidrs`.
6. DNS resolution for `company_host` to the load balancer's private addresses.

Items 3 and 4 are automatic if the gateway has default route table association
and propagation enabled. `terraform output vpc_id` and
`terraform output vpc_cidr` give the values the gateway owner needs.

### Deploying into a VPC you already have

Everything above assumes this deployment builds its own VPC. If your addressing
is planned centrally — a landing zone, a network account, ranges that must not
collide with production — supply a VPC instead and it will build none:

```hcl
existing_network = {
  vpc_id             = "vpc-0123456789abcdef0"
  private_subnet_ids = ["subnet-0aaa...", "subnet-0bbb..."]

  # Optional. Only used for the S3 gateway endpoint, which is skipped without
  # them rather than writing routes into tables you did not name.
  private_route_table_ids = ["rtb-0aaa...", "rtb-0bbb..."]
}

alb_internal      = true
alb_ingress_cidrs = ["10.0.0.0/8"]   # the ranges your users reach it from
```

No VPC, subnets, internet gateway, NAT gateways, route tables or routes are
created. `azs`, `vpc_cidr` and `transit_gateway_id` stop applying — the zones
come from the subnets you name, the addressing is yours, and attaching the VPC
to your network is something you have already done. Setting
`transit_gateway_id` in this mode is refused rather than ignored.

What the subnets have to provide, none of which this deployment can check for
you:

1. **Egress.** Private subnets with a route to the internet or to an approved
   proxy. Images are pulled from Ewake's registry, Bedrock is called for every
   agent run, and connected integrations are reached outbound. No NAT gateway is
   created here. Without egress nothing starts, and the first symptom is an
   image pull timeout that reads like a permissions problem.
2. **Two availability zones.** At least one private subnet in each. The load
   balancer and the database both require it. Checked at plan.
3. **Free addresses.** Eight per subnet for the load balancer, plus one per ECS
   task and per Lambda ENI. A subnet with a handful left will fail at apply.
4. **A route in, and back out.** However users reach the dashboard — VPN,
   transit gateway, peering — the deployment's subnets have to be on it.

Interface endpoints are off by default in this mode: a VPC like this usually has
them already, and AWS refuses a second endpoint for the same service with
private DNS enabled. Set `vpc_interface_endpoints = true` if yours does not have
them and egress is filtered.

Every CIDR on the VPC is admitted to the security groups, not just the primary,
so a secondary range works without further configuration.

> **This is a first-apply decision.** Moving a running deployment into a
> different VPC replaces its subnets, and with them the load balancer, the
> database and the graph store. It is a rebuild, not an apply. Contact Ewake
> before attempting it.

### Inbound webhooks

A private load balancer has no route from the internet, so Slack and Datadog
cannot deliver to it. The dashboard is unaffected.

If you already run a public entry point, point it at the load balancer and name
it:

```hcl
public_inbound_base_url = "https://ewake-inbound.example.com"
```

Otherwise set `public_inbound_gateway = true`. The deployment then creates an
API Gateway that routes only these paths. Anything else returns 404:

| Path | Called by |
| ---- | --------- |
| `POST /api/v1/slack/events` | Slack |
| `POST /api/v1/slack/interactive` | Slack buttons and modals |
| `POST /api/webhook/datadog/{token}` | Datadog monitors |
| `GET /android-chrome-512x512.png` | Slack, rendering a message block |
| `POST /api/v1/events/deployment` | your CI |

The dashboard, the API and SSO are not routed. Reach those over your own
network.

## First apply

```sh
terraform init \
  -backend-config="bucket=your-company-ewake-state" \
  -backend-config="key=ewake/terraform.tfstate" \
  -backend-config="region=eu-west-3"

terraform plan
terraform apply
```

The first apply takes about 15 to 20 minutes.

> **On a new install the first apply fails once**, on the `db-migrate` task,
> with an error about assuming a role. The role is correct; IAM has not finished
> propagating it. Run `terraform apply` again. If it fails a third time, contact
> Ewake.

When it completes, `terraform output dashboard_url` is your dashboard URL.

## Post-install

### Configure SSO

Login needs at least one SSO connector. This is two applies with a secret write
in between.

**1. Create the secret.** List the connector ID in `sso_connectors` and apply.
The dashboard comes up, but nobody can log in yet. This is expected.

```hcl
company = {
  # ...
  sso_connectors = ["google"]   # or "okta", "github"
}
```

**2. Register the application and write the secret.** In your identity provider,
register an OIDC application with this redirect URI:

```
https://<company.name>.<root_domain>/sso/callback
```

Then write the connector JSON to
`ewake/<tenant_name>/<company.name>/sso/<connector-id>`:

```sh
cat > connector.json << 'EOF'
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
EOF

aws secretsmanager put-secret-value \
  --secret-id "ewake/yourcompany/yourcompany/sso/okta" \
  --secret-string file://connector.json
```

Use `"type": "google"` or `"type": "github"` for those providers. For Microsoft
Entra, use `"issuer": "https://login.microsoftonline.com/<tenant-id>/v2.0"` with
a specific tenant ID, not `common`.

**3. Apply again and redeploy:**

```sh
terraform apply
aws ecs update-service \
  --cluster <tenant_name> --service <company.name> \
  --task-definition <tenant_name>-<company.name>-reactive \
  --force-new-deployment
```

### Connect integrations

Slack, Datadog, GitLab, Grafana, Prometheus, Loki, Jira, Linear and PagerDuty
are configured from the dashboard. See [docs.ewake.ai](https://docs.ewake.ai/).

Credentials are stored in Secrets Manager in your account.

Notion connects with a workspace access token pasted into the dashboard, the
same as the tools above.

GitHub SSO, Microsoft SSO and Google SSO are not available as *integrations* in
self-hosted deployments yet. They are unrelated to signing in, which uses your
own OIDC provider — see Prerequisites.

#### GitHub

GitHub is read through a GitHub App installed on your organisation. There is no
token form: reads use installation tokens, minted on demand and never stored.

There are two ways to get the App, and you do not have to choose before you
apply.

**Register it from the dashboard (no Terraform).** Go to **Integrations →
GitHub**, give it your organisation login, and the dashboard sends you to GitHub
with a prepared manifest. GitHub creates the App and hands the credentials back
to your deployment, which writes them to
`ewake/<tenant_name>/<company.name>/github-app` in your own account. No private
key ever passes through Terraform, your state file, or whoever runs the apply.
Registering an App this way needs no apply and no restart.

**Or seed it from Terraform**, if you already have an App you want to reuse:

```hcl
github_app_client_id = "Iv23li..."
github_app_slug      = "yourcompany-ewake"

github_app_private_key = <<-EOT
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA...
-----END RSA PRIVATE KEY-----
EOT
```

A `.tfvars` file takes literal values only — `file()` and every other function
is rejected there with `Error: Function calls not allowed` — so paste the PEM as
a heredoc. To keep it in its own file, pass it through the environment instead:

```sh
export TF_VAR_github_app_private_key="$(cat yourcompany-ewake.private-key.pem)"
terraform apply
```

Set all three or none. One or two fails the plan rather than half-enabling the
feature. The private key reaches Terraform state, so the backend holding that
state wants encryption and restricted reads — which is the reason to prefer
registering from the dashboard.

Either way, once the App exists the GitHub card gains an **Install** action.
Install it on the organisation, not on your user account: the deployment reads
an organisation and refuses a personal installation.

Requires `app_image_tag` at `ewake-v0.182.0` or later.

#### CloudWatch

Reading CloudWatch logs and metrics needs a sidecar container. It is off by
default because it runs permanently alongside the dashboard.

The sidecar does not read CloudWatch with the task's own permissions. It asks
the dashboard which roles to assume, and the dashboard answers with the
CloudWatch integrations you have connected.

**Connect the integration first, then turn the sidecar on.** In that order:

1. Create the role described below.
2. In the dashboard, go to **Integrations → CloudWatch** and connect it with the
   role ARN, your external ID, and the region.
3. Then set the flag and apply:

   ```hcl
   company = {
     # ...
     features = {
       cloudwatchMcpSidecar = true
     }
   }
   ```

<!-- prettier-ignore -->
> **The order matters.** The sidecar asks the dashboard for its configuration on
> startup, and gives up if the answer is that no integration exists. Started
> first, it stops within a second and is not restarted — and connecting an
> integration afterwards does not bring it back. Nothing else breaks if you get
> this wrong: the container is not essential, so the dashboard is unaffected.
> Connect the integration, then force a new deployment of the reactive service:
>
> ```sh
> aws ecs update-service \
>   --cluster <tenant_name> --service <company.name> \
>   --force-new-deployment
> ```

The role is yours to create, in whichever account holds the logs you want read.
Two requirements:

- **Its name must start with `EwakeCloudWatchReadOnly`.** The task role is
  allowed to assume that prefix and nothing else.
- **Its trust policy must allow the deployment's task role**, which is
  `arn:aws:iam::<account>:role/<tenant_name>-<company.name>-task`, with a
  `sts:ExternalId` condition matching the external ID you enter in the
  dashboard. Generate that value yourself; it is a shared secret, not an
  identifier.

`CloudWatchReadOnlyAccess` and `CloudWatchLogsReadOnlyAccess` are enough to
attach to it.

### Schedule the ambient agents

Ambient agents are deployed as Lambdas, but their schedules are created from the
dashboard, not by Terraform. A new install has no schedules. See
[docs.ewake.ai](https://docs.ewake.ai/).

## Updating

Check out the repository tag you want, set `app_image_tag` to the version its
release notes require, then:

```sh
terraform plan
terraform apply
```

The apply runs database migrations first, then rolls the service. Both are
skipped when the image tag has not changed.

`app_image_tag` pins the server, its migrations and every Lambda, so the
deployment moves as one version. It does not pin the sidecars.

Read [UPGRADING.md](UPGRADING.md) before upgrading an existing deployment, and
always read the plan before applying.

## Tearing down

1. Disable RDS deletion protection:

   ```sh
   aws rds modify-db-instance \
     --db-instance-identifier <tenant_name> \
     --no-deletion-protection --apply-immediately
   ```

2. Remove the `prevent_destroy` lifecycle blocks from the Neo4j EBS volume
   (`modules/company_stack/neo4j.tf`) and the DLM role (`dlm.tf`). Snapshot the
   volume first if the graph data matters.

3. Run `terraform destroy`. Allow about 45 minutes: AWS releases Lambda network
   interfaces slowly, and nothing in the VPC can be deleted until they are gone.
   Run it again if it times out waiting for VPC endpoints.

4. Delete manually, because they are not in Terraform state:

   - CloudWatch log groups recreated during the destroy
   - Secrets Manager entries, which keep a 30-day recovery window
   - The Route53 hosted zone
   - The state bucket

   Delete the integration secrets under
   `ewake/<tenant_name>/<company.name>/integrations/` if you intend to
   reinstall. They outlive the database and can block a later install.

## Support

Contact Ewake with your `tenant_name`, the repository tag, the `app_image_tag`
you are running, and the failing `terraform plan` or `apply` output.
