output "server_public_ip" { value = aws_eip.eip.public_ip }

output "ssh_command" {
  value = "ssh -i ${var.project_name}-key.pem ubuntu@${aws_eip.eip.public_ip}"
}

output "app_urls" {
  value = {
    php_app    = "http://${aws_eip.eip.public_ip}/"
    node_app   = "http://${aws_eip.eip.public_ip}/node/"
    python_app = "http://${aws_eip.eip.public_ip}/python/"
    java_app   = "http://${aws_eip.eip.public_ip}/java/"
    go_app     = "http://${aws_eip.eip.public_ip}/go/"
    jenkins    = "http://${aws_eip.eip.public_ip}:8080"
  }
}
