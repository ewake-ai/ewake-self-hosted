# Upgrading a running deployment

These procedures apply to an existing deployment. None are needed for a new
install — see [README.md](README.md).

Read the release notes for every tag between your current version and the one
you are moving to. Each states the minimum application version it needs.

Always run `terraform plan` first and read it. Anything that destroys or
replaces RDS, the Neo4j volume or the load balancer needs attention before you
continue. Contact Ewake if the plan does.

## Nothing to do: the GitHub App and the CloudWatch sidecar

Both are new opt-in features, and both stay off unless you turn them on. An
existing deployment plans and applies with no change, and neither adds a
required variable. README → "Connect integrations" covers what each one does.

One variable was removed rather than renamed: `github_app_secret_arn`. It was
always null here, so no `terraform.tfvars` should name it. If yours does, delete
the line before applying — Terraform refuses an undeclared variable.

## One-time: the scheduled Lambdas become one function

Applies to any deployment first applied before this release. One apply, no manual
steps. It needs `app_image_tag = "ewake-v0.176.0"` or later.

The twelve scheduled Lambdas are now one `<tenant_name>-<company.name>-scheduled`
function; which agent runs is named in the schedule's payload rather than by the
function it targets. Your schedules were created from the dashboard, so Terraform
does not own them and does not repoint them — the dashboard service does, when it
restarts during this apply. It reads each schedule's payload, so it can repoint a
schedule whether or not the function it used to point at still exists.

```sh
terraform apply
```

**Two things to know before you run it.**

The plan destroys twelve functions **and their twelve log groups**. The ambient
agents' log history goes with them. Export anything you still need first — this is
the only irreversible part of the upgrade.

Ambient agents may miss one run. Between the old functions being destroyed and the
dashboard service finishing its restart, a schedule that fires has nowhere to go.
The agents are cron-driven, so this costs at most a run or two, and the following
one lands normally.

Afterwards, confirm the schedules moved:

```sh
aws scheduler get-schedule --group-name "<tenant_name>-<company.name>" \
  --name lambda-knowledge-graph-default \
  --query 'Target.Arn' --output text
```

The ARN must end in `-scheduled`. If it still names a per-agent function, contact
Ewake with that output.

A schedule whose payload does not name a known agent is left alone, by design.
Those are hand-made and have to be recreated on the dashboard.

## The bootstrap and log-clustering Lambdas now follow app_image_tag

No action, but expect two extra function updates in the plan.

Both used to track a floating `:latest` tag with the image ignored in their
lifecycle, which meant neither ever moved: a container image tag resolves to a
digest once, when the function is created, so an install kept its original copy no
matter how many releases went by. They are now pinned to `app_image_tag` like every
other runtime, and the apply updates them.

This is what makes the seeding change below safe. From `ewake-v0.168.0` the company
row and the `ewake@ewake.ai` user are written by the RDS bootstrap Lambda rather
than by the migrate task — so a deployment still carrying a pre-v0.168.0 copy of
that function would have failed the apply that first called it.

## Seeding moved out of the migrate task

No action, but worth knowing why the plan changes. On an existing deployment both
rows are already there and the invocation is create-only, so nothing re-runs.

The coupling is strict in the other direction: **this repository at this tag cannot
run an image older than `ewake-v0.168.0`**. The migrate task no longer receives
`COMPANY_DOMAIN` or `ADMIN_PASSWORD`, which an older image's seed step requires, so
it would fail before the first migration chain.

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
