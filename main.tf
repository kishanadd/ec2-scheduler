variable "schedule_expression" {
  default     = "cron(0/5 * * * ? *)"
  description = "the aws cloudwatch event rule scheule expression that specifies when the scheduler runs. Default is 5 minuts past the hour. for debugging use 'rate(5 minutes)'. See https://docs.aws.amazon.com/AmazonCloudWatch/latest/events/ScheduledEvents.html"
}

variable "resource_name_prefix" {
  default     = "ec2-scheduler"
  description = "a prefix to apply to resource names created by this module."
}

variable "region" {
  default     = "eu-west-2"
  description = "aws-regions"
}

variable "account-id" {
  default     = "*********"
  description = "aws-accountid"
}

variable "tag" {
  default     = "schedule"
  description = "the tag name used on the EC2 or RDS instance to contain the schedule json string for the instance."
}
  

  // state table

resource "aws_dynamodb_table" "StateTable" {
  name           = "${var.resource_name_prefix}-StateTable"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "service"
  range_key      = "account-region"

  attribute {
    name = "service"
    type = "S"
  }

  attribute {
    name = "account-region"
    type = "S"
  }

}

// config table

resource "aws_dynamodb_table" "ConfigTable" {
  name           = "${var.resource_name_prefix}-ConfigTable"
  billing_mode   = "PAY_PER_REQUEST"
  hash_key       = "type"
  range_key      = "name"

  attribute {
    name = "type"
    type = "S"
  }

  attribute {
    name = "name"
    type = "S"
  }

}

//kms key
resource "aws_kms_key" "InstanceSchedulerEncryptionKey" {
  description             = "Key for SNS"
  is_enabled = true
  enable_key_rotation = true
   policy = <<POLICY
 {
   "Version": "2012-10-17",
   "Statement": [
        {
            "Sid": "default",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::${var.account-id}:root"
            },
            "Action": "kms:*",
            "Resource": "*"
        },
        {
            "Sid": "Allows use of key",
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::${var.account-id}:role/${var.resource_name_prefix}-SchedulerRole"
            },
            "Action": [
                "kms:GenerateDataKey*",
                "kms:Decrypt"
            ],
            "Resource": "*"
        }
    ]
 }
 POLICY
 
}

resource "aws_kms_alias" "InstanceSchedulerEncryptionKeyAlias" {
  name          = "alias/instance-scheduler-encryption-key"
  target_key_id = "${aws_kms_key.InstanceSchedulerEncryptionKey.key_id}"
}

// Log group
resource "aws_cloudwatch_log_group" "SchedulerLogGroup" {
  name = "${var.resource_name_prefix}-logs"
  retention_in_days = 30
}

resource "aws_sns_topic" "InstanceSchedulerSnsTopic" {
  name = "${var.resource_name_prefix}-InstanceSchedulerSnsTopic"
  kms_master_key_id = "${aws_kms_key.InstanceSchedulerEncryptionKey.key_id}"
}

// lambda function
data "archive_file" "aws-scheduler" {
  type        = "zip"
  source_dir  = "${path.module}/code"
  output_path = "${path.module}/aws-scheduler.zip"
}

resource "aws_lambda_function" "Main" {
  filename         = data.archive_file.aws-scheduler.output_path
  function_name    = "${var.resource_name_prefix}-InstanceSchedulerMain"
  role             = aws_iam_role.SchedulerRole.arn
  handler          = "main.lambda_handler"
  runtime          = "python3.7"
  timeout          = 300
  
  
  environment {
    variables = {     
      
     
      

      CONFIG_TABLE = aws_dynamodb_table.ConfigTable.name
      TAG_NAME   = var.tag
      STATE_TABLE = aws_dynamodb_table.StateTable.name
      LOG_GROUP  = aws_cloudwatch_log_group.SchedulerLogGroup.name
      ACCOUNT    =  var.account-id
      SCHEDULER_FREQUENCY = 5
      ISSUES_TOPIC_ARN = aws_sns_topic.InstanceSchedulerSnsTopic.arn
      BOTO_RETRY = "5,10,30,0.25"
      ENV_BOTO_RETRY_LOGGING =  "False"
      SEND_METRICS = "Yes"
      TRACE = "No"
      SCHEDULER_RULE = "ec2-scheduler-SchedulerRule"
      MemorySize = 128
      SOLUTION_ID	= "S00030"
      USER_AGENT = "InstanceScheduler-ec2-scheduler-v1.3.1"
      region = var.region
    }
  }
}

resource "aws_lambda_permission" "SchedulerInvokePermission" {
  statement_id  = "ec2-scheduler-SchedulerInvokePermission"
  action        = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.Main.function_name}"
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.SchedulerRule.arn
   
}


// SchedulerRule eventrule
resource "aws_cloudwatch_event_rule" "SchedulerRule" {
  name                      = "${var.resource_name_prefix}-SchedulerRule"
  description               = "Instance Scheduler - Rule to trigger instance for scheduler function version "
  schedule_expression       = var.schedule_expression 
  is_enabled                = true
  depends_on                = [aws_lambda_function.Main]
}

# Cloudwatch event target
resource "aws_cloudwatch_event_target" "SchedulerRule-MainFunction" {
  target_id                = "SchedulerRule-MainFunction"
  rule                     = aws_cloudwatch_event_rule.SchedulerRule.name
  arn                      = aws_lambda_function.Main.arn
}




resource "aws_iam_role" "SchedulerRole" {
  name = "${var.resource_name_prefix}-SchedulerRole"

  assume_role_policy = <<-EOF
  {
    "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    },
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "events.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
  }
  EOF
}


resource "aws_iam_role_policy" "SchedulerPolicy" {
  name = "${var.resource_name_prefix}-SchedulerPolicy"
  role = aws_iam_role.SchedulerRole.id

  policy = <<-EOF
  {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents",
                "logs:PutRetentionPolicy"
            ],
            "Resource": [
                "${aws_cloudwatch_log_group.SchedulerLogGroup.arn}",
                "arn:aws:logs:${var.region}:${var.account-id}:log-group:/aws/lambda/*"
            ],
            "Effect": "Allow"
        },
       {
            "Action": [
                "ec2:StartInstances",
                "ec2:StopInstances",
                "ec2:CreateTags",
                "ec2:DeleteTags"
            ],
            "Resource": [
                "arn:aws:ec2:*:${var.account-id}:instance/*"
            ],
            "Effect": "Allow"
      },
      {
            "Action": [
                "dynamodb:DeleteItem",
                "dynamodb:GetItem",
                "dynamodb:PutItem",
                "dynamodb:Query",
                "dynamodb:Scan",
                "dynamodb:BatchWriteItem"
            ],
            "Resource": [
                "${aws_dynamodb_table.StateTable.arn}",
                "${aws_dynamodb_table.ConfigTable.arn}"
            ],
            "Effect": "Allow"
      },
      {
            "Action": "sns:Publish",
            "Resource": [
                "${aws_sns_topic.InstanceSchedulerSnsTopic.arn}"
            ],
            "Effect": "Allow"
        },
        {
            "Action": [
                "lambda:InvokeFunction"
            ],
            "Resource": [
                "${aws_lambda_function.Main.arn}"
            ],
            "Effect": "Allow"
        },
        {
            "Action": [
                "logs:DescribeLogStreams",
                "ec2:DescribeInstances",
                "ec2:DescribeRegions",
                "ec2:ModifyInstanceAttribute",
                "cloudwatch:PutMetricData",
                "ssm:GetParameter",
                "ssm:GetParameters",
                "ssm:DescribeMaintenanceWindows",
                "ssm:DescribeMaintenanceWindowExecutions",
                "tag:GetResources",
                "sts:AssumeRole"
            ],
            "Resource": [
                "*"
            ],
            "Effect": "Allow"
        },
        {
            "Action": [
                "kms:GenerateDataKey*",
                "kms:Decrypt"
            ],
            "Resource": [
                "${aws_kms_key.InstanceSchedulerEncryptionKey.arn}"
            ],
            "Effect": "Allow"
        }       
    ]
  }
  EOF
}






      


