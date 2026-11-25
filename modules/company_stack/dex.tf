# Dex, the identity provider, as a sidecar of the reactive task.
#
# Not a service of its own: nothing in the login path may live outside this
# task. Dex binds loopback in the shared network namespace and reactive proxies /dex to
# it, which is also the URL its issuer claims.
#
# Present exactly when there is a connector. It used to be unconditional, on the
# grounds that SSO was the only way anyone logs in and a connectorless deployment was simply
# broken — password login is what makes that a valid state instead. Dex refuses to start on
# an empty connector list, and restartPolicy below retries it forever, so leaving it mounted
# costs a permanent crash loop and a log group full of its failures.
#
# It tracks sso_connectors, the same value reactive gates
# its password endpoint on, so the two cannot disagree about which login a deployment gets.

locals {
  # The origin the BROWSER drives the OIDC hops against, and what a provider's redirect URI
  # is registered against.
  dex_base_url = coalesce(
    var.sso_base_url,
    var.orchestrator_url,
    local.company_base_url
  )

  # One variable for each connector, which ECS fills from that connector's secret when the
  # task starts. valueFrom maps one variable to one secret and cannot concatenate, so both
  # containers build the array from these, in the order of the names. Terraform holds the
  # ARNs and never the connectors, which carry the customer's OAuth client secrets.
  dex_connector_secrets = [
    for index, id in var.company.sso_connectors : {
      name      = format("DEX_CONNECTOR_%02d", index)
      valueFrom = aws_secretsmanager_secret.sso_connector[id].arn
    }
  ]

  # Not a secret: it only names reactive's client registration inside Dex. The matching
  # secret is DEX_CLIENT_SECRET, below.
  dex_client_id = "ewake-reactive"

  dex_client_secret_value_from = local.is_byoc ? "${one(aws_secretsmanager_secret.app[*].arn)}:DEX_CLIENT_SECRET::" : "${var.dex_secret_arn}:SECRET::"

  dex_containers = length(var.company.sso_connectors) > 0 ? [{
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
      { name = "DEX_CLIENT_ID", value = local.dex_client_id },
      # Dex has no schema option of its own and creates its tables wherever search_path
      # points. Without this it fills `public` alongside the application's own tables.
      # The schema comes from reactive's migration 0005.
      { name = "PGOPTIONS", value = "-c search_path=dex" },
      # RDS terminates TLS; `require` encrypts without pinning a CA, which is what the
      # the application's own connection pool does.
      { name = "POSTGRES_SSL_MODE", value = "require" },
    ]
    # The connectors are the same variables reactive receives, so the login page cannot offer
    # a connector Dex does not serve.
    secrets = concat(local.dex_connector_secrets, [
      { name = "DEX_CLIENT_SECRET", valueFrom = local.dex_client_secret_value_from },
      { name = "POSTGRES_HOST", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:host::" },
      { name = "POSTGRES_PORT", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:port::" },
      { name = "POSTGRES_DB", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:database::" },
      { name = "POSTGRES_USER", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:username::" },
      { name = "POSTGRES_PASSWORD", valueFrom = "${aws_secretsmanager_secret.company_db.arn}:password::" },
    ])
    # No dependsOn. Dex needs the `dex` schema to exist before its own migrations run,
    # and nothing in this task creates it: db_migrate.tf's task owns every chain and
    # update-reactive-service.yml runs it to completion before repointing the service,
    # so the schema is already there by the time this container is ever placed.
    #
    # The one window that ordering does not cover is a brand-new install, where
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
  }] : []
}

# The connectors this deployment can log in with. Each secret holds one complete Dex
# connector object. One secret per connector so adding a provider is a new secret rather
# than a rewrite of everyone else's.
#
# Terraform creates the secret, and secret_values.tf has the bootstrap Lambda write a
# placeholder into it when it is empty, so the task can start. Dex rejects a connector with
# no type, so the placeholder fails visibly rather than admitting anyone. An operator then
# writes the real object straight to the secret, and nothing here ever reads it.
resource "aws_secretsmanager_secret" "sso_connector" {
  for_each = toset(var.company.sso_connectors)

  name = "${local.ssm_path}/sso/${each.key}"
  tags = local.tags
}

resource "aws_secretsmanager_secret" "company_sso" {
  name = "${local.ssm_path}/sso"
  tags = local.tags
}
