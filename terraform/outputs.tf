output "elastic_cloud_id" {
  value = ec_elasticsearch_project.demo_project.cloud_id
}

output "elastic_username" {
  value = ec_elasticsearch_project.demo_project.credentials.username
}

output "elastic_password" {
  value = ec_elasticsearch_project.demo_project.credentials.password
  sensitive = true
}

output "jina_api_key" {
  value = var.jina_api_key
  sensitive = true
}