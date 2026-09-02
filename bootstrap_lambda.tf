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
          aws_secretsmanager_secret.rds_master.arn,
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
  vpc_id      = aws_vpc.this.id

  egress {
    description = "RDS Postgres"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.this.cidr_block]
  }

  egress {
    description = "AWS interface endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.this.cidr_block]
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
  # CI only publishes this Lambda under :latest, not per release channel.
  image_uri   = "${local.ewake_ecr_registry}/ewake-lambda-rds-bootstrap:latest"
  timeout     = 60
  memory_size = 256

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.bootstrap_lambda.id]
  }

  depends_on = [
    aws_iam_role_policy.bootstrap_lambda,
    aws_cloudwatch_log_group.bootstrap_lambda
  ]

  # CI (Ewake side) re-pushes and the function is updated out of band on that
  # cadence; terraform only pins the repo, so ignore tag/digest drift.
  lifecycle {
    ignore_changes = [image_uri]
  }
}
