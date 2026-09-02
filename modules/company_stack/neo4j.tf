# Self-hosted Neo4j 5 Community on a single EC2 + EBS. Credentials
# are written to `${local.ssm_path}/neo4j` and consumed by the reactive ECS task
# and the scheduled Lambdas as env vars. Naming and shape mirror the RDS
# secret in rds_db.tf.

locals {
  # EBS volumes are AZ-bound; the instance must live in the same AZ. The
  # ECS tasks span all private subnets and reach here across AZs within the VPC.
  neo4j_subnet_id = var.private_subnets[0]

  # Single source of truth for the connection identity — referenced by the
  # composite secret payload and by lambdas.tf when forwarding these into the
  # reactive and scheduled Lambda submodules.
  neo4j_username = "neo4j"
  neo4j_uri      = "bolt://${aws_instance.neo4j.private_ip}:7687"
}

data "aws_ami" "al2023_arm64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-minimal-*-arm64"]
  }
}

data "aws_subnet" "neo4j" {
  id = local.neo4j_subnet_id
}

resource "random_password" "company_neo4j" {
  length  = 32
  special = false
}

# Password-only secret consumed by the EC2 at boot via its instance profile.
# Kept separate from the composite `${ssm_path}/neo4j` secret below to break
# the cycle: the composite carries the URI (derived from the instance's
# private_ip and therefore depending on the instance), which would make the
# instance depend on itself if the password lived only there.
resource "aws_secretsmanager_secret" "company_neo4j_password" {
  name = "${local.ssm_path}/neo4j-password"
  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "company_neo4j_password" {
  secret_id     = aws_secretsmanager_secret.company_neo4j_password.id
  secret_string = random_password.company_neo4j.result
}

# EC2 instance profile — the Neo4j box's *only* IAM privilege is reading its
# own password secret. Scoped by ARN, not by prefix.
data "aws_iam_policy_document" "neo4j_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "neo4j" {
  name               = "${local.arn_prefix}-neo4j-ec2"
  assume_role_policy = data.aws_iam_policy_document.neo4j_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "neo4j_secret_read" {
  name = "${local.arn_prefix}-neo4j-secret-read"
  role = aws_iam_role.neo4j.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.company_neo4j_password.arn
    }]
  })
}

# Enables `aws ssm start-session` for debugging. Grants only what the agent
# needs to register + receive commands — no data-plane permissions.
resource "aws_iam_role_policy_attachment" "neo4j_ssm" {
  role       = aws_iam_role.neo4j.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "neo4j" {
  name = "${local.arn_prefix}-neo4j"
  role = aws_iam_role.neo4j.name
}

resource "aws_security_group" "neo4j" {
  name        = "${local.arn_prefix}-neo4j"
  description = "Neo4j bolt ingress from the ECS task SG only"
  vpc_id      = var.vpc_id

  lifecycle {
    # description is immutable in AWS; ignore drift so a wording change never forces
    # a replacement of the live security group.
    ignore_changes = [description]
  }

  ingress {
    from_port       = 7687
    to_port         = 7687
    protocol        = "tcp"
    security_groups = [var.ecs_task_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.arn_prefix}-neo4j"
  })
}

resource "aws_ebs_volume" "neo4j_data" {
  availability_zone = data.aws_subnet.neo4j.availability_zone
  size              = 20
  type              = "gp3"
  encrypted         = true

  # This is the graph's only durable store, so terraform must never replace it
  # on a routine plan. The instance carries ignore_changes on user_data, so
  # cloud-init never re-formats/re-mounts a fresh volume on a running box — a
  # silent volume replace wipes the graph and leaves Neo4j broken.
  #
  #  - prevent_destroy: a genuine replace fails loudly instead of wiping data;
  #    lifting it is a deliberate, snapshot-first operation.
  #  - ignore_changes: the two ForceNew attributes that drift on refresh and
  #    would otherwise force a perpetual replace — availability_zone (recomputed
  #    from the re-read subnet data source) and kms_key_id (resolved to the
  #    default aws/ebs key ARN while config leaves it null). The volume and
  #    instance are already co-located; ignoring these keeps plans clean.
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [availability_zone, kms_key_id]
  }

  # `Name` is matched by aws_dlm_lifecycle_policy.neo4j_snapshots below.
  tags = merge(local.tags, {
    Name = "${local.arn_prefix}-neo4j-data"
  })
}

# AMI and user_data are pinned via ignore_changes so terraform never
# re-provisions the node silently — bumping them is an explicit, deliberate
# change.
resource "aws_instance" "neo4j" {
  ami                    = data.aws_ami.al2023_arm64.id
  instance_type          = var.neo4j_instance_type
  subnet_id              = local.neo4j_subnet_id
  vpc_security_group_ids = [aws_security_group.neo4j.id]
  iam_instance_profile   = aws_iam_instance_profile.neo4j.name

  # Bounded so a stuck RunInstances (rare regional-capacity issue) fails fast
  # instead of blocking the whole apply. On failure, retry: subsequent attempts
  # usually pick up freed capacity or the customer can override neo4j_instance_type.
  timeouts {
    create = "10m"
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true
  }

  # Password is NOT baked into user_data — it's fetched at boot from
  # `aws_secretsmanager_secret.company_neo4j_password` via the instance
  # profile. That keeps `describe-instance-attribute` and IMDS user_data
  # reads from leaking the credential.
  # data_volume_serial: EBS NVMe devices expose the volume ID (dash stripped)
  # as their serial, so /dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_<serial>
  # is a stable handle for the data volume regardless of nvme enumeration order.
  user_data = templatefile("${path.module}/neo4j_user_data.sh", {
    password_secret_id = aws_secretsmanager_secret.company_neo4j_password.name
    aws_region         = data.aws_region.current.name
    data_volume_serial = replace(aws_ebs_volume.neo4j_data.id, "-", "")
  })

  lifecycle {
    ignore_changes = [ami, user_data]
  }

  tags = merge(local.tags, {
    Name = "${local.arn_prefix}-neo4j"
  })
}

resource "aws_volume_attachment" "neo4j_data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.neo4j_data.id
  instance_id = aws_instance.neo4j.id
}

# Daily EBS snapshots, 7-day retention, matching the RDS backup retention. The
# DLM execution role is created account-wide by dlm.tf.
#
# NB these snapshots are crash-consistent, not clean backups. Community edition
# has no online backup, so restoring one is equivalent to power-cut recovery via
# Neo4j's transaction log. Ambient scraping refills the graph within one cycle
# regardless, so we accept this — but a future restore should not assume it's a
# clean snapshot.
resource "aws_dlm_lifecycle_policy" "neo4j_snapshots" {
  description        = "Neo4j EBS daily snapshots for ${local.arn_prefix}"
  execution_role_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/service-role/AWSDataLifecycleManagerDefaultRole"
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags = {
      Name = "${local.arn_prefix}-neo4j-data"
    }

    schedule {
      name      = "daily"
      copy_tags = true

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"]
      }

      retain_rule {
        count = 7
      }
    }
  }

  tags = local.tags
}

resource "aws_secretsmanager_secret" "company_neo4j" {
  name = "${local.ssm_path}/neo4j"
  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "company_neo4j" {
  secret_id = aws_secretsmanager_secret.company_neo4j.id
  secret_string = jsonencode({
    NEO4J_URI      = local.neo4j_uri
    NEO4J_USERNAME = local.neo4j_username
    NEO4J_PASSWORD = random_password.company_neo4j.result
  })

  depends_on = [aws_volume_attachment.neo4j_data]
}
