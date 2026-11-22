# nat-tax-lab

A small lab that shows S3 traffic from a private subnet paying NAT gateway data processing,
then removes that cost with a free S3 gateway endpoint, and proves it with CloudWatch numbers.

Companion code for the AWS Builder Center article:
"[TITLE + LINK AFTER PUBLISHING]"

## What it builds (one AZ, keep it cheap)

- VPC `10.20.0.0/16`, one public subnet (NAT gateway), one private subnet
- One `t4g.micro` instance in the private subnet (no public IP, no SSH, driven by SSM)
- One S3 bucket in the same Region
- Optional: S3 gateway endpoint (`enable_s3_endpoint`)
- Optional: a bucket policy that shows the `aws:SourceIp` trap (`bucket_policy_mode`)

## Cost

About $0.05 per hour while it runs (NAT gateway hour + public IPv4 + t4g.micro),
plus $0.045 per GB the NAT processes. Only the baseline run goes through NAT: ~3 GiB, about $0.14. Run `terraform destroy` when you finish. Prices are us-east-1; check yours.

## Run it

Needs: Terraform >= 1.5, AWS CLI v2, jq, GNU date (Linux or WSL), credentials for a
sandbox account.

```bash
terraform init
terraform apply                                   # 1. baseline: no endpoint
./scripts/generate-traffic.sh                     # note Start/End times
./scripts/nat-bytes.sh "$(terraform output -raw nat_gateway_id)" <start> <end>

terraform apply -var enable_s3_endpoint=true      # 2. add the endpoint
./scripts/generate-traffic.sh
./scripts/nat-bytes.sh "$(terraform output -raw nat_gateway_id)" <start> <end>

terraform apply -var enable_s3_endpoint=true -var bucket_policy_mode=sourceip_only     # 3. the trap
terraform apply -var enable_s3_endpoint=true -var bucket_policy_mode=sourceip_or_vpce  # 3. the fix

terraform destroy -var enable_s3_endpoint=true -var bucket_policy_mode=sourceip_or_vpce
```

Wait 3 to 5 minutes after a run before measuring. NAT metrics land in CloudWatch with a small delay.

## Files

| File | What it does |
|---|---|
| `main.tf` | VPC, NAT, private instance, bucket, optional endpoint and bucket policy |
| `scripts/generate-traffic.sh` | 1 GiB upload + 2 downloads from the private instance via SSM |
| `scripts/nat-bytes.sh` | Sums `BytesInFromSource` + `BytesInFromDestination` for a window and prices it |
