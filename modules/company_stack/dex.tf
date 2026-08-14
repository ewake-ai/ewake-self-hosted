# Dex, the identity provider, as a sidecar of the reactive task.
#
# Not a service of its own and not shared across companies: customers self-host
# reactive without an orchestrator, so nothing in the login path may live outside this
# task. Dex binds loopback in the shared network namespace and reactive proxies /dex to
# it, which is also the URL its issuer claims.
#
# Unconditional, with no feature flag — after this it is the only way anyone logs in,
# so a per-company toggle would only encode a broken state.

locals {
  # The origin the BROWSER drives the OIDC hops against, and what a provider's redirect URI
  # is registered against. The orchestrator where there is one, so a provider that allows a
  # single redirect URI serves the whole fleet from one registration; it then routes each
  # callback back to this company. That makes the orchestrator load-bearing for login.
  #
  # byoc has no orchestrator, so it falls through to the company's own host and the login
  # path stays self-contained — which is why the sidecar exists at all.
  dex_base_url = coalesce(
    var.sso_base_url,
    var.orchestrator_url,
    local.company_base_url
  )

  # The connectors compiled into the one array both containers read. Assembling here rather
  # than letting ECS resolve a secret is a deliberate trade: valueFrom maps one variable to
  # one secret and cannot concatenate, so a per-connector layout means terraform reads the
  # values. They therefore appear in the task definition and in terraform state, where the
  # aggregate secret never put them — treat state as holding customer OAuth credentials.
  dex_connectors = jsonencode([
    for id in var.company.sso_connectors :
    jsondecode(data.aws_secretsmanager_secret_version.sso_connector[id].secret_string)
  ])

  # Not a secret: it only names reactive's client registration inside Dex. The matching
  # secret is DEX_CLIENT_SECRET, below.
  dex_client_id = "ewake-reactive"

  # Both containers need it, and where it lives depends on the deployment mode: byoc has
  # no shared secret, so it reads the per-company `app` secret alongside JWT_SECRET;
  # saas reads the dedicated vendor secret, the same shape jwt.tf and google.tf use.
  dex_client_secret_value_from = local.is_byoc ? "${one(aws_secretsmanager_secret.app[*].arn)}:DEX_CLIENT_SECRET::" : "${var.dex_secret_arn}:SECRET::"

  dex_containers = [{
    name  = "dex"
    image = "${var.ecr_repository_urls["dex-sidecar"]}:latest"
    # Dex being down breaks new logins but not the dashboard for anyone already holding
    # a session, so it must not take the task down with it.
    essential = false
    restartPolicy = {
      enabled              = true
      restartAttemptPeriod = 60
    }
    # No portMappings: loopback only, so the port is never routable outside the task.
    environment = [
      # Origin only. sidecars/dex/config.yaml appends /sso for the issuer and reactive's
      # callback path for the redirect, so nothing here assembles either — the same value
      # reaches reactive as SSO_BASE_URL in ecs_task.tf, which is what makes the two agree.
      { name = "SSO_BASE_URL", value = local.dex_base_url },
      # The same array reactive receives, so the login page cannot offer a connector Dex
      # does not serve.
      { name = "DEX_CONNECTORS", value = local.dex_connectors },
      { name = "DEX_CLIENT_ID", value = local.dex_client_id },
      # Dex has no schema option of its own and creates its tables wherever search_path
      # points. Without this it fills `public` alongside the application's own tables.
      # The schema comes from reactive's migration 0005.
      { name = "PGOPTIONS", value = "-c search_path=dex" },
      # RDS terminates TLS; `require` encrypts without pinning a CA, which is what the
      # app's own pool does (src/core/db passes rejectUnauthorized: false).
      { name = "POSTGRES_SSL_MODE", value = "require" },
    ]
    secrets = [
      { name = "DEX_CLIENT_SECRET", valueFrom = local.dex_client_secret_value_from },
      { name = "POSTGRES_HOST", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:host::" },
      { name = "POSTGRES_PORT", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:port::" },
      { name = "POSTGRES_DB", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:database::" },
      { name = "POSTGRES_USER", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:username::" },
      { name = "POSTGRES_PASSWORD", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:password::" },
    ]
    # No dependsOn. Dex needs the `dex` schema to exist before its own migrations run,
    # and nothing in this task creates it: db_migrate.tf's task owns every chain and
    # update-reactive-service.yml runs it to completion before repointing the service,
    # so the schema is already there by the time this container is ever placed.
    #
    # The one window that ordering does not cover is a brand-new company, where
    # terraform creates the service before any deploy has run a migration. The restart
    # policy above is what covers it: Dex retries, and essential = false keeps the
    # failures off the rest of the task.
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.ecs_reactive.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "dex"
      }
    }
  }]
}

# The connectors this company can log in with: a JSON array of complete Dex connector
# objects, read by the sidecar as its `connectors` block and by reactive to render the
# login page. One secret per connector so adding a provider is a new secret rather than a
# rewrite of everyone else's — see sidecars/dex/README.md.
resource "aws_secretsmanager_secret" "sso_connector" {
  for_each = toset(var.company.sso_connectors)

  name = "${local.ssm_path}/sso/${each.key}"
  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "sso_connector" {
  for_each = aws_secretsmanager_secret.sso_connector

  secret_id = each.value.id

  # A placeholder, so the data source below has a version to read on the first apply.
  # Dex rejects a connector with no type, so this fails visibly rather than admitting
  # anyone; onboarding overwrites it with the real object.
  secret_string = jsonencode({ id = each.key, name = each.key, type = "" })

  # Onboarding and any later rotation write straight to the secret, so terraform must not
  # drag it back to the placeholder.
  lifecycle {
    ignore_changes = [secret_string]
  }
}

# The aggregate this replaced. Still declared, and deliberately: removing it from the config
# is a destroy, and it holds every connector a company is currently logging in with. It stays
# through this release so the cutover is reversible — nothing reads it any more — and comes
# out in a later one, once every company's per-connector secrets are populated.
resource "aws_secretsmanager_secret" "company_sso" {
  name = "${local.ssm_path}/sso"
  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "company_sso" {
  secret_id     = aws_secretsmanager_secret.company_sso.id
  secret_string = "[]"

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Read back rather than kept from the resource: the resource holds the placeholder, and
# ignore_changes means terraform never learns what onboarding wrote. This is the only way to
# assemble the array, and it is why the values land in state — see the note on
# local.dex_connectors.
data "aws_secretsmanager_secret_version" "sso_connector" {
  for_each = aws_secretsmanager_secret_version.sso_connector

  secret_id = each.value.secret_id
}
