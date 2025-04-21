resource "aws_s3_bucket" "file_sync" {
  bucket        = "${var.project_name}-bucket"
  force_destroy = true

  tags = {
    Name = "${var.project_name}-bucket"
  }
}