output "instance_id" {
  value = aws_instance.app.id
}

output "bucket_name" {
  value = aws_s3_bucket.lab.bucket
}

output "nat_gateway_id" {
  value = aws_nat_gateway.lab.id
}

output "nat_public_ip" {
  value = aws_eip.nat.public_ip
}

output "private_route_table_id" {
  value = aws_route_table.private.id
}

output "s3_endpoint_id" {
  value = try(aws_vpc_endpoint.s3[0].id, null)
}

output "s3_prefix_list_id" {
  value = try(aws_vpc_endpoint.s3[0].prefix_list_id, null)
}
