variable "aws_region" {
  description = "AWS region to deploy the PARCS lab instance."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type. t3.small (2 vCPU / 2 GB) fits NUM_WORKERS=2-4."
  type        = string
  default     = "t3.small"
}

variable "repo_url" {
  description = "HTTPS URL of the Git repository to clone on the instance (e.g. https://github.com/user/parcs-lab-go)."
  type        = string
}

variable "github_token_ssm_path" {
  description = "SSM Parameter Store path that holds the GitHub Personal Access Token (SecureString). Store it once with: aws ssm put-parameter --name <path> --value <token> --type SecureString"
  type        = string
  default     = "/parcs-lab/github-token"
}
