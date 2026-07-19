###############################################################################
# Partition context (used to build the built-in ACM PCA template ARNs)
###############################################################################

data "aws_partition" "current" {}

locals {
 is_root = var.type == "ROOT"

 # Whether the module signs the CA's CSR in-module (self_signed / parent_module).
 # In "external" mode the signing happens outside Terraform, so no
 # aws_acmpca_certificate.this is rendered.
 do_signing = var.activation != null && contains(["self_signed", "parent_module"], var.activation.mode)

 # Whether the module installs a certificate onto the CA (the step that flips it
 # to ACTIVE). For in-module signing this always renders; for external signing it
 # renders only once the caller supplies the signed PEM.
 do_install = var.activation != null && (contains(["self_signed", "parent_module"], var.activation.mode) ||
 (var.activation.mode == "external" && try(var.activation.signed_certificate, null) != null))

 # Built-in ACM PCA template ARNs (partition-aware). Root CAs self-sign with the
 # Root template; subordinate CAs use the PathLen0 subordinate template.
 acmpca_template_prefix = "arn:${data.aws_partition.current.partition}:acm-pca:::template"
 default_activation_template_arn = local.is_root ? ("${local.acmpca_template_prefix}/RootCACertificate/V1"): ("${local.acmpca_template_prefix}/SubordinateCACertificate_PathLen0/V1")
}

###############################################################################
# Certificate Authority (keystone)
#
# Created in PENDING_CERTIFICATE status — it exposes a CSR but cannot issue
# certificates until a signed certificate is installed (see the activation
# resources below). certificate_authority_configuration is FORCE-NEW in full.
###############################################################################

resource "aws_acmpca_certificate_authority" "this" {
 type = var.type
 usage_mode = var.usage_mode
 key_storage_security_standard = var.key_storage_security_standard
 permanent_deletion_time_in_days = var.permanent_deletion_time_in_days
 enabled = var.enabled

 certificate_authority_configuration {
 key_algorithm = var.certificate_authority_configuration.key_algorithm
 signing_algorithm = var.certificate_authority_configuration.signing_algorithm

 subject {
 common_name = var.certificate_authority_configuration.subject.common_name
 country = try(var.certificate_authority_configuration.subject.country, null)
 organization = try(var.certificate_authority_configuration.subject.organization, null)
 organizational_unit = try(var.certificate_authority_configuration.subject.organizational_unit, null)
 state = try(var.certificate_authority_configuration.subject.state, null)
 locality = try(var.certificate_authority_configuration.subject.locality, null)
 distinguished_name_qualifier = try(var.certificate_authority_configuration.subject.distinguished_name_qualifier, null)
 generation_qualifier = try(var.certificate_authority_configuration.subject.generation_qualifier, null)
 given_name = try(var.certificate_authority_configuration.subject.given_name, null)
 initials = try(var.certificate_authority_configuration.subject.initials, null)
 pseudonym = try(var.certificate_authority_configuration.subject.pseudonym, null)
 surname = try(var.certificate_authority_configuration.subject.surname, null)
 title = try(var.certificate_authority_configuration.subject.title, null)
 }
 }

 dynamic "revocation_configuration" {
 for_each = var.revocation != null ? [var.revocation]: []
 content {
 dynamic "crl_configuration" {
 for_each = try(revocation_configuration.value.crl, null) != null ? [revocation_configuration.value.crl]: []
 content {
 enabled = crl_configuration.value.enabled
 s3_bucket_name = try(crl_configuration.value.s3_bucket_name, null)
 expiration_in_days = try(crl_configuration.value.expiration_in_days, null)
 custom_cname = try(crl_configuration.value.custom_cname, null)
 s3_object_acl = try(crl_configuration.value.s3_object_acl, null)
 }
 }

 dynamic "ocsp_configuration" {
 for_each = try(revocation_configuration.value.ocsp, null) != null ? [revocation_configuration.value.ocsp]: []
 content {
 enabled = ocsp_configuration.value.enabled
 ocsp_custom_cname = try(ocsp_configuration.value.ocsp_custom_cname, null)
 }
 }
 }
 }

 tags = merge({ Name = var.name }, var.tags)
}

###############################################################################
# Activation step 1 — sign the CA's CSR (self_signed / parent_module only)
#
# Root CA: certificate_authority_arn points back at THIS CA (self-signature).
# Subordinate CA: certificate_authority_arn points at the parent CA that signs it.
# The CSR always comes from THIS CA's certificate_signing_request attribute — an
# implicit dependency Terraform resolves in a single apply (no cycle: the CA does
# not reference the certificate, only the reverse).
###############################################################################

resource "aws_acmpca_certificate" "this" {
 for_each = local.do_signing ? { this = var.activation }: {}

 certificate_authority_arn = (each.value.mode == "self_signed"
 ? aws_acmpca_certificate_authority.this.arn
: each.value.parent_certificate_authority_arn)
 certificate_signing_request = aws_acmpca_certificate_authority.this.certificate_signing_request
 signing_algorithm = coalesce(try(each.value.signing_algorithm, null), var.certificate_authority_configuration.signing_algorithm)
 template_arn = coalesce(try(each.value.template_arn, null), local.default_activation_template_arn)

 validity {
 type = each.value.validity.type
 value = each.value.validity.value
 }
}

###############################################################################
# Activation step 2 — install the signed certificate onto the CA
#
# This is the action that flips the CA from PENDING_CERTIFICATE to ACTIVE.
# certificate: the in-module signed cert, or (external mode) caller PEM.
# certificate_chain: REQUIRED for SUBORDINATE, FORBIDDEN for ROOT — set null
# for root regardless of activation mode.
###############################################################################

resource "aws_acmpca_certificate_authority_certificate" "this" {
 for_each = local.do_install ? { this = true }: {}

 certificate_authority_arn = aws_acmpca_certificate_authority.this.arn

 certificate = (var.activation.mode == "external"
 ? var.activation.signed_certificate
: aws_acmpca_certificate.this["this"].certificate)

 certificate_chain = local.is_root ? null: (var.activation.mode == "external"
 ? try(var.activation.certificate_chain, null)
: aws_acmpca_certificate.this["this"].certificate_chain)
}

###############################################################################
# End-entity certificates (child collection) — issued directly off the CA
#
# depends_on the activation install so the CA is ACTIVE before issuance is
# attempted (the CA ARN alone exists in PENDING_CERTIFICATE, so an explicit
# dependency is required here — there is no attribute linkage that forces order).
###############################################################################

resource "aws_acmpca_certificate" "issued" {
 for_each = var.issued_certificates

 certificate_authority_arn = aws_acmpca_certificate_authority.this.arn
 certificate_signing_request = each.value.certificate_signing_request
 signing_algorithm = coalesce(try(each.value.signing_algorithm, null), var.certificate_authority_configuration.signing_algorithm)
 template_arn = try(each.value.template_arn, null)
 api_passthrough = try(each.value.api_passthrough, null)

 validity {
 type = each.value.validity.type
 value = each.value.validity.value
 }

 depends_on = [aws_acmpca_certificate_authority_certificate.this]
}

###############################################################################
# ACM auto-renewal permission (aws_acmpca_permission)
#
# Grants acm.amazonaws.com the three actions ACM needs to auto-renew private
# certificates it issues from this CA. acm.amazonaws.com is the only principal the
# API accepts on this resource.
###############################################################################

resource "aws_acmpca_permission" "this" {
 for_each = var.create_acm_service_permission ? { this = true }: {}

 certificate_authority_arn = aws_acmpca_certificate_authority.this.arn
 actions = ["IssueCertificate", "GetCertificate", "ListPermissions"]
 principal = "acm.amazonaws.com"
 source_account = var.permission_source_account
}

###############################################################################
# Resource-based policy (aws_acmpca_policy) — cross-account issuance sharing
###############################################################################

resource "aws_acmpca_policy" "this" {
 for_each = var.policy != null ? { this = true }: {}

 resource_arn = aws_acmpca_certificate_authority.this.arn
 policy = var.policy
}
