variable "region" { default = "us-east-1" }
variable "project_name" { default = "student-query-sync" }
variable "vpc_cidr" { default = "10.0.0.0/16" }
variable "public_subnet_cidr" { default = "10.0.1.0/24" }
variable "private_subnet_cidr" { default = "10.0.2.0/24" }
variable "lambda_subnet_cidr" { default = "10.0.3.0/24" }
variable "instance_type" { default = "t2.micro" }
variable "key_name" { description = "SSH key pair name" }
variable "ami_id" {
  description = "AMI ID for Amazon Linux 2"
  default     = "ami-0e449927258d45bc4"
}
variable "az" {
  description = "Availability Zone"
  default     = "us-east-1a"
}
variable "secret_name" {
  description = "Secrets Manager secret name for SFTP private key"
  default     = "sftp-private-key"
}