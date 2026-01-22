# --- 1. PROVIDER ---
provider "aws" {
  region = "us-east-1"
}

# --- 2. CODE PACKAGING ---
# Automatically zips the 'lambda/' folder so Lambda can read it
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda_function.zip"
}

# --- 3. IAM PERMISSIONS ---
# Permission for the Lambda service to exist
resource "aws_iam_role" "lambda_role" {
  name = "serverless_scaler_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Policy to allow the Lambda to write logs to CloudWatch
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --- 4. THE LAMBDA FUNCTION ---
resource "aws_lambda_function" "scaler_func" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "ServerlessAutoScaler"
  role             = aws_iam_role.lambda_role.arn
  handler          = "app.lambda_handler" # File is app.py, function is lambda_handler
  runtime          = "python3.11"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
}

# --- 5. TRIGGER 1: EVENTBRIDGE (Scheduled Task) ---
# Create a rule that fires every 5 minutes
resource "aws_cloudwatch_event_rule" "every_five_minutes" {
  name                = "every-five-minutes"
  description         = "Fires every five minutes"
  schedule_expression = "rate(5 minutes)"
}

# Point the rule to our Lambda function
resource "aws_cloudwatch_event_target" "check_lambda_every_five_minutes" {
  rule      = aws_cloudwatch_event_rule.every_five_minutes.name
  target_id = "scaler_func"
  arn       = aws_lambda_function.scaler_func.arn
}

# Give EventBridge permission to "invoke" the Lambda
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scaler_func.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.every_five_minutes.arn
}

# --- 6. TRIGGER 2: API GATEWAY (HTTP Web Access) ---
resource "aws_apigatewayv2_api" "lambda_api" {
  name          = "serverless-http-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "lambda_stage" {
  api_id      = aws_apigatewayv2_api.lambda_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "lambda_int" {
  api_id           = aws_apigatewayv2_api.lambda_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.scaler_func.invoke_arn
}

resource "aws_apigatewayv2_route" "default_route" {
  api_id    = aws_apigatewayv2_api.lambda_api.id
  route_key = "GET /status"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_int.id}"
}

# Give API Gateway permission to "invoke" the Lambda
resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scaler_func.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.lambda_api.execution_arn}/*/*"
}

# --- 7. OUTPUTS ---
output "status_check_url" {
  value       = "${aws_apigatewayv2_api.lambda_api.api_endpoint}/status"
  description = "Click this URL to trigger your Lambda via the web"
}
