provider "aws" {
  region = var.region
}

# ---------------------------
# VPC + Public/Private Subnet
# ---------------------------
resource "aws_vpc" "this" {
  cidr_block           = "10.10.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.10.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.region}a"
  tags = { Name = "${var.project_name}-public-subnet" }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.10.2.0/24"
  map_public_ip_on_launch = false
  availability_zone       = "${var.region}a"
  tags = { Name = "${var.project_name}-private-subnet" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project_name}-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------
# NAT for private subnet egress
# ---------------------------
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "${var.project_name}-nat" }
  depends_on    = [aws_internet_gateway.igw]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project_name}-private-rt" }
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat.id
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ---------------------------
# Lambda Security Group
# ---------------------------
resource "aws_security_group" "lambda_sg" {
  name        = "${var.project_name}-lambda-sg"
  description = "Lambda egress-only SG"
  vpc_id      = aws_vpc.this.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-lambda-sg" }
}

# ---------------------------
# IAM Role + Policies
# ---------------------------
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_policy" "snapshot_cleanup" {
  name        = "${var.project_name}-snapshot-cleanup-policy"
  description = "Describe & delete EBS snapshots"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "DescribeSnapshots",
        Effect = "Allow",
        Action = ["ec2:DescribeSnapshots", "ec2:DescribeTags", "ec2:DescribeSnapshotAttribute"],
        Resource = "*"
      },
      {
        Sid    = "DeleteSnapshots",
        Effect = "Allow",
        Action = ["ec2:DeleteSnapshot"],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "snapshot_cleanup_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.snapshot_cleanup.arn
}

# ---------------------------
# Lambda Zip Packaging
# ---------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/../lambda/snapshot_cleanup.py"
  output_path = "${path.module}/build/snapshot_cleanup.zip"
}

# ---------------------------
# Lambda Function (in Private Subnet)
# ---------------------------
resource "aws_lambda_function" "snapshot_cleanup" {
  function_name = "${var.project_name}-lambda"
  role          = aws_iam_role.lambda_role.arn

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  runtime      = "python3.12"
  handler      = "snapshot_cleanup.lambda_handler"
  timeout      = 300
  memory_size  = 256

  vpc_config {
    subnet_ids         = [aws_subnet.private.id]
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = {
      RETENTION_DAYS = tostring(var.retention_days)
      DRY_RUN        = tostring(var.dry_run)
      AWS_REGION     = var.region
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_iam_role_policy_attachment.lambda_vpc,
    aws_iam_role_policy_attachment.snapshot_cleanup_attach
  ]
}

# ---------------------------
# EventBridge Schedule (Optional Bonus)
# ---------------------------
resource "aws_cloudwatch_event_rule" "daily" {
  name                = "${var.project_name}-schedule"
  description         = "Daily trigger for snapshot cleanup"
  schedule_expression = var.schedule_expression
}

resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.daily.name
  target_id = "SnapshotCleanupLambda"
  arn       = aws_lambda_function.snapshot_cleanup.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.snapshot_cleanup.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.daily.arn
}
