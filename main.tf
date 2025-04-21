provider "aws" {
  region = var.region
}

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
  tags = { Name = "${var.project_name}-vpc" }
}

# Public subnet (for SFTP)
resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.public_subnet_cidr
  availability_zone = var.az
  map_public_ip_on_launch = true
  tags = { Name = "${var.project_name}-public-subnet" }
}

# Private subnet (for Web App)
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = var.az
  tags = { Name = "${var.project_name}-private-subnet" }
}

# Lambda subnet
resource "aws_subnet" "lambda" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.lambda_subnet_cidr
  availability_zone = var.az
  tags = { Name = "${var.project_name}-lambda-subnet" }
}

# Internet gateway for public subnet
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# NAT Gateway for Lambda subnet
resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags = { Name = "${var.project_name}-nat-gateway" }
}

# Route table for Lambda subnet (uses NAT Gateway)
resource "aws_route_table" "lambda" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
}

resource "aws_route_table_association" "lambda_assoc" {
  subnet_id      = aws_subnet.lambda.id
  route_table_id = aws_route_table.lambda.id
}

# Private route table (no Internet for Web App)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# DynamoDB table to track processed files
resource "aws_dynamodb_table" "processed_files" {
  name           = "${var.project_name}-processed-files"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "filename"

  attribute {
    name = "filename"
    type = "S"
  }

  tags = { Name = "${var.project_name}-processed-files" }
}

# Optional: VPC Endpoints for S3 and Secrets Manager (uncomment to use instead of NAT Gateway)
# resource "aws_vpc_endpoint" "s3" {
#   vpc_id       = aws_vpc.main.id
#   service_name = "com.amazonaws.${var.region}.s3"
#   vpc_endpoint_type = "Gateway"
#   route_table_ids = [aws_route_table.lambda.id]
# }
#
# resource "aws_vpc_endpoint" "secretsmanager" {
#   vpc_id       = aws_vpc.main.id
#   service_name = "com.amazonaws.${var.region}.secretsmanager"
#   vpc_endpoint_type = "Interface"
#   subnet_ids   = [aws_subnet.lambda.id]
#   security_group_ids = [aws_security_group.lambda_sg.id]
# }