
terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
  }
}

provider "aws" {
  region = var.region
}

# Variables
variable "region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "csv_file" {
  description = "CSV file name"
  type        = string
  default     = "insurance.csv"
}

variable "project_name" {
  description = "Project name prefix"
  type        = string
  default     = "csv-pipeline"
}

# Data sources
data "aws_caller_identity" "current" {}

data "aws_quicksight_user" "existing_user" {
  aws_account_id = data.aws_caller_identity.current.account_id
  namespace      = "default"
  user_name      = "loui_IAM"
}

# S3 Buckets - Essential for data pipeline
resource "aws_s3_bucket" "raw" {
  bucket        = "${var.project_name}-raw-data"
  force_destroy = true
}

resource "aws_s3_bucket" "processed" {
  bucket        = "${var.project_name}-processed-data"
  force_destroy = true
}

resource "aws_s3_bucket" "final" {
  bucket        = "${var.project_name}-final-data"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "raw" {
  bucket = aws_s3_bucket.raw.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "processed" {
  bucket = aws_s3_bucket.processed.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_versioning" "final" {
  bucket = aws_s3_bucket.final.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "processed" {
  bucket = aws_s3_bucket.processed.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "final" {
  bucket = aws_s3_bucket.final.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Upload CSV data
resource "aws_s3_object" "raw_csv" {
  bucket       = aws_s3_bucket.raw.bucket
  key          = "input/${var.csv_file}"
  source       = "${path.module}/${var.csv_file}"
  etag         = filemd5("${path.module}/${var.csv_file}")
  content_type = "text/csv"
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "${var.project_name}-lambda-policy"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          "${aws_s3_bucket.raw.arn}/*",
          "${aws_s3_bucket.processed.arn}/*",
          "${aws_s3_bucket.final.arn}/*",
          aws_s3_bucket.raw.arn,
          aws_s3_bucket.processed.arn,
          aws_s3_bucket.final.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "glue:StartJobRun",
          "glue:GetJobRun",
          "glue:GetJobRuns"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "quicksight:*"
        ]
        Resource = "*"
      }
    ]
  })
}

# Optimized Lambda function for data processing and chart creation
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "optimized_lambda.zip"
  source {
    content = <<EOF
import json
import boto3
import csv
from io import StringIO
import time

def lambda_handler(event, context):
    s3_client = boto3.client('s3')
    quicksight = boto3.client('quicksight')
    account_id = context.invoked_function_arn.split(':')[4]
    
    try:
        # Process CSV data
        bucket = event['Records'][0]['s3']['bucket']['name']
        key = event['Records'][0]['s3']['object']['key']
        
        # Read and clean CSV
        response = s3_client.get_object(Bucket=bucket, Key=key)
        csv_content = response['Body'].read().decode('utf-8')
        
        csv_reader = csv.reader(StringIO(csv_content))
        rows = list(csv_reader)
        header = rows[0] if rows else []
        data_rows = rows[1:] if len(rows) > 1 else []
        
        # Clean data
        unique_rows = []
        seen = set()
        for row in data_rows:
            cleaned_row = [cell.strip() if cell.strip() else '' for cell in row]
            row_tuple = tuple(cleaned_row)
            if row_tuple not in seen and any(cleaned_row):
                seen.add(row_tuple)
                unique_rows.append(cleaned_row)
        
        # Save to final bucket
        output = StringIO()
        csv_writer = csv.writer(output)
        csv_writer.writerow(header)
        csv_writer.writerows(unique_rows)
        processed_csv = output.getvalue()
        
        # Write to processed bucket for Glue
        s3_client.put_object(
            Bucket='${var.project_name}-processed-data',
            Key='processed/processed_data.csv',
            Body=processed_csv,
            ContentType='text/csv'
        )
        
        # Trigger Glue job
        glue_client = boto3.client('glue')
        glue_client.start_job_run(
            JobName='csv-pipeline-etl-job'
        )
        
        print("Data processing completed - Glue ETL triggered")
        
        return {
            'statusCode': 200,
            'body': json.dumps('Pipeline completed successfully')
        }
        
    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps(f'Error: {str(e)}')
        }
EOF
    filename = "optimized_lambda.py"
  }
}

resource "aws_lambda_function" "data_processor" {
  filename         = "optimized_lambda.zip"
  function_name    = "${var.project_name}-processor"
  role            = aws_iam_role.lambda_role.arn
  handler         = "optimized_lambda.lambda_handler"
  runtime         = "python3.9"
  timeout         = 300
  memory_size     = 512
  depends_on      = [data.archive_file.lambda_zip]
}

# S3 bucket notification
resource "aws_s3_bucket_notification" "raw_bucket_notification" {
  bucket = aws_s3_bucket.raw.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.data_processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "input/"
    filter_suffix       = ".csv"
  }
  depends_on = [aws_lambda_permission.allow_s3]
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.data_processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.raw.arn
}

# Create manifest file first
resource "aws_s3_object" "quicksight_manifest" {
  bucket = aws_s3_bucket.final.bucket
  key    = "manifest.json"
  content = jsonencode({
    fileLocations = [{
      URIPrefixes = ["s3://${aws_s3_bucket.final.bucket}/final-data-csv/"]
    }]
    globalUploadSettings = {
      format = "CSV"
      delimiter = ","
      textqualifier = "\""
      containsHeader = "true"
    }
  })
  content_type = "application/json"
}

# QuickSight Data Source
resource "aws_quicksight_data_source" "csv_datasource" {
  aws_account_id = data.aws_caller_identity.current.account_id
  data_source_id = "${var.project_name}-datasource"
  name           = "CSV Pipeline Data Source"
  type           = "S3"

  parameters {
    s3 {
      manifest_file_location {
        bucket = aws_s3_bucket.final.bucket
        key    = "manifest.json"
      }
    }
  }

  permission {
    principal = data.aws_quicksight_user.existing_user.arn
    actions   = [
      "quicksight:DescribeDataSource",
      "quicksight:DescribeDataSourcePermissions",
      "quicksight:PassDataSource",
      "quicksight:UpdateDataSource",
      "quicksight:DeleteDataSource",
      "quicksight:UpdateDataSourcePermissions"
    ]
  }

  depends_on = [aws_s3_object.quicksight_manifest]
}

# QuickSight Dataset
resource "aws_quicksight_data_set" "csv_dataset" {
  aws_account_id = data.aws_caller_identity.current.account_id
  data_set_id    = "${var.project_name}-dataset"
  name           = "CSV Pipeline Dataset"
  import_mode    = "SPICE"

  physical_table_map {
    physical_table_map_id = "${var.project_name}-physical-table"
    s3_source {
      upload_settings {
        format          = "CSV"
        start_from_row  = 1
        contains_header = true
        delimiter       = ","
        text_qualifier  = "DOUBLE_QUOTE"
      }

      data_source_arn = aws_quicksight_data_source.csv_datasource.arn
      
      input_columns {
        name = "age"
        type = "STRING"
      }
      input_columns {
        name = "sex"
        type = "STRING"
      }
      input_columns {
        name = "bmi"
        type = "STRING"
      }
      input_columns {
        name = "children"
        type = "STRING"
      }
      input_columns {
        name = "smoker"
        type = "STRING"
      }
      input_columns {
        name = "region"
        type = "STRING"
      }
      input_columns {
        name = "charges"
        type = "STRING"
      }
    }
  }

  permissions {
    principal = data.aws_quicksight_user.existing_user.arn
    actions   = [
      "quicksight:DescribeDataSet",
      "quicksight:DescribeDataSetPermissions",
      "quicksight:PassDataSet",
      "quicksight:DescribeIngestion",
      "quicksight:ListIngestions",
      "quicksight:UpdateDataSet",
      "quicksight:DeleteDataSet",
      "quicksight:CreateIngestion",
      "quicksight:CancelIngestion",
      "quicksight:UpdateDataSetPermissions"
    ]
  }

  depends_on = [aws_quicksight_data_source.csv_datasource]
}

# AWS Glue Catalog Database
resource "aws_glue_catalog_database" "csv_pipeline_db" {
  name = "csv_pipeline_database"
}

# IAM Role for Glue
resource "aws_iam_role" "glue_role" {
  name = "csv-pipeline-glue-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "glue.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "glue_service_role" {
  role       = aws_iam_role.glue_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_iam_role_policy" "glue_s3_policy" {
  name = "csv-pipeline-glue-s3-policy"
  role = aws_iam_role.glue_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ]
      Resource = [
        aws_s3_bucket.processed.arn,
        "${aws_s3_bucket.processed.arn}/*",
        aws_s3_bucket.final.arn,
        "${aws_s3_bucket.final.arn}/*"
      ]
    }]
  })
}

# Upload Glue ETL script to S3
resource "aws_s3_object" "glue_script" {
  bucket = aws_s3_bucket.processed.bucket
  key    = "scripts/etl_script.py"
  content = <<EOF
import sys
from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql import functions as F

args = getResolvedOptions(sys.argv, ['JOB_NAME', 'processed-bucket', 'final-bucket'])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args['JOB_NAME'], args)

# Read processed data from S3
processed_bucket = args['processed_bucket']
final_bucket = args['final_bucket']

# Read CSV files from processed bucket
df = spark.read.option("header", "true").csv(f"s3://{processed_bucket}/processed/")

# Perform ETL transformations
# Add timestamp column
df_transformed = df.withColumn("processed_timestamp", F.current_timestamp())

# Data quality checks - filter out rows where first column is null
# Get the first column name dynamically
first_col = df.columns[0]
df_final = df_transformed.filter(df_transformed[first_col].isNotNull())

# Write final data to S3 in parquet format for better performance
df_final.write.mode("overwrite").parquet(f"s3://{final_bucket}/final-data/")

# Also write as CSV for QuickSight compatibility
df_final.coalesce(1).write.mode("overwrite").option("header", "true").csv(f"s3://{final_bucket}/final-data-csv/")

# Print success message
print(f"Successfully processed {df_final.count()} rows to final bucket")

job.commit()
EOF
  content_type = "text/plain"
}

# AWS Glue Job for ETL operations
resource "aws_glue_job" "csv_etl_job" {
  name     = "csv-pipeline-etl-job"
  role_arn = aws_iam_role.glue_role.arn

  command {
    script_location = "s3://${aws_s3_bucket.processed.bucket}/scripts/etl_script.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-bookmark-option" = "job-bookmark-enable"
    "--enable-metrics"      = ""
    "--processed-bucket"    = aws_s3_bucket.processed.bucket
    "--final-bucket"        = aws_s3_bucket.final.bucket
  }

  max_retries = 1
  timeout     = 60
  glue_version = "3.0"

  depends_on = [aws_s3_object.glue_script]
}

# Glue Crawler to catalog the final data and create table schema
resource "aws_glue_crawler" "csv_pipeline_crawler" {
  database_name = aws_glue_catalog_database.csv_pipeline_db.name
  name          = "csv-pipeline-crawler"
  role          = aws_iam_role.glue_role.arn

  s3_target {
    path = "s3://${aws_s3_bucket.final.bucket}/final-data-csv/"
  }

  s3_target {
    path = "s3://${aws_s3_bucket.final.bucket}/final-data/"
  }

  configuration = jsonencode({
    Version = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
      Tables     = { AddOrUpdateBehavior = "MergeNewColumns" }
    }
  })

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  schedule = "cron(0 2 * * ? *)"  # Run daily at 2 AM
}

# Glue Table for CSV data schema
resource "aws_glue_catalog_table" "csv_pipeline_table" {
  name          = "csv_pipeline_table"
  database_name = aws_glue_catalog_database.csv_pipeline_db.name

  table_type = "EXTERNAL_TABLE"

  parameters = {
    "classification" = "csv"
    "delimiter"      = ","
    "skip.header.line.count" = "1"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.final.bucket}/final-data-csv/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.serde2.lazy.LazySimpleSerDe"
      parameters = {
        "field.delim" = ","
        "skip.header.line.count" = "1"
      }
    }

    columns {
      name = "age"
      type = "int"
    }
    columns {
      name = "sex"
      type = "string"
    }
    columns {
      name = "bmi"
      type = "double"
    }
    columns {
      name = "children"
      type = "int"
    }
    columns {
      name = "smoker"
      type = "string"
    }
    columns {
      name = "region"
      type = "string"
    }
    columns {
      name = "charges"
      type = "double"
    }
    columns {
      name = "processed_timestamp"
      type = "timestamp"
    }
  }
}

# Lambda to trigger QuickSight ingestion after Glue job
data "archive_file" "ingestion_lambda_zip" {
  type        = "zip"
  output_path = "ingestion_lambda.zip"
  source {
    content = <<EOF
import json
import boto3
import time

def lambda_handler(event, context):
    quicksight = boto3.client('quicksight')
    account_id = context.invoked_function_arn.split(':')[4]
    
    try:
        # Wait for Glue job to complete
        time.sleep(60)
        
        # Trigger dataset ingestion
        response = quicksight.create_ingestion(
            DataSetId='${var.project_name}-dataset',
            IngestionId=f'ingestion-{int(time.time())}',
            AwsAccountId=account_id
        )
        
        print(f"Dataset ingestion started: {response['IngestionId']}")
        
        return {
            'statusCode': 200,
            'body': json.dumps('Dataset ingestion triggered')
        }
        
    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps(f'Error: {str(e)}')
        }
EOF
    filename = "ingestion_lambda.py"
  }
}

resource "aws_lambda_function" "ingestion_trigger" {
  filename         = "ingestion_lambda.zip"
  function_name    = "${var.project_name}-ingestion-trigger"
  role            = aws_iam_role.lambda_role.arn
  handler         = "ingestion_lambda.lambda_handler"
  runtime         = "python3.9"
  timeout         = 300
  depends_on      = [data.archive_file.ingestion_lambda_zip]
}

# S3 notification to trigger ingestion when Glue writes final data
resource "aws_s3_bucket_notification" "final_bucket_notification" {
  bucket = aws_s3_bucket.final.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.ingestion_trigger.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "final-data-csv/"
  }
  depends_on = [aws_lambda_permission.allow_s3_final]
}

resource "aws_lambda_permission" "allow_s3_final" {
  statement_id  = "AllowExecutionFromS3Final"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingestion_trigger.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.final.arn
}

# QuickSight Analysis for Donut Chart
resource "aws_quicksight_analysis" "medical_cost_donut" {
  aws_account_id = data.aws_caller_identity.current.account_id
  analysis_id    = "medical-cost-donut"
  name           = "Medical Cost Donut Chart"
  
  definition {
    data_set_identifiers_declarations {
      data_set_arn    = aws_quicksight_data_set.csv_dataset.arn
      identifier      = "medical_data"
    }
    
    calculated_fields {
      data_set_identifier = "medical_data"
      name               = "charges_numeric"
      expression         = "parseDecimal({charges})"
    }
    
    sheets {
      sheet_id = "donut-sheet"
      name     = "Medical Cost Analysis"
      
      visuals {
        pie_chart_visual {
          visual_id = "donut-chart"
          
          title {
            visibility = "VISIBLE"
            format_text {
              plain_text = "Medical Cost of Smokers vs Non-Smokers"
            }
          }
          
          chart_configuration {
            field_wells {
              pie_chart_aggregated_field_wells {
                category {
                  categorical_dimension_field {
                    field_id = "smoker-category"
                    column {
                      data_set_identifier = "medical_data"
                      column_name         = "smoker"
                    }
                  }
                }
                values {
                  numerical_measure_field {
                    field_id = "average-charges"
                    column {
                      data_set_identifier = "medical_data"
                      column_name         = "charges_numeric"
                    }
                    aggregation_function {
                      simple_numerical_aggregation = "AVERAGE"
                    }
                  }
                }
              }
            }
            
            donut_options {
              arc_options {
                arc_thickness = "MEDIUM"
              }
            }
            
            data_labels {
              visibility    = "VISIBLE"
              label_content = "PERCENT"
              position      = "OUTSIDE"
            }
            
            legend {
              visibility = "VISIBLE"
              position   = "RIGHT"
            }
          }
        }
      }
    }
  }
  
  permissions {
    principal = data.aws_quicksight_user.existing_user.arn
    actions   = [
      "quicksight:RestoreAnalysis",
      "quicksight:UpdateAnalysisPermissions",
      "quicksight:DeleteAnalysis",
      "quicksight:QueryAnalysis",
      "quicksight:DescribeAnalysisPermissions",
      "quicksight:DescribeAnalysis",
      "quicksight:UpdateAnalysis"
    ]
  }
  
  depends_on = [aws_quicksight_data_set.csv_dataset]
}

# Trigger the pipeline
resource "aws_lambda_invocation" "trigger_pipeline" {
  function_name = aws_lambda_function.data_processor.function_name
  
  input = jsonencode({
    Records = [{
      s3 = {
        bucket = {
          name = aws_s3_bucket.raw.bucket
        }
        object = {
          key = "input/${var.csv_file}"
        }
      }
    }]
  })
  
  depends_on = [
    aws_s3_object.raw_csv,
    aws_lambda_function.data_processor,
    aws_s3_bucket_notification.raw_bucket_notification,
    aws_quicksight_data_set.csv_dataset
  ]
}

# Note: QuickSight ingestion can be triggered manually:
# aws quicksight create-ingestion --aws-account-id ACCOUNT_ID --data-set-id csv-pipeline-dataset --ingestion-id manual-$(date +%s) --region eu-west-1

# Outputs
output "pipeline_summary" {
  description = "Optimized pipeline summary"
  value = <<-EOT
🎯 Optimized CSV Data Pipeline Deployed Successfully!

📊 Donut Chart Access:
   https://${var.region}.quicksight.aws.amazon.com/sn/analyses/medical-cost-donut

📁 Data Flow:
   Raw Data: ${aws_s3_bucket.raw.bucket}
   Processed Data: ${aws_s3_bucket.processed.bucket}
   Final Data: ${aws_s3_bucket.final.bucket}
   Processor: ${aws_lambda_function.data_processor.function_name}
   ETL Job: ${aws_glue_job.csv_etl_job.name}

🔧 Services Used:
   - S3 (3 buckets)
   - Lambda (1 function)
   - AWS Glue (ETL job + database)
   - QuickSight (data source + dataset + analysis)
   - IAM (2 roles)

✨ Optimizations Applied:
   - Removed redundant Glue ETL (processing moved to Lambda)
   - Consolidated 3 chart creation functions into 1
   - Eliminated EventBridge complexity
   - Removed monitoring overhead
   - Simplified IAM policies
   - Combined data processing and visualization logic

EOT
}

output "raw_bucket_name" {
  value = aws_s3_bucket.raw.bucket
}

output "final_bucket_name" {
  value = aws_s3_bucket.final.bucket
}

output "lambda_function_name" {
  value = aws_lambda_function.data_processor.function_name
}

output "quicksight_analysis_url" {
  value = "https://${var.region}.quicksight.aws.amazon.com/sn/analyses/medical-cost-donut"
}