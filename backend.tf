terraform {
  # 1.10 is the floor for the S3 backend's `use_lockfile` below. On 1.6–1.9 the
  # argument is rejected outright and `terraform init` fails.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  # Backend config is intentionally partial — the customer supplies the bucket
  # name and (optionally) key at init time via a backend config file or CLI:
  #
  #   terraform init \
  #     -backend-config=bucket=<customer>-ewake-terraform-state \
  #     -backend-config=key=ewake/terraform.tfstate \
  #     -backend-config=region=<aws_region>
  #
  # See README.md for the full bootstrap. `use_lockfile` locks through a .tflock
  # object in the state bucket, so there is no DynamoDB table to create — the
  # bucket (versioned) and read/write/delete on it are the whole prerequisite.
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}
