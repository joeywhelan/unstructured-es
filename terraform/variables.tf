variable "elastic_cloud_api_key" {
  description = "Elastic Cloud API key"
  type        = string
  sensitive   = true
}

variable "jina_api_key" {
  description = "Jina.ai API key"
  type        = string
  sensitive   = true
}

variable "region" {
  description = "GCP region"
  type        = string  
  default     = "gcp-us-central1"
}