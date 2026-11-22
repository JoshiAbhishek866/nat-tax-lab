data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

locals {
  az     = data.aws_availability_zones.available.names[0]
  bucket = "nat-tax-lab-${data.aws_caller_identity.current.account_id}-${var.region}"
}

# ---------------------------------------------------------------------------
# Network: one public subnet (NAT gateway) and one private subnet (our "app")
# ---------------------------------------------------------------------------
resource "aws_vpc" "lab" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true # gateway endpoints rely on Amazon DNS; keep this on
  enable_dns_hostnames = true

  tags = { Name = "nat-tax-lab" }
}

resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = { Name = "nat-tax-lab" }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.20.0.0/24"
  availability_zone = local.az
  tags              = { Name = "nat-tax-lab-public" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.lab.id
  cidr_block        = "10.20.1.0/24"
  availability_zone = local.az
  tags              = { Name = "nat-tax-lab-private" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "nat-tax-lab" }
}

resource "aws_nat_gateway" "lab" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "nat-tax-lab" }

  depends_on = [aws_internet_gateway.lab]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }

  tags = { Name = "nat-tax-lab-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.lab.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.lab.id
  }

  tags = { Name = "nat-tax-lab-private" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# The whole point of the lab: the S3 gateway endpoint (free)
# ---------------------------------------------------------------------------
resource "aws_vpc_endpoint" "s3" {
  count = var.enable_s3_endpoint ? 1 : 0

  vpc_id            = aws_vpc.lab.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"

  # Every private route table that sends 0.0.0.0/0 to a NAT gateway goes here.
  route_table_ids = [aws_route_table.private.id]

  # No policy block = default full access. If you narrow it later, remember
  # buckets in OTHER accounts that your apps read or write.

  tags = { Name = "nat-tax-lab-s3" }
}

# ---------------------------------------------------------------------------
# S3 bucket the private instance talks to
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "lab" {
  bucket        = local.bucket
  force_destroy = true # lab only: lets terraform destroy empty the bucket
}

resource "aws_s3_bucket_public_access_block" "lab" {
  bucket                  = aws_s3_bucket.lab.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

locals {
  nat_ip_condition = {
    NotIpAddress = { "aws:SourceIp" = ["${aws_eip.nat.public_ip}/32"] }
  }

  vpce_condition = {
    StringNotEquals = { "aws:SourceVpce" = try(aws_vpc_endpoint.s3[0].id, "no-endpoint-yet") }
  }

  # Conditions inside one statement are ANDed: deny only when the request is
  # neither from the NAT IP nor through our endpoint.
  deny_condition = var.bucket_policy_mode == "sourceip_or_vpce" ? merge(local.nat_ip_condition, local.vpce_condition) : local.nat_ip_condition
}

resource "aws_s3_bucket_policy" "lab" {
  count  = var.bucket_policy_mode == "none" ? 0 : 1
  bucket = aws_s3_bucket.lab.id

  # Only GetObject is denied, so terraform (which never reads objects) can
  # still manage and destroy the bucket from your laptop.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "OnlyFromOurNetwork"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.lab.arn}/*"
      Condition = local.deny_condition
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.lab]

  lifecycle {
    precondition {
      condition     = var.bucket_policy_mode != "sourceip_or_vpce" || var.enable_s3_endpoint
      error_message = "sourceip_or_vpce needs enable_s3_endpoint = true."
    }
  }
}

# ---------------------------------------------------------------------------
# Private instance (no public IP, no SSH). We drive it with SSM Run Command.
# ---------------------------------------------------------------------------
resource "aws_iam_role" "instance" {
  name = "nat-tax-lab-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "s3" {
  name = "lab-bucket-access"
  role = aws_iam_role.instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.lab.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.lab.arn}/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "instance" {
  name = "nat-tax-lab-instance"
  role = aws_iam_role.instance.name
}

resource "aws_security_group" "instance" {
  name        = "nat-tax-lab-instance"
  description = "Egress only. No inbound at all."
  vpc_id      = aws_vpc.lab.id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.private.id
  iam_instance_profile   = aws_iam_instance_profile.instance.name
  vpc_security_group_ids = [aws_security_group.instance.id]

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    volume_size = 10
    volume_type = "gp3"
  }

  tags = { Name = "nat-tax-lab-app" }

  # SSM agent needs the NAT route to register.
  depends_on = [aws_route_table_association.private, aws_nat_gateway.lab]
}
