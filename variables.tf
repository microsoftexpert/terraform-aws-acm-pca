###############################################################################
# Identity
###############################################################################

variable "name" {
 description = <<EOT
Logical name for this private CA. Used as the default `Name` tag on the CA and
for module labeling in outputs/diagnostics. AWS Private CA has no first-class
"name" argument — a CA's on-wire identity is its subject Distinguished Name and
its ARN — so this value is purely a friendly label. A `Name` key supplied in
var.tags takes precedence over this value (resource tags win on key conflict).
EOT
 type = string
}

###############################################################################
# CA configuration (Required) — FORCE-NEW as a whole
#
# Every field under certificate_authority_configuration is immutable: AWS Private
# CA provides no in-place key rotation or subject-DN update. Changing any of these
# REPLACES the CA (and orphans everything chained beneath it). Plan the key
# algorithm, signing algorithm, and subject up front.
###############################################################################

variable "certificate_authority_configuration" {
 description = <<EOT
Required algorithms and X.500 subject for the CA. FORCE-NEW — every field here is
immutable; changing any value destroys and recreates the CA.

 - key_algorithm: (Required) public key algorithm and size. One of
 RSA_2048, RSA_4096, EC_prime256v1, EC_secp384r1.
 - signing_algorithm: (Required) algorithm the CA uses to sign certificate
 requests. One of SHA256WITHRSA, SHA384WITHRSA,
 SHA512WITHRSA, SHA256WITHECDSA, SHA384WITHECDSA,
 SHA512WITHECDSA. Match the family to key_algorithm (RSA
 key => *WITHRSA; EC key => *WITHECDSA).
 - subject: (Required) X.500 Distinguished Name. common_name is
 required; all other fields are optional. At least
 common_name is emitted so the provider's "at least one
 subject attribute" rule is always satisfied.

 certificate_authority_configuration = {
 key_algorithm = "RSA_2048"
 signing_algorithm = "SHA256WITHRSA"
 subject = {
 common_name = "Internal Root CA"
 organization = "Casey Wood"
 country = "US"
 }
 }
EOT
 type = object({
 key_algorithm = string
 signing_algorithm = string
 subject = object({
 common_name = string
 country = optional(string)
 organization = optional(string)
 organizational_unit = optional(string)
 state = optional(string)
 locality = optional(string)
 distinguished_name_qualifier = optional(string)
 generation_qualifier = optional(string)
 given_name = optional(string)
 initials = optional(string)
 pseudonym = optional(string)
 surname = optional(string)
 title = optional(string)
 })
 })

 validation {
 condition = contains(["RSA_2048", "RSA_4096", "EC_prime256v1", "EC_secp384r1"],
 var.certificate_authority_configuration.key_algorithm)
 error_message = "key_algorithm must be one of RSA_2048, RSA_4096, EC_prime256v1, or EC_secp384r1."
 }

 validation {
 condition = contains(["SHA256WITHRSA", "SHA384WITHRSA", "SHA512WITHRSA", "SHA256WITHECDSA", "SHA384WITHECDSA", "SHA512WITHECDSA"],
 var.certificate_authority_configuration.signing_algorithm)
 error_message = "signing_algorithm must be one of SHA256WITHRSA, SHA384WITHRSA, SHA512WITHRSA, SHA256WITHECDSA, SHA384WITHECDSA, or SHA512WITHECDSA."
 }
}

###############################################################################
# CA type and mode
###############################################################################

variable "type" {
 description = <<EOT
Type of the certificate authority. FORCE-NEW — a CA cannot change type after
creation. Defaults to SUBORDINATE (the provider default). One of:
 - ROOT: self-signed trust anchor; activate via activation.mode = "self_signed".
 - SUBORDINATE: signed by a parent CA; activate via activation.mode = "parent_module"
 (sibling/parent module) or "external" (offline/enterprise parent).
EOT
 type = string
 default = "SUBORDINATE"

 validation {
 condition = contains(["ROOT", "SUBORDINATE"], var.type)
 error_message = "type must be either ROOT or SUBORDINATE."
 }
}

variable "usage_mode" {
 description = <<EOT
Whether the CA issues general-purpose certificates (which typically require a
revocation mechanism) or short-lived certificates (which may omit revocation
because they expire quickly). Defaults to GENERAL_PURPOSE (the baseline —
supports full CRL/OCSP revocation tooling). SHORT_LIVED_CERTIFICATE caps issued
certificate validity at 7 days and changes billing (lower CA fee, no
per-certificate fee); document the operational tradeoff before selecting it.
EOT
 type = string
 default = "GENERAL_PURPOSE"

 validation {
 condition = contains(["GENERAL_PURPOSE", "SHORT_LIVED_CERTIFICATE"], var.usage_mode)
 error_message = "usage_mode must be either GENERAL_PURPOSE or SHORT_LIVED_CERTIFICATE."
 }
}

variable "key_storage_security_standard" {
 description = <<EOT
Cryptographic key-management compliance standard used for handling the CA's
private key material. Defaults to FIPS_140_2_LEVEL_3_OR_HIGHER (the highest
compliance tier — secure baseline). NOTE: Level-3 is not available in every
AWS Region; where the target Region lacks Level-3 support, fall back to
FIPS_140_2_LEVEL_2_OR_HIGHER after confirming Region support in the AWS Private
CA data-protection documentation.
EOT
 type = string
 default = "FIPS_140_2_LEVEL_3_OR_HIGHER"

 validation {
 condition = contains(["FIPS_140_2_LEVEL_2_OR_HIGHER", "FIPS_140_2_LEVEL_3_OR_HIGHER"], var.key_storage_security_standard)
 error_message = "key_storage_security_standard must be FIPS_140_2_LEVEL_2_OR_HIGHER or FIPS_140_2_LEVEL_3_OR_HIGHER."
 }
}

variable "permanent_deletion_time_in_days" {
 description = <<EOT
Number of days a deleted CA remains restorable before AWS permanently purges it
(soft-delete window). Defaults to 30 (the maximum recovery window — safe
default). May be lowered to a minimum of 7 for ephemeral/dev CAs that need faster
permanent teardown. A CA cannot be permanently deleted immediately.
EOT
 type = number
 default = 30

 validation {
 condition = var.permanent_deletion_time_in_days >= 7 && var.permanent_deletion_time_in_days <= 30
 error_message = "permanent_deletion_time_in_days must be between 7 and 30 inclusive."
 }
}

variable "enabled" {
 description = <<EOT
Whether the CA is enabled for certificate issuance. Defaults to true. Has no
effect until the CA is actually activated (see var.activation) — a CA that never
received its signed certificate is inert regardless of this flag. Setting false on
an ACTIVE CA immediately stops issuance without deleting the CA (break-glass kill
switch); a CA can only be disabled from an ACTIVE state.
EOT
 type = bool
 default = true
}

###############################################################################
# Revocation (CRL / OCSP)
#
# Secure default: when a CRL S3 bucket is supplied, CRL revocation is ON. The CRL
# object ACL defaults to BUCKET_OWNER_FULL_CONTROL — this module OVERRIDES the AWS
# provider default of PUBLIC_READ, which is unacceptable in an PII/privacy-regulation
# environment. Leave var.revocation null only with a documented compliance
# exception (a private CA with no revocation mechanism, or one relying on
# short-lived certificates).
###############################################################################

variable "revocation" {
 description = <<EOT
Optional revocation configuration for the CA. Leave null to create a CA with no
CRL/OCSP (only appropriate for SHORT_LIVED_CERTIFICATE usage or a documented
exception). regulated-industry workloads should enable CRL.

 crl (optional):
 - enabled: whether CRLs are generated. Defaults to true.
 - s3_bucket_name: bare S3 bucket NAME (not ARN) that stores the CRL.
 REQUIRED when crl.enabled = true. The bucket must
 already exist with a policy granting
 acm-pca.amazonaws.com s3:PutObject / s3:GetBucketAcl /
 s3:GetBucketLocation BEFORE the CA is created — AWS
 validates writability at CA-create time. Order it with
 depends_on in the caller (see README).
 - expiration_in_days: days until a generated CRL expires. Defaults to 7.
 - custom_cname: optional CNAME for the CRL distribution point.
 - s3_object_acl: BUCKET_OWNER_FULL_CONTROL (default, secure) or
 PUBLIC_READ (only if the CRL must be publicly fetchable
 by external relying parties — document the exception).

 ocsp (optional):
 - enabled: whether a custom OCSP responder is enabled. Defaults to
 false (CRL is the baseline; OCSP is additive).
 - ocsp_custom_cname: optional CNAME for the OCSP responder.

 revocation = {
 crl = {
 enabled = true
 s3_bucket_name = module.crl_bucket.id
 }
 }
EOT
 type = object({
 crl = optional(object({
 enabled = optional(bool, true)
 s3_bucket_name = optional(string)
 expiration_in_days = optional(number, 7)
 custom_cname = optional(string)
 s3_object_acl = optional(string, "BUCKET_OWNER_FULL_CONTROL")
 }))
 ocsp = optional(object({
 enabled = optional(bool, false)
 ocsp_custom_cname = optional(string)
 }))
 })
 default = null

 validation {
 condition = var.revocation == null || try(var.revocation.crl, null) == null || var.revocation.crl.enabled == false || try(var.revocation.crl.s3_bucket_name, null) != null
 error_message = "revocation.crl.s3_bucket_name is required when revocation.crl.enabled = true (AWS validates CRL bucket writability at CA-create time)."
 }

 validation {
 condition = var.revocation == null || try(var.revocation.crl, null) == null || try(var.revocation.crl.s3_object_acl, null) == null || contains(["BUCKET_OWNER_FULL_CONTROL", "PUBLIC_READ"], var.revocation.crl.s3_object_acl)
 error_message = "revocation.crl.s3_object_acl must be BUCKET_OWNER_FULL_CONTROL (secure default) or PUBLIC_READ."
 }
}

###############################################################################
# Activation (the CA two-step: sign the CSR, then install the certificate)
#
# Creating the CA leaves it in PENDING_CERTIFICATE — it cannot issue certificates
# until a signed certificate is installed on it. This variable selects HOW the
# CSR is signed and the certificate installed. Leave null to activate the CA
# out-of-band (advanced — the CA sits inert until you install a certificate
# yourself); otherwise the module models AWS's three-call activation state machine
# (CreateCertificateAuthority -> IssueCertificate -> ImportCertificateAuthorityCertificate).
###############################################################################

variable "activation" {
 description = <<EOT
Optional CA activation. Leave null to handle activation outside this module (the
CA will remain in PENDING_CERTIFICATE and cannot issue certificates until you
install a signed certificate on it — see README Troubleshooting).

 - mode: (Required when set) one of:
 "self_signed": ROOT CA self-signs its own CSR in-module (requires
 type = "ROOT").
 "parent_module": SUBORDINATE CA whose CSR is signed by a parent CA managed
 by another (already-ACTIVE) module/root (requires
 type = "SUBORDINATE" and parent_certificate_authority_arn).
 "external": the signed certificate (and chain, for subordinates) is
 produced outside Terraform — an offline/enterprise root or
 a cross-account CA with no data-source visibility — and
 supplied here as PEM. The install resource renders only
 once signed_certificate is provided.
 - parent_certificate_authority_arn: parent CA ARN that signs the CSR. Required
 for mode = "parent_module".
 - signing_algorithm: algorithm used to sign the activation certificate.
 Defaults to certificate_authority_configuration.signing_algorithm.
 - template_arn: ACM PCA template ARN. Defaults to RootCACertificate/V1 for
 ROOT and SubordinateCACertificate_PathLen0/V1 for
 SUBORDINATE.
 - validity: validity window for the activation certificate. Defaults
 to { type = "YEARS", value = 10 }. type is one of DAYS,
 MONTHS, YEARS, ABSOLUTE, END_DATE.
 - signed_certificate: (mode = "external" only) PEM of the externally-signed CA
 certificate.
 - certificate_chain: (mode = "external" only) PEM chain up to the root.
 Required for an external SUBORDINATE; omitted for ROOT.

 activation = {
 mode = "self_signed"
 validity = { type = "YEARS", value = 10 }
 }
EOT
 type = object({
 mode = string
 parent_certificate_authority_arn = optional(string)
 signing_algorithm = optional(string)
 template_arn = optional(string)
 validity = optional(object({
 type = string
 value = number
 }), { type = "YEARS", value = 10 })
 signed_certificate = optional(string)
 certificate_chain = optional(string)
 })
 default = null

 validation {
 condition = var.activation == null || contains(["self_signed", "parent_module", "external"], var.activation.mode)
 error_message = "activation.mode must be one of \"self_signed\", \"parent_module\", or \"external\"."
 }

 validation {
 condition = var.activation == null || var.activation.mode != "self_signed" || var.type == "ROOT"
 error_message = "activation.mode = \"self_signed\" requires type = \"ROOT\" (only a root CA self-signs its own certificate)."
 }

 validation {
 condition = var.activation == null || var.activation.mode != "parent_module" || (var.type == "SUBORDINATE" && try(var.activation.parent_certificate_authority_arn, null) != null)
 error_message = "activation.mode = \"parent_module\" requires type = \"SUBORDINATE\" and activation.parent_certificate_authority_arn (the signing parent CA's ARN)."
 }

 validation {
 condition = var.activation == null || var.activation.validity == null || contains(["DAYS", "MONTHS", "YEARS", "ABSOLUTE", "END_DATE"], var.activation.validity.type)
 error_message = "activation.validity.type must be one of DAYS, MONTHS, YEARS, ABSOLUTE, or END_DATE."
 }
}

###############################################################################
# End-entity certificates (child collection — for_each over a map)
#
# Ad-hoc certificates issued directly off this CA once it is ACTIVE. NOTE:
# aws_acmpca_certificate is NOT renewable — issued certificates must be replaced,
# not renewed. For auto-renewing certificates, wire terraform-aws-acm's
# certificate_authority_arn to this CA instead (and set create_acm_service_permission).
###############################################################################

variable "issued_certificates" {
 description = <<EOT
Optional end-entity (leaf) certificates to issue directly from this CA, keyed by a
stable name. Each renders one aws_acmpca_certificate that depends on the CA being
ACTIVE. These are not renewable — replace, don't renew.

 - certificate_signing_request: (Required) CSR in PEM format for the leaf cert.
 - signing_algorithm: defaults to the CA's signing_algorithm.
 - template_arn: ACM PCA template ARN (e.g.
.../template/EndEntityCertificate/V1). Null uses
 the AWS default template.
 - validity: (Required) { type, value }. type is one of DAYS,
 MONTHS, YEARS, ABSOLUTE, END_DATE.
 - api_passthrough: optional JSON of X.509 fields to embed (used with
 API-passthrough templates).

 issued_certificates = {
 app-tls = {
 certificate_signing_request = file("app.csr")
 validity = { type = "DAYS", value = 90 }
 }
 }
EOT
 type = map(object({
 certificate_signing_request = string
 signing_algorithm = optional(string)
 template_arn = optional(string)
 validity = object({
 type = string
 value = number
 })
 api_passthrough = optional(string)
 }))
 default = {}

 validation {
 condition = alltrue([
 for c in var.issued_certificates:
 contains(["DAYS", "MONTHS", "YEARS", "ABSOLUTE", "END_DATE"], c.validity.type)
 ])
 error_message = "Each issued_certificates[*].validity.type must be one of DAYS, MONTHS, YEARS, ABSOLUTE, or END_DATE."
 }
}

###############################################################################
# Permissions and resource policy
###############################################################################

variable "create_acm_service_permission" {
 description = <<EOT
Whether to grant the ACM service principal (acm.amazonaws.com) the
IssueCertificate / GetCertificate / ListPermissions actions on this CA via
aws_acmpca_permission. Required so that ACM-managed certificates backed by this
private CA (terraform-aws-acm with certificate_authority_arn set) can AUTO-RENEW.
Defaults to false. acm.amazonaws.com is the only principal AWS accepts here.
EOT
 type = bool
 default = false
}

variable "permission_source_account" {
 description = "Optional calling-account ID for the ACM service permission (aws_acmpca_permission.source_account). Null (default) uses the current account. Only meaningful when create_acm_service_permission = true."
 type = string
 default = null
}

variable "policy" {
 description = <<EOT
Optional resource-based IAM policy (JSON-encoded string) attached to the CA via
aws_acmpca_policy, enabling cross-account sharing of issuance rights (e.g. via AWS
RAM or direct principal grants). Leave null (default) for no resource policy.
Build with jsonencode() or aws_iam_policy_document. This is distinct from
create_acm_service_permission, which is the narrow, fixed-principal ACM
auto-renewal grant.
EOT
 type = string
 default = null

 validation {
 condition = var.policy == null || can(jsondecode(var.policy))
 error_message = "policy must be a valid JSON-encoded IAM policy document, or null."
 }
}

###############################################################################
# Universal tail
###############################################################################

variable "tags" {
 description = <<EOT
A map of tags to assign to the certificate authority (the only taggable resource
in this module — aws_acmpca_certificate, _authority_certificate, _permission, and
_policy expose no tags argument). These merge with provider-level default_tags;
resource tags win on key conflict. The computed tags_all output reflects the
merged set. A `Name` key here overrides the default Name derived from var.name.
EOT
 type = map(string)
 default = {}
}
