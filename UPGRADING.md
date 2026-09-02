# Upgrading a running deployment

These procedures apply to an existing deployment. None are needed for a new
install — see [README.md](README.md).

Read the release notes for every tag between your current version and the one
you are moving to. Each states the minimum application version it needs.

Always run `terraform plan` first and read it. Anything that destroys or
replaces RDS, the Neo4j volume or the load balancer needs attention before you
continue. Contact Ewake if the plan does.

## Changing the hostname

Use two applies. The first adds the new name, the second removes the old one.

**1. Serve both names.** Leave `root_domain`, `hosted_zone_id` and
`company_host` as they are, and add:

```hcl
extra_certificate_arns = ["arn:...:certificate/<cert for the new name>"]
alb_extra_host_headers = ["new.example.com"]
```

Both are needed. The certificate makes the TLS handshake succeed; the host
header makes the request route.

**2. Remove the old name.** Once the new hostname works, set `company_host` to
it and empty both variables above.

## The plan wants to replace the RDS subnet group

A deployment first applied before this repository moved to generated names has a
subnet group named exactly `<tenant_name>`, and the plan wants to replace it.
RDS refuses to move a live Multi-AZ instance.

Keep the existing name:

```sh
terraform state show aws_db_subnet_group.this | grep '^\s*name '
```

```hcl
rds_subnet_group_name = "<that name>"
```

The replacement disappears and the database is untouched. Leave the variable
unset on newer deployments.

## One-time: deployments first applied before v1.0.0

Only if the last apply predates the v1.0.0 tag. Check with
`terraform state list | grep aws_route.` — if that prints nothing, this applies
to you.

v1.0.0 moved the default routes into standalone `aws_route` resources, so the
apply fails with `RouteAlreadyExists`.

**Do the two state moves first.** Terraform migrates `this` to `this[0]` during
plan and apply, but not during import:

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
order of `azs`. Read the IDs from state, not from the console.

`terraform plan` should then show no route creations. The ALB security group is
replaced during this upgrade, which takes seconds.

## One-time: deployments first applied before application version v0.150.0

Only if this deployment was first applied before v0.150.0. A new deployment
already uses the bundled image.

The nine scheduled Lambdas each used their own ECR repository. They now share
one image. The old repositories have been deleted, so any apply touching these
functions fails until they are replaced.

```sh
terraform apply $(for l in \
  datadog-log-analysis loki-log-analysis datadog-metric-analysis \
  datadog-span-analysis knowledge-graph incident-indexing \
  release-watch custom-mcp-discovery kubernetes-discovery; do
    printf ' -replace=module.company.module.scheduled_lambdas.aws_lambda_function.%s' "${l//-/_}"
  done)
```

The plan should show nine functions replaced and nothing else. Each is recreated
under the same name and schedule. Expect a cold start on the next scheduled run.
