variable "prefix" {
  type        = string
  description = "Prefixo de todos os recursos"
  default     = "azstudy"
}

variable "env" {
  type        = string
  description = "Ambiente (dev, stage...)"
  default     = "dev"
}

variable "image" {
  type        = string
  description = "Imagem inicial do Container App; o pipeline troca pela da API"
  default     = "mcr.microsoft.com/k8se/quickstart:latest"
}
