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
| 6 | Network access to the deployment, if it is private |

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

app_image_tag  = "ewake-v0.164.0"
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

| Variable | Default | Notes |
| --- | --- | --- |
| `vpc_cidr` | `10.10.0.0/16` | Changing it later needs a rebuild, not an apply |
| `rds_instance_class` | `db.t4g.small` | Increase for larger teams |
| `rds_multi_az` | `true` | `false` costs less in non-production |
| `neo4j_instance_type` | `t4g.small` | Must be a Graviton (arm64) type |

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

GitHub App, GitHub SSO, Microsoft SSO, Google SSO and Notion are not available
in self-hosted deployments yet.

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
