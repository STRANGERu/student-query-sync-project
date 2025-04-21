# IAM role for Lambda
resource "aws_iam_role" "lambda_exec_role" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_sftp_s3" {
  name = "${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda_exec_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # S3 access
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject"]
        Resource = [aws_s3_bucket.file_sync.arn, "${aws_s3_bucket.file_sync.arn}/*"]
      },
      # Secrets Manager
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "*"
      },
      # DynamoDB access
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem"]
        Resource = aws_dynamodb_table.processed_files.arn
      }
    ]
  })
}

# SFTP→S3 Lambda
resource "aws_lambda_function" "sftp_to_s3" {
  function_name = "${var.project_name}-sftp-to-s3"
  role          = aws_iam_role.lambda_exec_role.arn
  handler       = "sftp_to_s3.lambda_handler"
  runtime       = "python3.9"
  filename      = "lambda/sftp_to_s3.zip"
  timeout       = 120
  layers        = ["arn:aws:lambda:us-east-1:024848483238:layer:paramiko-layer:4"]
  environment {
    variables = {
      SFTP_HOST       = aws_instance.sftp_server.public_ip
      SFTP_USER       = "ec2-user"
      SFTP_SECRET_NAME = var.secret_name
      FILE_SYNC_BUCKET = aws_s3_bucket.file_sync.bucket
      PROCESSED_FILES_TABLE = aws_dynamodb_table.processed_files.name
    }
  }
  vpc_config {
    subnet_ids         = [aws_subnet.lambda.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }
  depends_on = [aws_iam_role_policy.lambda_sftp_s3]
}
resource "aws_cloudwatch_event_rule" "sftp_to_s3_schedule" {
  name                = "${var.project_name}-sftp-to-s3-schedule"
  schedule_expression = "rate(1 minute)"
}

resource "aws_cloudwatch_event_target" "sftp_to_s3_target" {
  rule      = aws_cloudwatch_event_rule.sftp_to_s3_schedule.name
  target_id = "SftpToS3"
  arn       = aws_lambda_function.sftp_to_s3.arn
}

resource "aws_lambda_permission" "allow_s3_to_call_sftp_schedule" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sftp_to_s3.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.sftp_to_s3_schedule.arn
}

# S3→SFTP Lambda
resource "aws_lambda_function" "s3_to_sftp" {
  function_name = "${var.project_name}-s3-to-sftp"
  role          = aws_iam_role.lambda_exec_role.arn
  handler       = "s3_to_sftp.lambda_handler"
  runtime       = "python3.9"
  filename      = "lambda/s3_to_sftp.zip"
  timeout       = 120
  layers        =["arn:aws:lambda:us-east-1:024848483238:layer:paramiko-layer:4"]
  environment {
    variables = {
      SFTP_HOST       = aws_instance.sftp_server.public_ip
      SFTP_USER       = "ec2-user"
      SFTP_SECRET_NAME = var.secret_name
      FILE_SYNC_BUCKET = aws_s3_bucket.file_sync.bucket
      PROCESSED_FILES_TABLE = aws_dynamodb_table.processed_files.name
    }
  }
  vpc_config {
    subnet_ids         = [aws_subnet.lambda.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }
}

# Subscribe Lambda to S3 bucket notifications
resource "aws_s3_bucket_notification" "bucket_notify" {
  bucket = aws_s3_bucket.file_sync.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.s3_to_sftp.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_s3_notification]
}

resource "aws_lambda_permission" "allow_s3_notification" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_to_sftp.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.file_sync.arn
}