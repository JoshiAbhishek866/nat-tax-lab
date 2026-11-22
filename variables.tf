variable "region" {
  description = "Region for the lab. The S3 bucket and the VPC must be in the same Region for a gateway endpoint to help."
  type        = string
  default     = "us-east-1"
}

variable "enable_s3_endpoint" {
  description = "Step 2 of the lab: flip to true to add the S3 gateway endpoint."
  type        = bool
  default     = false
}

variable "bucket_policy_mode" {
  description = <<-EOT
    Step 3 of the lab (the trap):
      none             = no bucket policy
      sourceip_only    = deny GetObject unless the request comes from the NAT public IP (breaks once the endpoint exists)
      sourceip_or_vpce = deny GetObject unless it comes from the NAT IP OR through our S3 gateway endpoint (the fix)
  EOT
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "sourceip_only", "sourceip_or_vpce"], var.bucket_policy_mode)
    error_message = "bucket_policy_mode must be none, sourceip_only or sourceip_or_vpce."
  }
}

variable "instance_type" {
  description = "Small Graviton instance that generates S3 traffic from the private subnet."
  type        = string
  default     = "t4g.micro"
}
