# Student Query Sync Project

## Overview
This project implements a bidirectional file synchronization system between an **SFTP Server** (EC2 instance) and an **AWS S3 bucket** using AWS Lambda functions for the Intermediate DevOps assignment. It leverages Terraform for Infrastructure as Code (IaC), integrating AWS services (EC2, S3, Lambda, DynamoDB, Secrets Manager) and Python for secure SFTP-based file transfers.

- **SFTP-to-S3**: Lambda function (`sftp_to_s3`) syncs files from `/home/ec2-user/sftp` on the SFTP Server to `student-query-sync-bucket` every minute.
- **S3-to-SFTP**: Lambda function (`s3_to_sftp`) triggers on S3 `ObjectCreated` events to sync files to the SFTP Server.
- **Deduplication**: DynamoDB (`student-query-sync-processed-files`) prevents duplicate processing.
- **Security**: SFTP authentication uses a private key in AWS Secrets Manager (`sftp-private-key`).

## Architecture
- **VPC** (`student-query-sync-vpc`, ID: `vpc-02b7b36f344b878fb`):
  - **Public Subnet** (`10.0.1.0/24`): SFTP Server (`10.0.1.72`, public IP: `98.80.123.122`).
  - **Private Subnet** (`10.0.2.0/24`): Webapp Server (`10.0.2.234`).
  - **Lambda Subnets**: Enable Lambda access to S3 via NAT Gateway.
- **EC2**:
  - **SFTP Server**: Allows inbound SSH (port 22) from anywhere, hosts `/home/ec2-user/sftp`.
  - **Webapp Server**: Allows **inbound SSH (port 22) from SFTP Server** (per supervisor’s requirement) and **outbound SSH (port 22) to SFTP Server only**. No internet or AWS service access, enforced by `webapp_sg` and an empty private route table.
- **S3**: `student-query-sync-bucket` stores synced files.
- **Lambda**:
  - `student-query-sync-sftp-to-s3`: Scheduled every minute via CloudWatch Events.
  - `student-query-sync-s3-to-sftp`: Triggered by S3 notifications.
  - Both use `paramiko` (Lambda layer) for SFTP and run in the VPC with NAT Gateway.
- **DynamoDB**: Tracks processed files.
- **Secrets Manager**: Stores `sftp-private-key`.
- **IAM**: Roles for EC2 (SSM) and Lambda (S3, Secrets Manager, DynamoDB).
- **Network ACLs**: Default NACLs allow all traffic (verified).

## File Structure
```
student-query-sync-project/
├── ec2.tf                # EC2 instances (SFTP, Webapp), security groups
├── lambda/               # Lambda function code
│   ├── s3_to_sftp.py     # S3 to SFTP sync
│   ├── sftp_to_s3.py     # SFTP to S3 sync
├── lambda.tf             # Lambda functions, IAM roles, triggers
├── main.tf               # VPC, subnets, NAT Gateway, DynamoDB, route tables
├── outputs.tf            # Outputs (SFTP IP, S3 bucket, Lambda ARNs)
├── s3.tf                 # S3 bucket, notifications
├── terraform.tfvars      # Variables (e.g., project_name)
├── variables.tf          # Variable definitions
├── README.md             # Documentation
├── .gitignore            # Excludes sensitive files
```

**Excluded Files**:
- `KEY.pem`: SSH private key.
- `terraform.tfstate`, `terraform.tfstate.backup`: Terraform state.
- `lambda_layer/`: Lambda layer build directory.
- `*.zip`, `ftp_server_public_ip`, `*.json`, `*.txt`, `*.out`, `*.so`: Temporary files.

## Prerequisites
- **AWS CLI**: Configured with credentials (`aws configure`).
- **Terraform**: Version >= 1.5.0.
- **Docker**: For building Lambda layer.
- **Git**: For version control.
- **SSH Key**:
  ```bash
  ssh-keygen -t rsa -b 2048 -f KEY -N ""
  aws ec2 import-key-pair --key-name KEY --public-key-material fileb://KEY.pub --region us-east-1
  ```

## Setup Instructions
1. **Clone Repository**:
   ```bash
   git clone https://github.com/<your-username>/student-query-sync-project.git
   cd student-query-sync-project
   ```

2. **Configure SSH Key**:
   - Place `KEY.pem` in project root.
   - Set permissions:
     ```bash
     chmod 400 KEY.pem
     ```

3. **Store Private Key in Secrets Manager**:
   ```bash
   aws secretsmanager create-secret --name sftp-private-key --secret-string "{\"private_key\":\"$(awk '{printf "%s\\n", $0}' KEY.pem)\"}" --region us-east-1
   ```

4. **Build Lambda Layer**:
   - Create layer with `paramiko`, `cffi`, `cryptography`:
     ```bash
     mkdir -p lambda_layer/python
     docker run --entrypoint /bin/bash -v $(pwd):/app -w /app/lambda_layer/python public.ecr.aws/lambda/python:3.9 -c "yum install -y libffi-devel python3-devel gcc make && pip install cffi==1.17.1 paramiko==3.5.0 cryptography==42.0.8 -t ."
     cd lambda_layer
     zip -r layer.zip python/
     ```
   - Publish layer:
     ```bash
     aws lambda publish-layer-version --layer-name paramiko-layer --zip-file fileb://layer.zip --compatible-runtimes python3.9 --region us-east-1
     ```
   - Update `lambda.tf` with the layer version ARN (e.g., `arn:aws:lambda:us-east-1:123456789012:layer:paramiko-layer:1`).

5. **Package Lambda Functions**:
   ```bash
   cd lambda
   zip sftp_to_s3.zip sftp_to_s3.py
   zip s3_to_sftp.zip s3_to_sftp.py
   cd ..
   ```

6. **Deploy Infrastructure**:
   ```bash
   terraform init
   terraform apply
   ```
   - Enter `yes` after reviewing.
   - Outputs: SFTP public IP (`98.80.123.122`), S3 bucket name, Lambda ARNs.

7. **Verify Network ACLs**:
   ```bash
   aws ec2 describe-network-acls --region us-east-1 --filters "Name=vpc-id,Values=vpc-02b7b36f344b878fb" --query "NetworkAcls[].Entries" --output json
   ```
   - Expected: Default NACL allows all traffic.

8. **Test File Sync**:
   - **SFTP to S3**:
     ```bash
     echo "Test file" > test.txt
     sftp -i KEY.pem ec2-user@98.80.123.122
     cd sftp
     put test.txt
     exit
     aws s3 ls s3://student-query-sync-bucket/ --region us-east-1
     ```
     - Expected: `test.txt` appears in S3 within 1 minute.
   - **S3 to SFTP**:
     ```bash
     echo "S3 test" > test2.txt
     aws s3 cp test2.txt s3://student-query-sync-bucket/test2.txt --region us-east-1
     sftp -i KEY.pem ec2-user@98.80.123.122
     cd sftp
     ls
     exit
     ```
     - Expected: `test2.txt` appears in `/home/ec2-user/sftp`.

9. **Test Webapp Server Isolation**:
   - Access SFTP Server:
     ```bash
     scp -i KEY.pem KEY.pem ec2-user@98.80.123.122:/home/ec2-user/KEY.pem
     ssh -i KEY.pem ec2-user@98.80.123.122
     chmod 400 KEY.pem
     scp -i KEY.pem KEY.pem ec2-user@10.0.2.234:/home/ec2-user/KEY.pem
     ssh -i KEY.pem ec2-user@10.0.2.234
     chmod 400 KEY.pem
     ```
   - On Webapp Server:
     ```bash
     ssh -i KEY.pem ec2-user@10.0.1.72
     curl -I http://10.0.1.72:80
     ping -c 3 google.com
     curl -I https://google.com
     aws s3 ls s3://student-query-sync-bucket --region us-east-1
     ```
   - Expected Results:
     - `ssh`: Connects to SFTP Server.
     - `curl -I http://10.0.1.72:80`: Times out (interrupt with Ctrl+C after ~30-60 seconds).
     - `ping`: Fails (`100% packet loss`).
     - `curl -I https://google.com`: Times out (interrupt with Ctrl+C).
     - `aws s3 ls`: Fails (e.g., `Unable to locate credentials` or timeout).

## Troubleshooting
- **SSH Issues**:
  - **Permission Denied**:
    - Ensure `KEY.pem` permissions:
      ```bash
      chmod 400 KEY.pem
      ```
    - If using WSL, move `KEY.pem` to a Linux-native directory (e.g., `/home/user`) to avoid Windows file system issues.
    - Verify `KEY.pem` matches the EC2 key pair:
      ```bash
      aws ec2 describe-key-pairs --key-names KEY --region us-east-1
      ```
  - **Connection Refused (exit code 255)**:
    - Check SFTP Server `user_data` in `ec2.tf`:
      ```bash
      #!/bin/bash
      yum update -y
      yum install -y openssh-server
      systemctl enable sshd
      systemctl start sshd
      mkdir -p /home/ec2-user/sftp
      chown ec2-user:ec2-user /home/ec2-user/sftp
      ssh-keygen -A
      ```
    - Verify `sftp_sg`:
      ```hcl
      ingress {
        from_port   = 22
        to_port     = 22
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
      }
      ```
- **Lambda Failures**:
  - **No Logs**: Check CloudWatch Events (`sftp_to_s3_schedule`) and S3 notifications (`bucket_notify`).
  - **SFTP Connection**: Verify `sftp-private-key` in Secrets Manager matches `KEY.pem`.
  - **Timeout**: Increase `timeout` in `lambda.tf` (e.g., 300 seconds).
  - **_cffi_backend Error**: Ensure layer includes `cffi==1.17.1`, `paramiko==3.5.0`, `cryptography==42.0.8`.
- **Webapp Server Isolation**:
  - Verify `webapp_sg`:
    ```hcl
    ingress {
      from_port       = 22
      to_port         = 22
      protocol        = "tcp"
      security_groups = [aws_security_group.sftp_sg.id]
    }
    egress {
      from_port       = 22
      to_port         = 22
      protocol        = "tcp"
      security_groups = [aws_security_group.sftp_sg.id]
    }
    ```
  - Ensure `aws_route_table.private` is empty:
    ```hcl
    resource "aws_route_table" "private" {
      vpc_id = aws_vpc.main.id
    }
    ```
- **Network ACLs**: If connectivity fails, verify NACLs allow all traffic:
  ```bash
  aws ec2 describe-network-acls --region us-east-1 --filters "Name=vpc-id,Values=vpc-02b7b36f344b878fb"
  ```
- **WSL Issues**: Ensure `KEY.pem` is in a Linux-native directory and has `chmod 400`. If WSL terminal isn’t available in VS Code, install the WSL extension and add:
  ```json
  "terminal.integrated.profiles.windows": {
    "WSL": {
      "path": "C:\\Windows\\System32\\wsl.exe"
    }
  }
  ```

## Cleanup
```bash
terraform destroy
aws secretsmanager delete-secret --secret-id sftp-private-key --region us-east-1
aws ec2 delete-key-pair --key-name KEY --region us-east-1
```

## Notes
- **Webapp Server**: Allows inbound SSH from SFTP Server and outbound SSH to SFTP Server only. No internet or AWS service access.
- **Timeouts**: `curl` tests may take 30-60 seconds to timeout; interrupt with Ctrl+C.
- **Lambda Layer**: Uses `cryptography==42.0.8` to avoid `CryptographyDeprecationWarning`.
- **Terraform State**: Use an S3 backend for production.
- **WSL**: Avoid storing `KEY.pem` in Windows directories (e.g., `/mnt/c`) to prevent permission errors.