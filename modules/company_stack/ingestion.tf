# S3 folder marker: a zero-byte object with a trailing-slash key materializes the <tenant>/<company>/ prefix.
resource "aws_s3_object" "ingestion_folder" {
  count        = local.is_byoc ? 0 : 1
  bucket       = "${var.project_name}-ingestion"
  key          = "${var.tenant_name}/${var.company.name}/"
  content      = ""
  content_type = "application/x-directory"
  tags         = local.tags
}
