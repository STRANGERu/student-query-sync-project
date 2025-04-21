# SFTP Security Group (public subnet)
resource "aws_security_group" "sftp_sg" {
  name        = "${var.project_name}-sftp-sg"
  description = "Allow SSH from anywhere"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Web App Security Group: only outbound SSH to SFTP
resource "aws_security_group" "webapp_sg" {
  name        = "${var.project_name}-webapp-sg"
  description = "Deny all ingress; egress only to SFTP on 22"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.sftp_sg.id]
    description     = "Temporary SSH from SFTP Server for testing"
  }

  egress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.sftp_sg.id]
  }
}

# Lambda Security Group
resource "aws_security_group" "lambda_sg" {
  name        = "${var.project_name}-lambda-sg"
  description = "Security group for Lambda functions"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# IAM Role for SSM
resource "aws_iam_role" "ssm_role" {
  name               = "${var.project_name}-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "${var.project_name}-ssm-profile"
  role = aws_iam_role.ssm_role.name
}

# SFTP Server (public subnet)
resource "aws_instance" "sftp_server" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.sftp_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm_profile.name

  tags = {
    Name = "SFTP Server"
  }

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y firewalld
    systemctl enable firewalld && systemctl start firewalld

    SFTP_CONF="/etc/ssh/sshd_config"
    if ! grep -qE '^Subsystem\s+sftp\s+' "$SFTP_CONF"; then
      echo "Subsystem sftp /usr/libexec/openssh/sftp-server" >> "$SFTP_CONF"
    fi

    mkdir -p /home/ec2-user/sftp
    chown ec2-user:ec2-user /home/ec2-user/sftp

    systemctl restart sshd

    firewall-cmd --permanent --add-port=22/tcp
    firewall-cmd --reload
  EOF
}

# Web App Server (private subnet)
resource "aws_instance" "webapp_server" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private.id
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.webapp_sg.id]

  tags = {
    Name = "Web App Server"
  }

  user_data = <<-EOF
    #!/bin/bash
    echo "Web app setup complete"
  EOF
}
