output "sftp_server_public_ip" {
  description = "Public IP of the SFTP EC2 instance"
  value       = aws_instance.sftp_server.public_ip
}

output "webapp_server_private_ip" {
  description = "Private IP of the Web App EC2"
  value       = aws_instance.webapp_server.private_ip
}

output "s3_bucket_name" {
  description = "Name of the S3 bucket used for file sync"
  value       = aws_s3_bucket.file_sync.bucket
}

output "sftp_to_s3_lambda" {
  description = "ARN of the SFTP→S3 Lambda"
  value       = aws_lambda_function.sftp_to_s3.arn
}

output "s3_to_sftp_lambda" {
  description = "ARN of the S3→SFTP Lambda"
  value       = aws_lambda_function.s3_to_sftp.arn
}
