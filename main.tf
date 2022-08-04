provider "aws" {
	region  = "us-east-1"
	alias   = "aws_cloudfront"
	profile = var.aws_profile
}
locals {
	default_certs = var.use_default_domain ? ["default"] : []
	acm_certs     = var.use_default_domain ? [] : ["acm"]
	domain_name   = var.use_default_domain ? [] : [var.domain_name]
	create_cert   = !var.use_default_domain && var.create_acm_cert
	bucket_name   = replace(coalesce(var.bucket_name, var.domain_name), ".", "-")
}

data "aws_acm_certificate" "acm_cert" {
	count    = (!var.use_default_domain && !var.create_acm_cert) ? 1 : 0
	domain   = coalesce(var.acm_certificate_domain, "*.${var.hosted_zone}")
	provider = aws.aws_cloudfront
	//CloudFront uses certificates from US-EAST-1 region only
	statuses = [
		"ISSUED",
	]
}

resource "aws_acm_certificate" "acm_cert" {
	count    = local.create_cert ? 1 : 0
	domain_name       = coalesce(var.acm_certificate_domain, "*.${var.hosted_zone}")
	validation_method = "DNS"
	provider = aws.aws_cloudfront

	lifecycle {
		create_before_destroy = true
	}
}

locals {
	domain_validation_options = local.create_cert ? aws_acm_certificate.acm_cert[0].domain_validation_options : []
}

resource "aws_route53_record" "acm_cert" {
	for_each = {
		for dvo in local.domain_validation_options : dvo.domain_name => {
			name   = dvo.resource_record_name
			record = dvo.resource_record_value
			type   = dvo.resource_record_type
		}
	}

	allow_overwrite = true
	name            = each.value.name
	records         = [each.value.record]
	ttl             = 60
	type            = each.value.type
	zone_id         = data.aws_route53_zone.domain_name[0].zone_id
}

resource "aws_acm_certificate_validation" "acm_cert" {
	count = local.create_cert ? 1 : 0
	certificate_arn         = aws_acm_certificate.acm_cert[0].arn
	validation_record_fqdns = [for record in aws_route53_record.acm_cert : record.fqdn]
	provider                = aws.aws_cloudfront
}

locals {
	acm_certificate_arn = var.create_acm_cert ? aws_acm_certificate_validation.acm_cert.*.certificate_arn : data.aws_acm_certificate.acm_cert.*.arn
}

data "aws_iam_policy_document" "s3_bucket_policy" {
	statement {
		sid = "1"

		actions = [
			"s3:GetObject",
		]

		resources = [
			"arn:aws:s3:::${local.bucket_name}/*",
		]

		principals {
			type = "AWS"

			identifiers = [
				aws_cloudfront_origin_access_identity.origin_access_identity.iam_arn,
			]
		}
	}
}

resource "aws_s3_bucket" "s3_bucket" {
	bucket = local.bucket_name
	policy = data.aws_iam_policy_document.s3_bucket_policy.json
	tags   = var.tags
	force_destroy = true
}

resource "aws_s3_bucket_acl" "s3_bucket" {
	bucket = aws_s3_bucket.s3_bucket.id
	acl    = var.s3_canned_acl
}

resource "aws_s3_bucket_versioning" "s3_bucket" {
	bucket = aws_s3_bucket.s3_bucket.id
	versioning_configuration {
		status = "Enabled"
	}
}

resource "aws_s3_bucket_object" "object" {
	count        = var.upload_sample_file ? 1 : 0
	bucket       = aws_s3_bucket.s3_bucket.bucket
	key          = "index.html"
	source       = "${path.module}/index.html"
	content_type = "text/html"
	etag         = filemd5("${path.module}/index.html")
}

data "aws_route53_zone" "domain_name" {
	count        = var.use_default_domain ? 0 : 1
	name         = var.hosted_zone
	private_zone = false
}

resource "aws_route53_record" "route53_record" {
	count = var.use_default_domain ? 0 : 1
	depends_on = [
		aws_cloudfront_distribution.s3_distribution
	]

	zone_id = data.aws_route53_zone.domain_name[0].zone_id
	name    = var.domain_name
	type    = "A"

	alias {
		name    = aws_cloudfront_distribution.s3_distribution.domain_name
		zone_id = "Z2FDTNDATAQYW2"

		//HardCoded value for CloudFront
		evaluate_target_health = false
	}
}

resource "aws_cloudfront_distribution" "s3_distribution" {
	depends_on = [
		aws_s3_bucket.s3_bucket
	]

	origin {
		domain_name = aws_s3_bucket.s3_bucket.bucket_regional_domain_name
		origin_id   = "s3-cloudfront"

		s3_origin_config {
			origin_access_identity = aws_cloudfront_origin_access_identity.origin_access_identity.cloudfront_access_identity_path
		}
	}

	enabled             = true
	is_ipv6_enabled     = true
	default_root_object = "index.html"

	aliases = local.domain_name

	default_cache_behavior {
		allowed_methods = [
			"GET",
			"HEAD",
		]

		cached_methods = [
			"GET",
			"HEAD",
		]

		target_origin_id = "s3-cloudfront"

		forwarded_values {
			query_string = false

			cookies {
				forward = "none"
			}
		}

		viewer_protocol_policy = "redirect-to-https"
	
		# https://stackoverflow.com/questions/67845341/cloudfront-s3-etag-possible-for-cloudfront-to-send-updated-s3-object-before-t
		min_ttl                = var.cloudfront_min_ttl
		default_ttl            = var.cloudfront_default_ttl
		max_ttl                = var.cloudfront_max_ttl
	}

	price_class = var.price_class

	restrictions {
		geo_restriction {
			restriction_type = "none"
		}
	}
	dynamic "viewer_certificate" {
		for_each = local.default_certs
		content {
			cloudfront_default_certificate = true
		}
	}

	dynamic "viewer_certificate" {
		for_each = local.acm_certs
		content {
			acm_certificate_arn      = local.acm_certificate_arn[0]
			ssl_support_method       = "sni-only"
			minimum_protocol_version = "TLSv1"
		}
	}

	custom_error_response {
		error_code            = 403
		response_code         = 200
		error_caching_min_ttl = 0
		response_page_path    = "/index.html"
	}

	wait_for_deployment = false
	tags                = var.tags
}

resource "aws_cloudfront_origin_access_identity" "origin_access_identity" {
	comment = "access-identity-${local.bucket_name}.s3.amazonaws.com"
}

locals {
	# Maps file extensions to mime types
	# Need to add more if needed
	mime_type_mappings = {
		html = "text/html",
		js   = "text/javascript",
		css  = "text/css"
	}
}

resource "aws_s3_bucket_object" "frontend_object" {
	for_each = toset(var.s3_bucket_files)
	key      = each.value
	source   = "${var.s3_bucket_basedir}/${each.value}"
	bucket   = aws_s3_bucket.s3_bucket.id

	etag         = filemd5("${var.s3_bucket_basedir}/${each.value}")
	content_type = lookup(local.mime_type_mappings, concat(regexall("\\.([^\\.]*)$", basename(each.value)), [[""]])[0][0], "application/octet-stream")
}
