# EC2 Snapshot Cleanup — Lambda in VPC (Terraform)
My name is Divya Goud Inteniki, As requested, I have done the exercise and explained the whole flow below.
This submission provisions AWS infrastructure (Terraform) and deploys a Python AWS Lambda that deletes **EBS (EC2) snapshots older than 1 year** (default **365 days**). The Lambda runs in a **private subnet** inside a **VPC** and is triggered on a **schedule** via **EventBridge**.

---

## 1) Chosen IaC Tool (and Why)
**Terraform**
- **How to use it here:** run `terraform init` + `terraform apply` to create networking, IAM, Lambda, and EventBridge schedule.
- **Why Terraform:** concise and easy to review; reproducible deployments; automatic Lambda packaging via `archive_file` (zips the Python file and uploads during apply).

---

## 2) How to Execute the IaC (Create VPC, Subnet, IAM Role, EventBridge Rule)
### Prerequisites (How to prepare your environment)
1. Install Terraform (>= 1.5).
2. Configure AWS credentials on your machine (any one option):
   - **AWS CLI profile**:
     ```bash
     aws configure
     ```
   - **Or environment variables**:
     ```bash
     export AWS_ACCESS_KEY_ID="..."
     export AWS_SECRET_ACCESS_KEY="..."
     export AWS_DEFAULT_REGION="us-east-1"
     ```

### Deploy (How to create infrastructure)
1. Go to the Terraform directory:
   ```bash
   cd terraform
   ```
2. Initialize providers/modules:
   ```bash
   terraform init
   ```
3. (Optional) Review the plan:
   ```bash
   terraform plan
   ```
4. Apply to create resources:
   ```bash
   terraform apply
   ```

### What gets created (so you can verify)
After `terraform apply`, Terraform creates:
- **VPC**: `10.10.0.0/16`
- **Subnets**:
  - Public subnet: `10.10.1.0/24` (contains NAT + IGW route)
  - Private subnet: `10.10.2.0/24` (**Lambda runs here**)
- **Routing**:
  - Internet Gateway attached to VPC
  - NAT Gateway in public subnet
  - Private route table default route `0.0.0.0/0 → NAT` (enables Lambda to reach AWS APIs)
- **IAM**:
  - Lambda role + policies:
    - `AWSLambdaBasicExecutionRole` (CloudWatch logs)
    - `AWSLambdaVPCAccessExecutionRole` (ENIs to attach Lambda to VPC)
    - Custom policy for snapshot actions: `ec2:DescribeSnapshots`, `ec2:DeleteSnapshot`
- **EventBridge Schedule** (CloudWatch Event Rule):
  - Default: `rate(1 day)`
  - Target: Lambda function invoke permission + rule target binding

---

## 3) How to Deploy the Lambda Function Code
### Option A (Primary) — Terraform deploys code automatically
**How it works:** Terraform zips `lambda/snapshot_cleanup.py` and uploads it when you run `terraform apply`.
- Steps:
  ```bash
  cd terraform
  terraform apply
  ```
- Code packaging details:
  - Source: `../lambda/snapshot_cleanup.py`
  - Zip output: `terraform/build/snapshot_cleanup.zip`
  - `source_code_hash` ensures code updates trigger a redeploy.

### Option B (Alternate) — Deploy code using AWS CLI (code-only update)
**How to do it:**
1. Zip the Python file:
   ```bash
   cd lambda
   zip -r snapshot_cleanup.zip snapshot_cleanup.py
   ```
2. Update Lambda function code:
   ```bash
   aws lambda update-function-code      --function-name snapshot-cleaner-lambda      --zip-file fileb://snapshot_cleanup.zip
   ```
> Note: the function name may differ if you changed `project_name`. You can confirm via `terraform output lambda_function_name`.

---

## 4) How to Configure Lambda to Run Within the VPC (Subnet IDs, Security Group IDs)
### How VPC configuration is set (Terraform)
Lambda VPC attachment is defined in `terraform/main.tf` under:
- `aws_lambda_function.snapshot_cleanup.vpc_config`:
  - `subnet_ids` → private subnet
  - `security_group_ids` → Lambda security group (egress-only)

### How to obtain subnet and security group IDs
After apply, run:
```bash
cd terraform
terraform output
```
Use these outputs:
- `private_subnet_id` → pass as `subnet_ids`
- `lambda_security_group_id` → pass as `security_group_ids`

### Why NAT is included (important “how it works” detail)
Lambda in a private subnet needs outbound access to AWS public APIs (EC2 endpoint) for `DescribeSnapshots/DeleteSnapshot`.
- **How it is enabled:** private route table has `0.0.0.0/0 → NAT Gateway` in the public subnet.

---

## 5) Assumptions Made (Region, Retention, Scope)
- **AWS Region:** default `us-east-1` (Terraform variable `region`).
  - How to change region:
    ```bash
    cd terraform
    terraform apply -var="region=us-west-2"
    ```
- **Retention:** default `365` days (Terraform variable `retention_days`).
  - How to change retention:
    ```bash
    cd terraform
    terraform apply -var="retention_days=400"
    ```
- **Scope:** deletes only snapshots owned by this account using `OwnerIds=["self"]`.
- **Safety:** supports `dry_run` (Terraform variable `dry_run`).
  - How to run in dry-run mode first:
    ```bash
    cd terraform
    terraform apply -var="dry_run=true"
    ```

---

## 6) How to Monitor Lambda Execution (Logs + Metrics)
### CloudWatch Logs (How to view)
1. Open AWS Console → **CloudWatch** → **Log groups**
2. Select: `/aws/lambda/<lambda_function_name>`
3. Open the latest log stream and search for:
   - `Eligible snapshot:`
   - `Deleting snapshot:`
   - `Delete failed`

### CloudWatch Metrics (How to check health)
1. AWS Console → **CloudWatch** → **Metrics** → **Lambda**
2. Monitor these key metrics:
   - `Invocations` (did it run?)
   - `Errors` (any failures?)
   - `Duration` (execution time)
   - `Throttles` (capacity issues)

### EventBridge Rule Monitoring (How to verify scheduler)
1. AWS Console → **EventBridge** → **Rules**
2. Open rule: `<project_name>-schedule`
3. Check “Invocations” and “Failed invocations” metrics.

---

## Quick Validation (Recommended “How to test safely”)
1. Deploy with dry-run:
   ```bash
   cd terraform
   terraform apply -var="dry_run=true"
   ```
2. Confirm logs show eligible snapshots (but no deletions performed).
3. Enable real deletion:
   ```bash
   cd terraform
   terraform apply -var="dry_run=false"
   ```
