# ---------------------------------------------------------------------------
# Step 3: public status page
# CloudFront serves index.html and status.json from the private S3 bucket
# defined in main.tf, using Origin Access Control (OAC).
# ---------------------------------------------------------------------------

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_origin_access_control" "status" {
  name                              = "${local.name}-oac"
  description                       = "Lets CloudFront read the private status bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "status" {
  enabled             = true
  comment             = "${local.name} public status page"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"

  origin {
    origin_id                = "status-bucket"
    domain_name              = aws_s3_bucket.status.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.status.id
  }

  default_cache_behavior {
    target_origin_id       = "status-bucket"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # Respects the Cache-Control headers set on each object
    # (status.json: 30s from the Lambda, index.html: 60s below)
    cache_policy_id = data.aws_cloudfront_cache_policy.optimized.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# Only this CloudFront distribution may read objects from the bucket
data "aws_iam_policy_document" "bucket_read" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.status.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.status.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "status" {
  bucket = aws_s3_bucket.status.id
  policy = data.aws_iam_policy_document.bucket_read.json

  depends_on = [aws_s3_bucket_public_access_block.status]
}

# Deploy the page as part of tofu apply
resource "aws_s3_object" "index" {
  bucket        = aws_s3_bucket.status.id
  key           = "index.html"
  source        = "${path.module}/web/index.html"
  etag          = filemd5("${path.module}/web/index.html")
  content_type  = "text/html; charset=utf-8"
  cache_control = "max-age=60"
}

output "status_page_url" {
  value = "https://${aws_cloudfront_distribution.status.domain_name}"
}
