###############################################################################
# Primary outputs (id + arn)
#
# On aws_acmpca_certificate_authority, id and arn are the SAME ARN string; both
# are emitted for consistency with the id + arn convention across the library.
###############################################################################

output "id" {
 description = "The ID of the certificate authority — identical to its ARN (arn:<partition>:acm-pca:<region>:<account>:certificate-authority/<uuid>)."
 value = aws_acmpca_certificate_authority.this.id
}

output "arn" {
 description = <<EOT
The ARN of the certificate authority (cross-resource reference type). Wire into
terraform-aws-acm (certificate_authority_arn for ACM-Private-CA-backed certs),
terraform-aws-iam-policy (resource-scoped issuance policies), and any subordinate
CA's activation.parent_certificate_authority_arn.
EOT
 value = aws_acmpca_certificate_authority.this.arn
}

###############################################################################
# Activation / CSR material
###############################################################################

output "certificate_signing_request" {
 description = <<EOT
The base64 PEM-encoded CSR for the CA's own certificate. Export this to have an
external/offline root sign the CA (activation.mode = "external"), or observe the
value the in-module self/parent signing consumes.
EOT
 value = aws_acmpca_certificate_authority.this.certificate_signing_request
}

output "certificate" {
 description = "The base64 PEM-encoded CA certificate installed on the authority. Only populated after activation; null-equivalent (empty) on a PENDING_CERTIFICATE CA."
 value = aws_acmpca_certificate_authority.this.certificate
}

output "certificate_chain" {
 description = "The base64 PEM-encoded CA certificate chain (subordinate CAs only). Only populated after a subordinate CA is activated; empty for root CAs."
 value = aws_acmpca_certificate_authority.this.certificate_chain
}

output "not_before" {
 description = "Start of the CA certificate validity window. Only populated after activation."
 value = aws_acmpca_certificate_authority.this.not_before
}

output "not_after" {
 description = "End of the CA certificate validity window. Only populated after activation."
 value = aws_acmpca_certificate_authority.this.not_after
}

output "serial" {
 description = "Serial number of the CA certificate. Only populated after activation."
 value = aws_acmpca_certificate_authority.this.serial
}

###############################################################################
# End-entity certificates (child collection)
###############################################################################

output "issued_certificate_arns" {
 description = "Map of issued_certificates key => certificate ARN for each end-entity certificate issued off this CA."
 value = { for k, c in aws_acmpca_certificate.issued: k => c.arn }
}

output "issued_certificates" {
 description = "Map of issued_certificates key => { arn, certificate (PEM), certificate_chain (PEM) } for each end-entity certificate. The PEM material is not secret (public certificates)."
 value = {
 for k, c in aws_acmpca_certificate.issued: k => {
 arn = c.arn
 certificate = c.certificate
 certificate_chain = c.certificate_chain
 }
 }
}

###############################################################################
# Permission / policy
###############################################################################

output "acm_permission_policy" {
 description = "The IAM policy JSON associated with the ACM service permission when create_acm_service_permission = true; null otherwise."
 value = try(aws_acmpca_permission.this["this"].policy, null)
}

###############################################################################
# Tags
###############################################################################

output "tags_all" {
 description = "All tags on the certificate authority, including those inherited from provider default_tags (resource tags win on key conflict)."
 value = aws_acmpca_certificate_authority.this.tags_all
}
