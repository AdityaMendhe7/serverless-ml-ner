terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      project    = "serverless-ml-ner"
      managed_by = "terraform"
    }
  }
}

data "aws_ecr_repository" "ner" {
  name = "serverless-ml-ner"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ner_fn" {
  name               = "ner-tf-fn-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "ner_fn_logs" {
  role       = aws_iam_role.ner_fn.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role" "authorizer" {
  name               = "ner-tf-authorizer-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "authorizer_logs" {
  role       = aws_iam_role.authorizer.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "ner" {
  function_name                  = "ner-tf-fn"
  role                           = aws_iam_role.ner_fn.arn
  package_type                   = "Image"
  image_uri                      = "${data.aws_ecr_repository.ner.repository_url}:${var.image_tag}"
  architectures                  = ["arm64"]
  memory_size                    = 3008
  timeout                        = 30
  reserved_concurrent_executions = 5
  depends_on                     = [aws_iam_role_policy_attachment.ner_fn_logs]

  lifecycle {
    ignore_changes = [image_uri]
  }
}

data "archive_file" "authorizer" {
  type        = "zip"
  source_file = "${path.module}/authorizer/lambda_function.py"
  output_path = "${path.module}/authorizer.zip"
}

resource "aws_lambda_function" "authorizer" {
  function_name    = "ner-tf-authorizer"
  role             = aws_iam_role.authorizer.arn
  runtime          = "python3.12"
  handler          = "lambda_function.lambda_handler"
  architectures    = ["arm64"]
  filename         = data.archive_file.authorizer.output_path
  source_code_hash = data.archive_file.authorizer.output_base64sha256
  memory_size      = 128
  timeout          = 3
  depends_on       = [aws_iam_role_policy_attachment.authorizer_logs]

  environment {
    variables = {
      API_SECRET = var.api_secret
    }
  }
}

resource "aws_cloudwatch_log_group" "ner" {
  name              = "/aws/lambda/${aws_lambda_function.ner.function_name}"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "authorizer" {
  name              = "/aws/lambda/${aws_lambda_function.authorizer.function_name}"
  retention_in_days = 7
}

resource "aws_apigatewayv2_api" "api" {
  name          = "ner-tf-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "ner" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.ner.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_authorizer" "header" {
  api_id                            = aws_apigatewayv2_api.api.id
  name                              = "header-secret"
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = aws_lambda_function.authorizer.invoke_arn
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
  identity_sources                  = ["$request.header.x-api-key"]
  authorizer_result_ttl_in_seconds  = 300
}

resource "aws_apigatewayv2_route" "extract" {
  api_id             = aws_apigatewayv2_api.api.id
  route_key          = "POST /extract"
  target             = "integrations/${aws_apigatewayv2_integration.ner.id}"
  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.header.id
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 10
    throttling_rate_limit  = 5
  }
}

resource "aws_lambda_permission" "apigw_ner" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ner.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_authorizer" {
  statement_id  = "AllowAPIGatewayInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.header.id}"
}

resource "aws_sns_topic" "alerts" {
  name = "ner-tf-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "invocations" {
  alarm_name          = "ner-tf-high-invocations"
  namespace           = "AWS/Lambda"
  metric_name         = "Invocations"
  dimensions          = { FunctionName = aws_lambda_function.ner.function_name }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 1
  threshold           = 500
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
