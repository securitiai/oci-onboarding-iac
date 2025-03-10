variable "tenancy_ocid" {}
variable "region" {}

provider "oci" {
  region       = var.region
  tenancy_ocid = var.tenancy_ocid
}
