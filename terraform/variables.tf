variable "region" {
  type    = string
  default = "ap-southeast-2"
}

variable "image_tag" {
  type    = string
  default = "v2"
}

variable "api_secret" {
  type      = string
  sensitive = true
}

variable "alert_email" {
  type = string
}
