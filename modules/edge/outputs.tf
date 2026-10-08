output "cloudfront_url" {
  description = "Public HTTPS endpoint for the MCP server."
  value       = "https://${aws_cloudfront_distribution.app.domain_name}"
}

output "distribution_id" {
  value = aws_cloudfront_distribution.app.id
}
