locals {
  version          = "0.0.2"
  compartment_ocid = var.tenancy_ocid
}

resource "random_id" "cookie_jar_id" {
  byte_length = 8
}

resource "random_id" "user_id" {
  byte_length = 8
}

resource "random_id" "config_file_id" {
  byte_length = 8
}

resource "null_resource" "notify_login" {
  triggers = {
    version = local.version
  }

  provisioner "local-exec" {
    command = <<CURL
curl -c /tmp/${random_id.cookie_jar_id.hex}.jar '${var.securiti_endpoint}/core/v1/auth/basic/session?token=${var.securiti_token}'
CURL
  }
}

resource "null_resource" "get_config" {
  triggers = {
    version = local.version
  }

  provisioner "local-exec" {
    command = <<CURL
curl -b /tmp/${random_id.cookie_jar_id.hex}.jar '${var.securiti_endpoint}/privaci/v1/admin/xpod/auth_config?token=${var.securiti_token}&connector_id=${var.connector_id}' -o /tmp/${random_id.config_file_id.hex}.txt
CURL
  }

  depends_on = [null_resource.notify_login]
}

data "local_file" "public_key" {
  filename   = "/tmp/${random_id.config_file_id.hex}.txt"
  depends_on = [null_resource.get_config]
}

resource "oci_identity_group" "securiti_user_group" {
  compartment_id = local.compartment_ocid
  description    = "Securiti User Group"
  name           = "securiti-user-grp-${random_id.user_id.hex}"
}

resource "oci_identity_user" "securiti_user" {
  compartment_id = local.compartment_ocid
  description    = "Securiti User"
  name           = "securiti-user-${random_id.user_id.hex}"
  freeform_tags  = { "Department" = "DevOps" }
  depends_on     = [oci_identity_group.securiti_user_group]
}

resource "oci_identity_user_capabilities_management" "user_capabilities_management" {
  user_id                  = oci_identity_user.securiti_user.id
  can_use_auth_tokens      = "false"
  can_use_console_password = "false"
  can_use_smtp_credentials = "false"
}

resource "oci_identity_api_key" "api_key" {
  user_id   = oci_identity_user.securiti_user.id
  key_value = jsondecode(data.local_file.public_key.content).data
}

resource "oci_identity_user_group_membership" "users_groups_membership" {
  group_id   = oci_identity_group.securiti_user_group.id
  user_id    = oci_identity_user.securiti_user.id
  depends_on = [oci_identity_group.securiti_user_group, oci_identity_user.securiti_user]
}

resource "oci_identity_policy" "securiti_user_policy" {
  depends_on     = [oci_identity_user.securiti_user, oci_identity_group.securiti_user_group, oci_identity_user_group_membership.users_groups_membership]
  compartment_id = local.compartment_ocid
  description    = "Securiti User Policy"
  name           = "securiti-user-policy-${random_id.user_id.hex}"
  statements     = ["Allow group ${oci_identity_group.securiti_user_group.name} to read all-resources in compartment id ${var.tenancy_ocid}"]
}

resource "time_sleep" "wait_for_creds_to_be_ready" {
  depends_on      = [null_resource.notify_login, oci_identity_policy.securiti_user_policy]
  create_duration = "300s"
}

resource "null_resource" "notify_call" {
  triggers = {
    version = local.version
  }

  provisioner "local-exec" {
    command = <<CURL
curl -b /tmp/${random_id.cookie_jar_id.hex}.jar --request POST '${var.securiti_endpoint}/privaci/v1/admin/xpod/auth_ready' \
  --header 'Content-Type: application/json' \
  --data '${jsonencode({ "connector_id" : var.connector_id, "token" : var.securiti_token, "uid" : oci_identity_user.securiti_user.id, "tid" : var.tenancy_ocid, "fingerprint" : oci_identity_api_key.api_key.fingerprint, "cloud_type" : "oci", "region" : var.region })}'
CURL
  }

  depends_on = [time_sleep.wait_for_creds_to_be_ready]
}

resource "null_resource" "notify_logout" {
  triggers = {
    version = local.version
  }

  provisioner "local-exec" {
    command = <<CURL
curl -b /tmp/${random_id.cookie_jar_id.hex}.jar -X POST '${var.securiti_endpoint}/core/v1/auth/basic/signout' \
  --data ""
CURL
  }

  depends_on = [null_resource.notify_call]
}
