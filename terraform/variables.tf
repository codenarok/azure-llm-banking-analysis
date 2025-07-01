variable "location" {
  description = "The Azure region where all resources will be created."
  type        = string
  default     = "UK South"
}

variable "sql_admin_login" {
  description = "The administrator login for the SQL server. This should be a user or group from your Entra ID."
  type        = string
}