# CloudFront in front of the internal ALB (docs/architecture.md, decision 7).
# HTTPS terminates at CloudFront on its default *.cloudfront.net
# certificate. The VPC origin reaches the ALB in the private subnets over
# AWS's network, so the ALB never gets a public address.

# --- VPC origin ---

resource "aws_cloudfront_vpc_origin" "alb" {
  vpc_origin_endpoint_config {
    name = "${var.name_prefix}-alb"
    arn  = var.alb_arn

    # No certificate on the ALB (no domain), so this hop is HTTP. It
    # stays inside AWS's network, unlike a public-ALB origin.
    origin_protocol_policy = "http-only"
    http_port              = var.alb_listener_port
    https_port             = 443 # required by the API, unused with http-only

    origin_ssl_protocols {
      items    = ["TLSv1.2"] # required by the API, unused with http-only
      quantity = 1
    }
  }
}

# AWS creates this security group in our VPC alongside the VPC origin
# and manages it; we only reference it. It doesn't exist until the
# origin is deployed, so the lookup waits on it.
data "aws_security_group" "cloudfront_vpc_origin" {
  vpc_id = var.vpc_id

  filter {
    name   = "group-name"
    values = ["CloudFront-VPCOrigins-Service-SG*"]
  }

  depends_on = [aws_cloudfront_vpc_origin.alb]
}

# The ALB's only ingress rule. Scoped to our VPC origin rather than
# CloudFront's managed prefix list, which would admit any distribution.
resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id            = var.alb_security_group_id
  description                  = "From the CloudFront VPC origin only"
  referenced_security_group_id = data.aws_security_group.cloudfront_vpc_origin.id
  ip_protocol                  = "tcp"
  from_port                    = var.alb_listener_port
  to_port                      = var.alb_listener_port
}

# --- Distribution ---

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

# Forwards every viewer header (x-api-key, Accept, Content-Type) and the
# query string, but replaces Host with the origin's own name.
data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_distribution" "app" {
  enabled = true
  comment = "${var.name_prefix} MCP server"

  # North America and Europe edges only; the cheapest price class.
  price_class = "PriceClass_100"

  origin {
    origin_id   = "alb"
    domain_name = var.alb_dns_name

    vpc_origin_config {
      vpc_origin_id = aws_cloudfront_vpc_origin.alb.id
    }
  }

  # An API, not a website: nothing is cached and every method passes
  # through (MCP is POST).
  default_cache_behavior {
    target_origin_id = "alb"

    # Refuse plain HTTP outright. A redirect would come back only after
    # the client had already sent its API key unencrypted.
    viewer_protocol_policy = "https-only"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id

    # Small JSON / event-stream responses; leave bodies untouched.
    compress = false
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Default *.cloudfront.net certificate. Its minimum TLS version can't
  # be raised; that needs a custom certificate, i.e. a domain (option C
  # in decision 7).
  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
