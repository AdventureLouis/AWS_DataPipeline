# Optimized Serverless Data Pipeline for CSV Processing

This optimized Terraform configuration creates a streamlined serverless data pipeline on AWS for processing CSV files and generating donut chart visualizations. Optimized following Guido van Rossum's principles of simplicity and readability.

## Architecture Overview

The pipeline consists of essential components:

1. **S3 Buckets**: Three buckets for raw, processed, and final data
2. **Lambda Function**: Data preprocessing and pipeline orchestration
3. **AWS Glue**: ETL job for advanced data transformations
4. **QuickSight**: Data source, dataset, and donut chart analysis
5. **IAM Roles**: Secure access for Lambda and Glue services

## Data Flow

1. CSV files are uploaded to the raw S3 bucket
2. S3 event triggers Lambda function for preprocessing
3. Lambda cleans data and saves to processed bucket
4. Lambda triggers AWS Glue ETL job
5. Glue performs advanced transformations and saves to final bucket
6. QuickSight ingests data and displays the medical cost donut chart

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.0 installed
- Python 3.9+ (for Lambda function)

## Deployment Instructions

1. **Initialize Terraform**:
   ```bash
   terraform init
   ```

2. **Plan the deployment**:
   ```bash
   terraform plan
   ```

3. **Apply the configuration**:
   ```bash
   terraform apply
   ```

4. **Upload your CSV file**:
   After deployment, upload your CSV file to the raw bucket under the `input/` prefix to trigger the pipeline.

## Configuration

Key variables can be customized in `main.tf`:

- `project_name`: Project name prefix (default: csv-pipeline)
- `csv_file`: Name of the CSV file to process (default: insurance.csv)
- `region`: AWS region (default: eu-west-1)

## Outputs

After deployment, Terraform will output:
- Raw and final S3 bucket names
- Lambda function name
- Direct URL to QuickSight donut chart analysis
- Complete pipeline summary with optimization details

## Services Used

📊 **Core AWS Services:**
- **Amazon S3 (3 buckets)**:
  - Raw bucket: Stores uploaded CSV files
  - Processed bucket: Stores Lambda-cleaned data
  - Final bucket: Stores Glue-transformed data
- **AWS Lambda (2 functions)**:
  - Data processor: CSV cleaning and preprocessing
  - Ingestion trigger: QuickSight dataset refresh
- **AWS Glue**:
  - ETL Job: Advanced data transformations with Spark
  - Catalog Database: Schema management
  - Crawler: Automatic schema discovery
  - Table: Data structure definition
- **Amazon QuickSight**:
  - Data Source: S3 connection via manifest
  - Dataset: SPICE import with calculated fields
  - Analysis: Donut chart visualization
- **AWS IAM (2 roles)**:
  - Lambda role: S3, Glue, and QuickSight permissions
  - Glue role: S3 access for ETL operations

🔒 **Security Features:**
- S3 buckets with versioning and AES256 encryption
- IAM roles with least privilege access
- Secure service-to-service communication

✨ **Optimizations Applied:**
- Consolidated from 8 .tf files to 1 main.tf file
- Unified Lambda functions for efficiency
- Automated pipeline triggering
- Direct QuickSight integration

## Cleanup

To destroy all resources:
```bash
terraform destroy
```

## Donut Chart Visualization

🎯 **Direct Access**: After deployment, access your donut chart at:
`https://eu-west-1.quicksight.aws.amazon.com/sn/analyses/medical-cost-donut`


The chart visualizes medical costs comparing smokers vs non-smokers with:
- Donut chart format with medium arc thickness
- Percentage labels positioned outside
- Legend positioned on the right
- Average charges aggregation by smoker status

## Support
This optimized pipeline is designed for efficient data processing and visualization with minimal AWS resource usage.


**Video Demo**

https://github.com/user-attachments/assets/4cc624d5-a146-49be-80b5-ca2c3bdaf164


**Architecture**

![Architecture](https://github.com/user-attachments/assets/875fb2da-2748-4e03-aa86-5a93c7f7fa91)



