locals {
  version          = "0.1.0"
  compartment_ocid = var.tenancy_ocid
  secure_tmp_dir   = "/tmp/securiti_${random_id.tmpdir_id.hex}"
  cookie_jar       = "/tmp/securiti_${random_id.tmpdir_id.hex}/${random_id.cookie_jar_id.hex}.jar"
  config_file      = "/tmp/securiti_${random_id.tmpdir_id.hex}/${random_id.config_file_id.hex}.txt"
}

resource "random_id" "tmpdir_id" {
  byte_length = 8
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

resource "null_resource" "setup_secure_tmpdir" {
  triggers = {
    version = local.version
  }

  provisioner "local-exec" {
    command = "mkdir -p ${local.secure_tmp_dir} && chmod 700 ${local.secure_tmp_dir}"
  }
}

resource "null_resource" "notify_login" {
  triggers = {
    version = local.version
  }

  provisioner "local-exec" {
    command = <<-CURL
    printf 'url = "%s/core/v1/auth/basic/session?token=%s"\n' "$SECURITI_ENDPOINT" "$SECURITI_TOKEN" | \
    curl -sf -c ${local.cookie_jar} --config -
    CURL
    environment = {
      SECURITI_TOKEN    = var.securiti_token
      SECURITI_ENDPOINT = var.securiti_endpoint
    }
  }

  depends_on = [null_resource.setup_secure_tmpdir]
}

resource "null_resource" "get_config" {
  triggers = {
    version = local.version
  }

  provisioner "local-exec" {
    command = <<-CURL
    printf 'url = "%s/privaci/v1/admin/xpod/auth_config?token=%s&connector_id=%s"\n' "$SECURITI_ENDPOINT" "$SECURITI_TOKEN" "$CONNECTOR_ID" | \
    curl -sf -b ${local.cookie_jar} --config - -o ${local.config_file}
    CURL
    environment = {
      SECURITI_TOKEN    = var.securiti_token
      SECURITI_ENDPOINT = var.securiti_endpoint
      CONNECTOR_ID      = var.connector_id
    }
  }

  depends_on = [null_resource.notify_login]
}

resource "null_resource" "validate_config" {
  triggers = {
    version = local.version
  }

  provisioner "local-exec" {
    command = <<-VALIDATE
    test -s ${local.config_file} || { echo "ERROR: Config file is empty or missing" >&2; exit 1; }
    head -c 1 ${local.config_file} | grep -q '{' || { echo "ERROR: Config response is not valid JSON" >&2; exit 1; }
    grep -q '"data"' ${local.config_file} || { echo "ERROR: Config response missing expected 'data' field" >&2; exit 1; }
    VALIDATE
  }

  depends_on = [null_resource.get_config]
}

data "local_file" "public_key" {
  filename   = local.config_file
  depends_on = [null_resource.validate_config]
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
    command = <<-CURL
    printf '{"connector_id":"%s","token":"%s","uid":"%s","tid":"%s","fingerprint":"%s","cloud_type":"oci","region":"%s"}' \
      "$CONNECTOR_ID" "$SECURITI_TOKEN" "$USER_ID" "$TENANCY_OCID" "$FINGERPRINT" "$REGION" | \
    curl -sf -b ${local.cookie_jar} --request POST "$SECURITI_ENDPOINT/privaci/v1/admin/xpod/auth_ready" \
      --header 'Content-Type: application/json' --data @-
    CURL
    environment = {
      SECURITI_TOKEN    = var.securiti_token
      SECURITI_ENDPOINT = var.securiti_endpoint
      CONNECTOR_ID      = var.connector_id
      USER_ID           = oci_identity_user.securiti_user.id
      TENANCY_OCID      = var.tenancy_ocid
      FINGERPRINT       = oci_identity_api_key.api_key.fingerprint
      REGION            = var.region
    }
  }

  depends_on = [time_sleep.wait_for_creds_to_be_ready]
}

resource "null_resource" "notify_logout" {
  triggers = {
    version = local.version
  }

  provisioner "local-exec" {
    command = <<-CURL
    curl -sf -b ${local.cookie_jar} -X POST "$SECURITI_ENDPOINT/core/v1/auth/basic/signout" \
      --data ""
    CURL
    environment = {
      SECURITI_ENDPOINT = var.securiti_endpoint
    }
  }

  depends_on = [null_resource.notify_call]
}

resource "null_resource" "cleanup" {
  triggers = {
    version = local.version
  }

  provisioner "local-exec" {
    command = "rm -rf ${local.secure_tmp_dir}"
  }

  depends_on = [null_resource.notify_logout]
}
