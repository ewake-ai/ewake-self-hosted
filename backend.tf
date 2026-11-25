terraform {
  # 1.11 is the floor for ephemeral variables and write-only arguments, which keep the
  # GitHub App private key out of the state. See modules/company_stack/github_app.tf.
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 5.95 has the write-only secret_string_wo argument.
      version = ">= 5.95, < 6.0"
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
