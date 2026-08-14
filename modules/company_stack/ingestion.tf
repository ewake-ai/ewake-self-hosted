# S3 folder marker: a zero-byte object with a trailing-slash key materializes the <tenant>/<company>/ prefix.
#
# Byoc: skipped. The `ewake-ingestion` bucket is Ewake-account owned; a byoc
# tenant has no cross-account write grant (and giving one would leak that
# tenant's uploads into our bucket, which is exactly what byoc exists to prevent).
# The app-side ingestion path for byoc uses a per-customer bucket (see TODO).
resource "aws_s3_object" "ingestion_folder" {
  count        = local.is_byoc ? 0 : 1
  bucket       = "${var.project_name}-ingestion"
  key          = "${var.tenant_name}/${var.company.name}/"
  content      = ""
  content_type = "application/x-directory"
  tags         = local.tags
}
