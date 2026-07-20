# terraform-aws-acm-pca — SCOPE

Composite **security** module for an AWS Certificate Manager Private Certificate
Authority (ACM PCA / "AWS Private CA"). It owns the private CA itself, its
activation chain (CSR issuance + certificate installation), least-privilege
resource policies and service-principal permissions, and secondary end-entity
certificates issued off the CA — so a single module call yields an
active, encrypted, revocation-aware private CA that other modules and
workloads can issue certificates from, without hand-wiring the CA activation
state machine in root modules.

- **Module type:** Composite (security)
- **Primary resource (keystone):** `aws_acmpca_certificate_authority.this`

> ⚠️ **The single biggest gotcha in this module: CA activation is a two-step,
> circularly-dependent process.** See "Provider gotchas" and "Design
> decisions" below before touching `main.tf`. A CA created but never activated
> sits in `PENDING_CERTIFICATE` status and **cannot issue certificates** —
> Terraform will not fail loudly on this; the CA simply stays inert.

## In-scope resources

The module manages **all** of the following (allow-list):

- `aws_acmpca_certificate_authority` — keystone; the private CA itself
  (`ROOT` or `SUBORDINATE`), its key/signing algorithm, subject DN, revocation
  configuration (CRL/OCSP), and usage mode
- `aws_acmpca_certificate` — issues a certificate from a CA's own CSR (for
  root self-signature) or from a child CA's CSR (for subordinate activation),
  and optionally issues additional end-entity certificates off an already
  active CA (child collection, `for_each`)
- `aws_acmpca_certificate_authority_certificate` — installs a signed
  certificate (and chain, for subordinates) onto the CA, the action that
  flips CA status from `PENDING_CERTIFICATE` to `ACTIVE`
- `aws_acmpca_permission` — grants an AWS service principal (in practice only
  `acm.amazonaws.com`) permission to call `IssueCertificate` /
  `GetCertificate` / `ListPermissions` against the CA, so `terraform-aws-acm`
  certificates backed by this CA can auto-renew
- `aws_acmpca_policy` — attaches a resource-based IAM policy to the CA,
  enabling cross-account sharing of issuance rights (e.g. via AWS RAM /
  direct principal grants) without a permission's fixed service-principal
  restriction

## Out-of-scope resources (consumed by reference)

Referenced by `arn`/`id`, never created here:

- **KMS CMK** — ACM PCA always encrypts the CA's private key at rest inside
  the ACM PCA / CloudHSM-backed service boundary; **ACM PCA does not accept a
  caller-supplied `kms_key_id`/CMK argument on `aws_acmpca_certificate_authority`
  in the current provider schema** (verified against `hashicorp/aws` v6.53.0
  — no such argument exists). This is a **correction to the seed brief**: Casey's
  "customer-managed KMS key" secure-by-default posture cannot be implemented as
  a direct CA encryption key the way it is for S3/RDS/EBS. Where a
  caller-supplied CMK is genuinely required (e.g. audit-report or CRL bucket
  encryption), it is wired through the **destination** module
  (`terraform-aws-s3-bucket`), not through this module. See "Secure-by-default
  decisions" for how encryption is actually enforced here.
- **S3 bucket for CRL storage** — `aws_s3_bucket` and its bucket policy are
  owned by `terraform-aws-s3-bucket`; this module only consumes the bucket's
  `id`/`arn` to populate `crl_configuration.s3_bucket_name`. The **caller is
  responsible** for attaching an S3 bucket policy granting
  `acm-pca.amazonaws.com` `s3:PutObject`/`s3:GetBucketAcl`/`s3:GetBucketLocation`
  on that bucket **before** `aws_acmpca_certificate_authority.this` is created
  with CRL enabled — the CA create call validates bucket writability at
  creation time when CRL is enabled inline. Model this as a `depends_on` in
  the caller's root module (see the VPC module's `depends_on` pattern for the
  S3 bucket policy → CA example in the upstream Terraform Registry docs).
- **External/offline signing CA** — when a subordinate CA is signed by a CA
  outside this AWS account/module (e.g. an on-prem enterprise root, or a
  cross-account root CA managed by a different module call), the signed
  certificate and chain are supplied as **caller input** (PEM strings) rather
  than produced by an in-module `aws_acmpca_certificate` resource. This module
  supports both paths (see `variables.tf` design).
- **IAM roles/policies for callers** who need to invoke `acm-pca:IssueCertificate`
  etc. — owned by `terraform-aws-iam-role` / `terraform-aws-iam-policy`; this module
  only emits the CA `arn` for those policies to reference.
- **AWS Certificate Manager (public/private-issued) certificates consumed by
  ALB/CloudFront** — owned by `terraform-aws-acm`, which references this module's
  CA `arn` via its own `certificate_authority_arn` argument for
  ACM-private-CA-backed certs.

## Consumes

| Input (as authored) | Type | Source module |
|---|---|---|
| `revocation.crl.s3_bucket_name` | `string` (bucket name, not ARN — the provider argument is `s3_bucket_name`) | `terraform-aws-s3-bucket` (`.id` / bucket name output) |
| `activation.parent_certificate_authority_arn` (mode `"parent_module"`) | `string` (CA ARN) | a parent `terraform-aws-acm-pca` instance (`arn` output) |
| `activation.signed_certificate` / `activation.certificate_chain` (mode `"external"`) | `string` (PEM) | Caller-supplied (offline/enterprise root CA) — not a sibling module |
| `policy` | `string` (JSON) | `terraform-aws-iam-policy` document / `jsonencode()` |

> This module does **not** consume a KMS key ARN — see "Out-of-scope
> resources" above for why the seed brief's `kms_key_arn` input was removed.

> **Authored variable surface (final):** the seed brief referred informally to
> `crl_s3_bucket_name`, `external_signed_certificate`/`external_certificate_chain`,
> `parent_certificate_authority_arn`, and `certificate_authority.type`. As
> implemented these are consolidated into nested objects for a coherent surface:
> the CRL bucket is `revocation.crl.s3_bucket_name`; the external PEM inputs are
> `activation.signed_certificate` / `activation.certificate_chain`; the parent CA
> ARN is `activation.parent_certificate_authority_arn`; and the CA type is the
> top-level `type` variable (matching the provider argument name). The ACM
> auto-renewal grant is exposed as the boolean `create_acm_service_permission`
> (+ optional `permission_source_account`).

## Required IAM permissions

Least-privilege actions the Terraform identity needs:

| Action | Required for |
|---|---|
| `acm-pca:CreateCertificateAuthority`, `acm-pca:DescribeCertificateAuthority`, `acm-pca:UpdateCertificateAuthority`, `acm-pca:DeleteCertificateAuthority`, `acm-pca:ListCertificateAuthorities` | CA lifecycle |
| `acm-pca:GetCertificateAuthorityCsr` | Reading the CSR exposed via `certificate_signing_request` |
| `acm-pca:IssueCertificate`, `acm-pca:GetCertificate` | Signing the CA's own CSR (root self-sign) or a subordinate's CSR (`aws_acmpca_certificate`), and issuing end-entity certs |
| `acm-pca:ImportCertificateAuthorityCertificate` | Installing the signed certificate/chain (`aws_acmpca_certificate_authority_certificate`) — the activation step |
| `acm-pca:GetCertificateAuthorityCertificate` | Reading back the installed CA certificate/chain attributes |
| `acm-pca:CreatePermission`, `acm-pca:DeletePermission`, `acm-pca:ListPermissions` | `aws_acmpca_permission` (ACM auto-renewal grant) |
| `acm-pca:PutPolicy`, `acm-pca:GetPolicy`, `acm-pca:DeletePolicy` | `aws_acmpca_policy` (resource-based cross-account policy) |
| `acm-pca:TagCertificateAuthority`, `acm-pca:UntagCertificateAuthority`, `acm-pca:ListTags` | Tagging |
| `s3:GetBucketAcl`, `s3:GetBucketLocation` | Validating CRL bucket accessibility at CA-create time (only when `revocation.crl.enabled = true`); the write grant itself (`s3:PutObject`, `s3:PutObjectAcl`) is on the **bucket policy**, not the Terraform identity |
| `kms:Decrypt`, `kms:GenerateDataKey` (conditional) | Only if the caller's CRL bucket uses SSE-KMS with a CMK whose key policy restricts principals — granted on the KMS key policy, not by this module |

> `iam:PassRole` is **not** required — ACM PCA has no pass-role dependency in
> this resource family (unlike, e.g., RDS monitoring roles).

## AWS Prerequisites

- **No service-linked role** is required for ACM PCA itself.
- **The CA activation two-step is a hard AWS API constraint, not a Terraform
  limitation** — see "Provider gotchas" below for the full sequencing.
- **CRL storage (opt-in but default-recommended):** if `revocation.crl.enabled
  = true`, the target S3 bucket must already exist and carry a bucket policy
  granting the `acm-pca.amazonaws.com` service principal
  `s3:GetBucketAcl`, `s3:GetBucketLocation`, `s3:PutObject`, and
  `s3:PutObjectAcl` — AWS validates this at CA-creation time when CRL is
  configured inline, so the bucket + policy must be created and (in Terraform)
  `depends_on`-ordered ahead of `aws_acmpca_certificate_authority.this`.
- **Key storage security standard region availability:** `FIPS_140_2_LEVEL_3_OR_HIGHER`
  (the module default) is not available in every AWS Region; confirm support
  for the target Region in the AWS Private CA data-protection documentation
  before deploying, or fall back to `FIPS_140_2_LEVEL_2_OR_HIGHER`.
- **Audit reports are an on-demand API action, not a Terraform-managed
  resource.** `CreateCertificateAuthorityAuditReport` is invoked via the AWS
  CLI/SDK/console against an **already-active** CA and writes a point-in-time
  report of issued/revoked certificates to an S3 bucket; there is no
  Terraform resource for it in `hashicorp/aws` v6.53.0. **This corrects the
  seed brief's "audit reports enabled" secure-by-default item** — this module
  cannot enable audit reports as a standing configuration. Document the
  `acm-pca:CreateCertificateAuthorityAuditReport` / `DescribeCertificateAuthorityAuditReport`
  actions as an operational runbook step (e.g. scheduled via EventBridge +
  Lambda, or a CI/CD pipeline job) outside this module's scope.
- **Deletion is soft-delete with a restoration window.** `permanent_deletion_time_in_days`
  (7–30 days, default 30) governs how long a deleted CA remains restorable
  before AWS permanently purges it. A CA cannot be permanently deleted
  immediately.
- **A CA must be `DISABLED` before it can be deleted**, and can only be
  `DISABLE`d from an `ACTIVE` state — a CA stuck in `PENDING_CERTIFICATE`
  (never activated) or `CREATING` cannot be cleanly disabled through the
  normal state transition; Terraform destroy handles this via the provider's
  internal delete logic, but manual console/CLI cleanup of stalled CAs should
  go through `DeletePermission`/state checks first.
- **Service quotas** (soft, Service Quotas console): default is a small number
  of private CAs per account/Region (historically 10, GENERAL_PURPOSE and
  SHORT_LIVED_CERTIFICATE tracked separately) and a certificate issuance
  rate limit (TPS) that can throttle bulk end-entity issuance — request an
  increase before large-scale rollouts.
- **`SHORT_LIVED_CERTIFICATE` usage mode** changes billing (lower monthly
  CA fee, no per-certificate fee) and caps issued-certificate validity at 7
  days — incompatible with long-lived revocation-configuration workflows;
  document this tradeoff for callers who set `usage_mode`.

## Emits

| Output | Description | Consumed by |
|---|---|---|
| `id` | CA ARN (ACM PCA's `id` and `arn` are the same ARN string) | Any module/policy referencing this CA |
| `arn` | CA ARN — `arn:aws:acm-pca:<region>:<account>:certificate-authority/<uuid>` | `terraform-aws-acm` (`certificate_authority_arn` for ACM-Private-CA-backed certs), `terraform-aws-iam-policy` (resource policies scoped to this CA), `terraform-aws-acmpca-permission`/policy callers |
| `certificate_signing_request` | Base64 PEM-encoded CSR for the CA's own certificate — required input to sign the CA (root self-sign or subordinate parent-sign) | Root-CA self-activation flow (`aws_acmpca_certificate` in this module); external signing workflows (exported for an offline enterprise root to sign) |
| `certificate` | Base64-encoded installed CA certificate (only populated after activation) | Audit / verification |
| `certificate_chain` | Base64-encoded installed CA certificate chain (subordinate CAs only) | Audit / trust-chain verification |
| `not_before` / `not_after` / `serial` | CA validity window and serial (only populated post-activation) | Certificate lifecycle monitoring |
| `issued_certificate_arns` | Map of ARNs for any end-entity certificates issued via the `issued_certificates` child collection | Workload TLS configuration, `terraform-aws-secrets-manager` (storing issued cert/key material) |
| `issued_certificates` | Map of key => `{ arn, certificate, certificate_chain }` (public PEM) | Workload TLS configuration |
| `acm_permission_policy` | IAM policy JSON of the ACM permission when `create_acm_service_permission = true`; null otherwise | Audit |
| `tags_all` | All tags incl. provider `default_tags` | Governance/audit |

> **Note:** `aws_acmpca_certificate_authority` does **not** export a `status`
> attribute on the *resource* (only the data source does), so the module emits
> the validity window (`not_before`/`not_after`/`serial`) instead — a non-null
> `not_after` is the practical signal that the CA has been activated.

## Provider gotchas

### The CA activation two-step (read this before writing `main.tf`)

Creating `aws_acmpca_certificate_authority.this` leaves the CA in
**`PENDING_CERTIFICATE`** status — it exists, has generated a key pair, and
exposes a CSR via the `certificate_signing_request` attribute, but **cannot
issue certificates** until a signed certificate is installed on it. This is
an AWS Private CA API constraint (`CreateCertificateAuthority` →
`GetCertificateAuthorityCsr` → sign → `ImportCertificateAuthorityCertificate`),
not a Terraform quirk — Terraform must model all three calls explicitly as
separate resources with an unambiguous dependency chain:

```
                         ┌────────────────────────────────────────┐
                         │  aws_acmpca_certificate_authority.this  │
                         │  status: PENDING_CERTIFICATE            │
                         │  exports: certificate_signing_request   │
                         └───────────────────┬──────────────────────┘
                                              │ CSR (PEM)
                                              ▼
        ┌─────────────────────────────────────────────────────────────┐
        │  WHO SIGNS THE CSR? — two supported paths                    │
        ├─────────────────────────────┬───────────────────────────────┤
        │ ROOT CA (self-signed)        │ SUBORDINATE CA                │
        │ aws_acmpca_certificate.this  │ aws_acmpca_certificate.this   │
        │   certificate_authority_arn  │   certificate_authority_arn   │
        │     = <this same CA>.arn     │     = <PARENT CA>.arn         │
        │   certificate_signing_request│   certificate_signing_request │
        │     = <this same CA>.csr     │     = <this CA>.csr           │
        │   template_arn = .../        │   template_arn = .../         │
        │     RootCACertificate/V1     │  SubordinateCACertificate_    │
        │                               │  PathLen0/V1 (or similar)     │
        │  OR: export the CSR and have  │  OR: export the CSR and have │
        │  an EXTERNAL/offline root CA  │  an external parent CA sign  │
        │  sign it (caller supplies PEM)│  it (caller supplies PEM)    │
        └─────────────────────────────┬───────────────────────────────┘
                                              │ signed certificate (+ chain
                                              │ for subordinates)
                                              ▼
        ┌─────────────────────────────────────────────────────────────┐
        │  aws_acmpca_certificate_authority_certificate.this            │
        │    certificate_authority_arn = aws_acmpca_certificate_       │
        │                                 authority.this.arn            │
        │    certificate       = <signed cert PEM>                      │
        │    certificate_chain = <chain PEM>  (REQUIRED for SUBORDINATE,│
        │                                       FORBIDDEN for ROOT)      │
        └───────────────────────────────┬───────────────────────────────┘
                                              │ install triggers AWS-side
                                              │ state transition
                                              ▼
                         ┌────────────────────────────────────────┐
                         │  CA status: ACTIVE                      │
                         │  Can now: IssueCertificate,             │
                         │  aws_acmpca_permission, aws_acmpca_policy│
                         │  (issued_certificates child collection) │
                         └──────────────────────────────────────────┘
```

Key sequencing facts verified against the live provider schema
(`hashicorp/aws` v6.53.0):

1. `aws_acmpca_certificate.certificate_signing_request` for the **root
   self-sign case** is set to
   `aws_acmpca_certificate_authority.this.certificate_signing_request` — an
   implicit `depends_on` via attribute reference, which Terraform resolves
   correctly in a single `apply` (create CA → read its CSR attribute → issue
   the certificate → install it) **without needing an explicit second
   `terraform apply`**, because there is no cycle: the CA resource does not
   reference the certificate resource, only the reverse.
2. For a **subordinate CA**, the CSR is still `aws_acmpca_certificate_authority.this.certificate_signing_request`
   (the subordinate's own CSR), but `certificate_authority_arn` on the
   `aws_acmpca_certificate` resource points at the **parent** CA's ARN (either
   a sibling `terraform-aws-acm-pca` module instance, or a `var.parent_certificate_authority_arn`
   pointing outside this module). The parent CA must already be `ACTIVE`
   (i.e., past its own two-step activation) before it can sign anything —
   this creates a strict cross-module ordering: **root module instance must
   fully activate before the subordinate module instance is applied.**
3. `certificate_chain` on `aws_acmpca_certificate_authority_certificate` is
   **required for `SUBORDINATE`** CAs and **forbidden/omitted for `ROOT`**
   CAs (a self-signed root has no chain above it) — the module conditionally
   sets this based on `var.certificate_authority.type`.
4. **No explicit `depends_on` is needed between the certificate and the
   installation resource** when using attribute references
   (`aws_acmpca_certificate.this.certificate` /
   `.certificate_chain`) — Terraform's implicit dependency graph from
   resource attribute interpolation is sufficient and is the house-style
   preferred pattern (explicit `depends_on` reserved for cases with no
   attribute linkage, e.g. the CRL S3 bucket policy).
5. **External/offline signing path:** when the signing authority lives
   outside Terraform's state (an enterprise root CA, a cross-account CA
   managed by a separate root module with no data-source visibility), this
   module skips the in-module `aws_acmpca_certificate` resource entirely for
   that CA and instead takes `var.external_signed_certificate` /
   `var.external_certificate_chain` (caller-supplied PEM strings, produced by
   whatever manual or pipeline process signed the exported CSR) directly into
   `aws_acmpca_certificate_authority_certificate.this`. The module's
   `activation.mode` variable (`"self_signed"` | `"parent_module"` |
   `"external"`) selects which path renders.
6. **A CA that is created but never activated is easy to leave silently
   broken.** If a caller sets `activation.mode = "external"` but never
   supplies the signed certificate (e.g., forgets to complete an offline
   signing ceremony), `terraform apply` succeeds (the CA resource alone has no
   required-activation validation) and the CA sits in `PENDING_CERTIFICATE`
   indefinitely. The module surfaces this risk in the README Troubleshooting
   section; it cannot be prevented purely with `validation {}` blocks because
   the external PEM is only known at a later apply.

### Other gotchas

- **`certificate_authority_configuration` is entirely FORCE-NEW.** Every field
  under it (`key_algorithm`, `signing_algorithm`, `subject.*`) requires
  replacing the CA — there is no in-place key rotation or subject-DN update.
  Plan the key algorithm and DN up front; "rotating" a private CA means
  standing up a new CA and re-issuing/re-chaining everything under it.
- **`type` (`ROOT` | `SUBORDINATE`) is FORCE-NEW.** A CA cannot change type
  after creation.
- **`enabled` can only be flipped to `false` from an `ACTIVE` state** — a CA
  that never activated cannot be meaningfully "disabled" (it is already
  inert). The module defaults `enabled = true` but this has no effect until
  the CA is actually activated by the certificate-installation step; setting
  it `false` on an activated CA immediately stops certificate issuance
  without deleting the CA (useful for a break-glass kill switch).
- **No `kms_key_id`/CMK argument exists on `aws_acmpca_certificate_authority`**
  in the current provider schema — ACM PCA manages its own HSM-backed key
  material via `key_storage_security_standard`, not customer-supplied KMS
  keys. Do not attempt to wire a `terraform-aws-kms` ARN directly into this
  resource; it will fail `terraform validate` (unsupported argument).
- **`aws_acmpca_certificate` is not renewable.** Certificates issued by this
  resource must be replaced (new resource, new serial), not renewed in place.
  For auto-renewing certificates backed by a private CA, wire
  `terraform-aws-acm`'s `certificate_authority_arn` at the ACM certificate
  layer instead (which is why `aws_acmpca_permission` granting
  `acm.amazonaws.com` exists — it is specifically for that ACM-managed
  renewal path).
- **`aws_acmpca_permission.principal` only accepts `acm.amazonaws.com`** in
  the current provider/API — this is not a general-purpose service-principal
  grant mechanism despite the resource name; cross-account or
  non-ACM-service sharing goes through `aws_acmpca_policy` instead.
- **Destroy ordering:** `aws_acmpca_permission` / `aws_acmpca_policy` must be
  removed (or Terraform will remove them automatically pre-CA-delete via the
  dependency graph) before the CA itself can be deleted; a CA with active
  permissions/policy attachments does not block deletion at the API level,
  but a CA still `ENABLED`/`ACTIVE` must be disabled first — the provider
  handles the disable-then-delete sequence internally on `terraform destroy`,
  subject to the `permanent_deletion_time_in_days` soft-delete window.
- **`tags` vs `tags_all`.** `var.tags` flows to every taggable resource in the
  composite (only `aws_acmpca_certificate_authority` is taggable in this
  resource family — `aws_acmpca_certificate`, `_authority_certificate`,
  `_permission`, and `_policy` expose no `tags` argument); `tags_all` is the
  CA's computed merge of resource tags over provider `default_tags` (resource
  tags win). `default_tags` remains the caller's provider-block concern.
- **`id` and `arn` are identical** on `aws_acmpca_certificate_authority` — both
  resolve to the same ARN string; the module still emits both per the Casey's
  `id` + `arn` convention for consumer consistency across the library.

## Secure-by-default decisions

| Posture | Default | Opt-out |
|---|---|---|
| Key storage security standard | `FIPS_140_2_LEVEL_3_OR_HIGHER` (highest available compliance tier) | `key_storage_security_standard = "FIPS_140_2_LEVEL_2_OR_HIGHER"` — only where the target Region lacks Level-3 support |
| Revocation — CRL | **Enabled by default** (`revocation.crl.enabled = true`) when a `crl_s3_bucket_name` is supplied; the module refuses to silently skip revocation without an explicit opt-out | `revocation.crl.enabled = false` (requires a documented compliance exception — GLBA/FCA environments should not run a private CA with no revocation mechanism) |
| Revocation — OCSP | Disabled by default (CRL is the Casey's baseline mechanism); available as an additive/alternative control | `revocation.ocsp.enabled = true` with an optional custom CNAME |
| CRL object ACL | `BUCKET_OWNER_FULL_CONTROL` (never `PUBLIC_READ`) — **this module overrides the AWS provider default of `PUBLIC_READ`**, which is not acceptable for an NPI/GLBA environment even though the CRL itself is not NPI | `s3_object_acl` override to `PUBLIC_READ` only if the CRL must be publicly fetchable by external relying parties (common for public-facing use cases; document the exception) |
| CA usage mode | `GENERAL_PURPOSE` (supports full revocation tooling) | `usage_mode = "SHORT_LIVED_CERTIFICATE"` — trades revocation infrastructure for 7-day-max certificate lifetimes; document the operational tradeoff |
| Soft-delete window | `permanent_deletion_time_in_days = 30` (maximum recovery window) | Lower to as little as 7 days if faster permanent teardown is required (e.g. ephemeral dev CAs) |
| Encryption at rest | Always-on, AWS-managed HSM-backed key material (no caller CMK option exists on this resource — see Provider gotchas) | Not applicable — no opt-out surface; this is a hard AWS Private CA platform guarantee, not a module-configurable default |
| Audit reports | **Not a standing Terraform-managed control** (corrected from the seed brief — no such resource/argument exists); documented as a required operational runbook item outside this module | N/A — implement via a scheduled Lambda/EventBridge or pipeline step calling `acm-pca:CreateCertificateAuthorityAuditReport` |

## Design decisions

- **Activation is modeled as three distinct resources, never collapsed into
  one.** Even though `aws_acmpca_certificate_authority_certificate` is what
  ultimately activates the CA, keeping CA / signing-certificate / installation
  as three separate resources mirrors the AWS API's own three-call model
  (`CreateCertificateAuthority` / `IssueCertificate` / `ImportCertificateAuthorityCertificate`)
  and lets `terraform plan` show exactly which phase of activation a change
  affects — collapsing them would obscure the CSR-signing dependency that is
  this resource family's defining constraint.
- **`activation.mode` is a closed enum (`"self_signed"`, `"parent_module"`,
  `"external"`)** rather than inferring behavior from which optional
  variables are set, so `terraform plan` intent is explicit and
  `validation {}` blocks can enforce mutually-exclusive input combinations
  (e.g. `parent_certificate_authority_arn` required only in `"parent_module"`
  mode).
- **`issued_certificates` end-entity certs are a child collection
  (`for_each` over `map(object(...))`), separate from the activation
  certificate.** Activation is a singleton concern per CA; ad-hoc end-entity
  issuance (e.g. bootstrap certs, non-ACM-managed workloads) is a
  variable-cardinality concern best modeled as a map, consistent with the Casey's
  composite pattern (child collections use `for_each`, no `count`).
- **No customer-managed KMS input, despite the seed brief and Casey's general
  CMK-everywhere posture** — corrected after verifying the live provider
  schema exposes no such argument on any of the five in-scope resources.
  Documenting this explicitly (rather than silently dropping the seed
  requirement) avoids a future author re-adding a non-existent argument.
- **CRL storage is consumed by bucket name, not ARN**, because the
  `crl_configuration.s3_bucket_name` provider argument is a bare bucket name
  string, not an ARN — the module input is deliberately named
  `crl_s3_bucket_name` (not `crl_s3_bucket_arn`) to avoid caller confusion,
  even though every other cross-module reference in the Casey's library prefers
  ARNs.
- **Permissions vs. policy are kept as two separate optional features**
  (`aws_acmpca_permission` for the narrow ACM-auto-renewal grant,
  `aws_acmpca_policy` for general resource-based cross-account policy)
  because they serve genuinely different purposes at the API level and have
  different cardinality (permission is scoped to a fixed principal;
  policy is a single full IAM policy document per CA).
