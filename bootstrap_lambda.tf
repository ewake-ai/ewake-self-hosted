# The image is pulled cross-account from Ewake's ECR.

resource "aws_iam_role" "bootstrap_lambda" {
  name = "${var.tenant_name}-rds-bootstrap"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "bootstrap_lambda" {
  name = "${var.tenant_name}-rds-bootstrap"
  role = aws_iam_role.bootstrap_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Logs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = [
          "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${var.tenant_name}-rds-bootstrap*"
        ]
      },
      {
        Sid    = "ReadTenantSecrets"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = [
          local.rds_master_secret_arn,
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:ewake/${var.tenant_name}/*"
        ]
      },
      {
        Sid    = "VPCNetworking"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_security_group" "bootstrap_lambda" {
  name        = "${var.tenant_name}-rds-bootstrap-lambda"
  description = "Tenant RDS bootstrap Lambda. Egress to the VPC CIDR on 5432 (RDS) only."
  vpc_id      = local.vpc_id

  egress {
    description = "RDS Postgres"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = local.vpc_cidr_blocks
  }

  # This function reads the RDS master secret before it connects to anything, so
  # Secrets Manager has to be reachable or it blocks until the 60-second timeout —
  # no error, no partial progress, just "Task timed out". Which destination that is
  # depends on how the deployment reaches AWS APIs at all: interface endpoints
  # answer on addresses inside the VPC, and without them the call leaves through the
  # NAT gateway or proxy and the VPC range is the one range that cannot carry it.
  #
  # The description below reads oddly now that the destination is conditional, and it
  # stays as it is on purpose: a rule's description is applied state, so rewording it
  # updates every live security group and drags the module's IAM roles and the task
  # definition along behind it. Comments are free; this string is not.
  egress {
    description = "AWS interface endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = local.vpc_interface_endpoints ? local.vpc_cidr_blocks : ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.tenant_name}-rds-bootstrap-lambda"
  }
}

resource "aws_cloudwatch_log_group" "bootstrap_lambda" {
  name              = "/aws/lambda/${var.tenant_name}-rds-bootstrap"
  retention_in_days = 14
}

resource "aws_lambda_function" "bootstrap" {
  function_name = "${var.tenant_name}-rds-bootstrap"
  role          = aws_iam_role.bootstrap_lambda.arn
  package_type  = "Image"
  # Pinned to app_image_tag like every other runtime. It matters most here: from
  # ewake-v0.168.0 this function seeds the company row and the admin user, so a copy
  # left at an older digest fails the apply that first calls it.
  image_uri   = "${local.ewake_ecr_registry}/ewake-lambda-rds-bootstrap:${local.app_image_tag}"
  timeout     = 60
  memory_size = 256

  vpc_config {
    subnet_ids         = local.private_subnets
    security_group_ids = [aws_security_group.bootstrap_lambda.id]
  }

  depends_on = [
    aws_iam_role_policy.bootstrap_lambda,
    aws_cloudwatch_log_group.bootstrap_lambda
  ]
}
