output "instance_id" {
  description = "EC2 instance ID — use with AWS SSM to connect or send commands."
  value       = aws_instance.parcs_ec2.id
}

output "ssm_session_command" {
  description = "Command to open an interactive shell on the instance via SSM (no SSH key needed)."
  value       = "aws ssm start-session --target ${aws_instance.parcs_ec2.id} --region ${var.aws_region}"
}

output "run_experiments_command" {
  description = "Command to run all experiments on the instance from this directory."
  value       = "./run-experiments.sh"
}
