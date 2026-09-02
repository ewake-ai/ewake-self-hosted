# Upgrading and reshaping a running deployment

Procedures that apply to an existing deployment. None of them are needed for a
new install — see [README.md](README.md) for that.

- [Changing the hostname](#changing-the-hostname-of-a-running-deployment)
- [An upgrade plans to replace the RDS subnet group](#if-an-upgrade-plans-to-replace-the-rds-subnet-group)
- [Deployments first applied before v1.0.0](#one-time-deployments-first-applied-before-v100)
- [Deployments first applied before application version v0.150.0](#one-time-deployments-first-applied-before-application-version-v01500)

Read the release notes for every tag between your current version and the one
you are moving to. Each states the minimum application version it needs.

## Before any upgrade

```sh
terraform plan
```

Read the plan before applying. Anything that destroys or replaces RDS, the Neo4j
volume or the load balancer needs attention before you continue, not after.

## Changing the hostname of a running deployment

Use two applies, never one. The first adds the new name; the second removes the
old one once you have confirmed the new one works.

**Apply 1 — serve both names.** Leave `root_domain`, `hosted_zone_id` and
`company_host` as they are, and add:

```hcl
extra_certificate_arns = ["arn:...:certificate/<cert for the new name>"]
alb_extra_host_headers = ["new.example.com"]
```

Both are needed. `extra_certificate_arns` makes the TLS handshake succeed on the
new name; `alb_extra_host_headers` makes the request route. A certificate
without a host header gives a successful handshake followed by `404 no route`,
which looks like a working migration until someone tries it.

**Apply 2 — remove the old name.** Once the new hostname works, set
`company_host` to it and empty both variables above.

## If an upgrade plans to replace the RDS subnet group

A deployment first applied before this repository moved to generated names has a
subnet group named exactly `<tenant_name>`. Current Terraform generates
`<tenant_name>-<suffix>`, so the plan wants to replace the group and move the
live database onto the new one. RDS refuses:

```
Error: updating RDS DB Instance (<tenant>): api error InvalidParameterCombination:
You cannot move a DB instance with Multi-Az enabled to a VPC
```

Nothing about the group needs to change, only the form of its name. Keep the
existing one:

```sh
terraform state show aws_db_subnet_group.this | grep '^\s*name '

# or, if state is unavailable:
aws rds describe-db-instances --db-instance-identifier <tenant_name> \
  --query 'DBInstances[0].DBSubnetGroup.DBSubnetGroupName' --output text
```

```hcl
rds_subnet_group_name = "<that name>"
```

The replacement disappears and the database is untouched. Leave this variable
unset on newer deployments.

## One-time: deployments first applied before v1.0.0

Only needed if the last apply predates the v1.0.0 tag. Check with
`terraform state list | grep aws_route.` — if that prints nothing, this applies
to you. Skip it on a new deployment.

v1.0.0 moved the default routes into standalone `aws_route` resources and put
the certificate behind a `count`. Terraform cannot tell that the routes it wants
already exist, so the apply fails:

```
Error: creating Route in Route Table (rtb-...): RouteAlreadyExists
```

**Do the two state moves first.** Terraform migrates `this` to `this[0]` during
plan and apply, but not during import, so importing first fails with
`aws_acm_certificate.this is empty tuple`:

```sh
terraform state mv 'aws_acm_certificate.this'            'aws_acm_certificate.this[0]'
terraform state mv 'aws_acm_certificate_validation.this' 'aws_acm_certificate_validation.this[0]'
```

Then read your route table IDs from state and import the default route from
each:

```sh
terraform state show aws_route_table.public       | grep -m1 '^    id'
terraform state show 'aws_route_table.private[0]' | grep -m1 '^    id'
terraform state show 'aws_route_table.private[1]' | grep -m1 '^    id'

terraform import 'aws_route.public_default'     '<public-rtb-id>_0.0.0.0/0'
terraform import 'aws_route.private_default[0]' '<private-rtb-id-0>_0.0.0.0/0'
terraform import 'aws_route.private_default[1]' '<private-rtb-id-1>_0.0.0.0/0'
```

`private_default[N]` matches `aws_route_table.private[N]`, which follows the
order of `azs`. Read the IDs from state rather than guessing from the console.

`terraform plan` should then show no route creations.

The ALB security group is replaced during this upgrade, because its description
changed and descriptions are immutable in AWS. This is expected and takes
seconds.

## One-time: deployments first applied before application version v0.150.0

Only needed if this deployment was first applied before v0.150.0. A new
deployment already uses the bundled image. Skip it.

The nine scheduled Lambdas each used their own ECR repository. They now share
one image and select their handler from it. The old repositories have been
deleted, and AWS Lambda re-validates the current code artifact on every
configuration change, so a function still pointing at a deleted repository
cannot be updated at all. Any apply touching these functions fails with:

```
Error: updating Lambda Function (<tenant>-<company>-knowledge-graph) configuration:
ResourceConflictException: ... AWS Lambda does not have permission to access the
provided code artifact. Please configure the required permissions in the ECR repository.
```

The message names ECR permissions, but the grant is correct — the repository no
longer exists. Replace the functions once:

```sh
terraform apply $(for l in \
  datadog-log-analysis loki-log-analysis datadog-metric-analysis \
  datadog-span-analysis knowledge-graph incident-indexing \
  release-watch custom-mcp-discovery kubernetes-discovery; do
    printf ' -replace=module.company.module.scheduled_lambdas.aws_lambda_function.%s' "${l//-/_}"
  done)
```

The plan should show nine functions replaced and nothing else. Each is recreated
under the same name and schedule, and the EventBridge rules are untouched.
Expect a cold start on the next scheduled run.

Verify afterwards:

```sh
aws lambda get-function --function-name <tenant_name>-<company.name>-knowledge-graph \
  --query 'Code.ImageUri' --output text
# → ...amazonaws.com/ewake-lambdas:<app_image_tag>
```

If a function still names `ewake-lambda-knowledge-graph`, re-run the replace.
