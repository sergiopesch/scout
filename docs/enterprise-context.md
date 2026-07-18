# Enterprise context policy

Reviewed 2026-07-17. This document is a product-context design and source policy. It does not claim
that every taxonomy, connector, framework, or vendor listed below is implemented, certified, endorsed,
or used by every large enterprise.

Scout should maintain a small, versioned **Enterprise Context Registry**, not a giant prompt, copied
methodology library, or vendor-logo wall. The registry supplies neutral vocabulary and questions;
customer evidence determines which context applies. OpenAI may propose a mapping, but deterministic
Scout code must validate its shape and preserve its source, version, licence posture, and epistemic state.

## Registry contract

Every context record should have:

- a stable Scout ID, canonical name, aliases, record type, short Scout-authored definition, and
  applicability conditions;
- authoritative source URL, publisher, source version, publication/review dates, and last-checked date;
- licence class or terms URL, required attribution, permitted uses, and a `reference-only` flag;
- evidence links, provenance, epistemic state (`heard`, `inferred`, `proposed`, `validated`, or
  `contradicted`), confidence, owner, and review status;
- vendor/product version and lifecycle where relevant, without silently merging a capability with a
  particular supplier's implementation.

Definitions must be original Scout summaries. Do not copy framework diagrams, proprietary assessment
questions, certification marks, vendor screenshots, or long passages into source, prompts, context
packs, or the presentation.

## Customer-model taxonomy

| Layer | Capture as distinct records |
| --- | --- |
| Engagement and consent | Participants, roles, selected capture sources, consent, purpose, retention, residency, and sharing boundary |
| Outcomes and value | Business outcome, KPI formula, baseline, target, timebox, customer/job/segment, cost, risk, and benefit owner |
| Stakeholders and organisation | Teams, decision rights, accountability, incentives, operating model, and cognitive load |
| Capabilities and domains | Business capability, value stream, bounded context, domain terms, ownership, and dependencies |
| Process and service journey | Trigger, steps, handoffs, queues, exceptions, controls, SLA/SLO, and service/customer journey |
| Applications and platforms | Vendor, product, version, tenant, system role, owner, lifecycle, criticality, and system-of-record status |
| Integration | API, event, file, CDC, or manual handoff; direction, contract, auth, cadence, latency, retry, replay, idempotency, and failure owner |
| Data | Business terms/entities, producer, consumer, owner, classification, residency, retention, lineage, quality/SLO, and data-product status |
| Architecture | Current and proposed views kept separate across business, application, data, technology, and security; assumptions and decisions link to ADRs |
| Security, privacy, and compliance | Threat, control objective, implementation, evidence, jurisdiction, exception, review date, and accountable owner; never infer a legal obligation |
| AI system | Use case, model/provider/version, data and tool access, evaluation, human review, risk, incident, fallback, and monitoring |
| Delivery and operations | Acceptance/non-goals, dependencies, deployment and reliability measures, SLO/error budget, runbooks, incidents, support, and FinOps |
| Commercial and procurement | Contract, licence, renewal, DPA, vendor risk, residency commitment, exit plan, and purchasing constraint |
| Handoff and transformation | Gaps, contradictions, proposed questions/actions, estimate assumptions, readiness checks, approvals, and exact POC dependency closure |

## Representative platform catalogue

These are discovery aliases, not market-share claims or a completeness guarantee. “Popular with the
Fortune 500” must never be asserted without a dated, licensed dataset and a defined denominator.
Customer statements and system inventories remain authoritative.

| Capability family | Representative text labels |
| --- | --- |
| CRM and revenue | Salesforce, Microsoft Dynamics 365, SAP Customer Experience, Oracle Customer Experience |
| ERP, finance, and supply chain | SAP S/4HANA, Oracle Fusion Cloud ERP, Microsoft Dynamics 365, Oracle NetSuite |
| Human capital | Workday, SAP SuccessFactors, Oracle Fusion Cloud HCM |
| IT service/workflow | ServiceNow, BMC Helix, Jira Service Management |
| Collaboration and content | Microsoft 365, Teams, SharePoint, Google Workspace, Slack, Box |
| Cloud and runtime | AWS, Microsoft Azure, Google Cloud, Kubernetes, Red Hat OpenShift, VMware |
| Identity and security | Microsoft Entra ID, Okta, Ping Identity, CyberArk, CrowdStrike, Palo Alto Networks, Splunk |
| Integration, API, and event | MuleSoft, Boomi, Informatica, Apigee, Kong, Apache Kafka, Confluent |
| Data, analytics, and AI | Snowflake, Databricks, Microsoft Fabric, Power BI, BigQuery, Looker, Redshift, QuickSight, Tableau, dbt |
| Development and observability | GitHub, GitLab, Azure DevOps, Jira, Datadog, Dynatrace, New Relic, Splunk |
| Service and contact centre | Salesforce Service Cloud, Zendesk, ServiceNow CSM, Genesys Cloud, NICE CXone, Five9 |
| Commerce | SAP Commerce Cloud, Salesforce Commerce Cloud, Adobe Commerce, Shopify Plus |
| Industry core | Banking core, policy/claims administration, EHR, MES, PLM, billing, and other customer-evidenced systems |

Maintain product renames, acquisitions, aliases, supported versions, connector identifiers, and
official documentation URLs as dated records. Never use vendor existence to infer the customer's
architecture, data flow, control posture, or licence.

## Method and architecture mappings

Use these as conditional lenses, not universal laws:

- **Progressive data quality:** represent neutral `raw`, `validated`, and `curated` zones, then map
  vendor aliases such as bronze/silver/gold when the customer uses them. Databricks documents the
  [medallion architecture](https://docs.databricks.com/gcp/en/lakehouse/medallion), and Microsoft
  documents its application in [Fabric/OneLake](https://learn.microsoft.com/en-us/fabric/onelake/onelake-medallion-lakehouse-architecture).
- **Data mesh:** map domain ownership, data as a product, self-service platform, and federated
  computational governance from the original
  [data-mesh principles](https://martinfowler.com/articles/data-mesh-principles.html). Link to the
  source; do not copy its diagrams.
- **Domain modelling:** capture business capabilities, subdomains, bounded contexts, and ubiquitous
  language. Microsoft's current guidance covers
  [domain analysis](https://learn.microsoft.com/en-us/azure/architecture/microservices/model/domain-analysis)
  and [tactical DDD](https://learn.microsoft.com/en-us/azure/architecture/microservices/model/tactical-domain-driven-design).
- **Event-driven architecture:** model producers, consumers, channels, event contracts, ordering,
  delivery, replay, idempotency, and failure handling. Use it only where its trade-offs fit; see
  [Microsoft's architecture guidance](https://learn.microsoft.com/en-us/azure/architecture/guide/architecture-styles/event-driven).
- **Architecture views:** Scout can create its own C4-like context/container/component views. C4's
  website and example diagrams state [CC BY 4.0 terms](https://c4model.com/diagrams/system-landscape),
  so attribution is required for adapted material. TOGAF and ArchiMate are reference-only unless the
  required [Open Group commercial licence](https://www.opengroup.org/licensing-commercial-and-non-commercial)
  is obtained.
- **Delivery performance:** the current DORA guide defines five measures—change lead time,
  deployment frequency, failed-deployment recovery time, change fail rate, and deployment rework
  rate—and warns that context matters. Do not turn them into individual or cross-team scorecards; see
  [DORA metrics](https://dora.dev/guides/dora-metrics/).
- **Reliability:** capture SLIs, SLOs, error budgets, incident response, and toil where appropriate.
  Google's [SRE resources](https://sre.google/) and
  [error-budget chapter](https://sre.google/sre-book/embracing-risk/) are references, not bundled book text.
- **Cloud economics:** capture allocation, unit economics, budgets, forecasts, and optimisation using
  original Scout fields. The FinOps Framework permits reuse under
  [CC BY 4.0 with attribution](https://www.finops.org/introduction/how-to-use/).
- **Agile delivery:** preserve customer-specific ways of working rather than forcing a framework.
  The official [Scrum Guide](https://scrumguides.org/download.html) is CC BY-SA; SAFe content and marks
  remain subject to [Scaled Agile terms](https://scaledagile.com/terms-of-use/), and ITIL material and
  marks remain subject to [PeopleCert's marks policy](https://www.peoplecert.org/-/media/folders-reorganized/legal-documents/qmepo13-marks-usage-policy.pdf).
- **Team interaction:** Scout may use original records for team type, ownership, dependencies, and
  interaction modes. Do not copy Team Topologies diagrams or academy content; follow its
  [material-usage policy](https://teamtopologies.com/use-of-team-topologies-materials).
- **Business and service design:** Strategyzer permits specific uses of the Business Model Canvas but
  treats the Value Proposition Canvas differently; follow its
  [tool-usage terms](https://www.strategyzer.com/legal/usage-of-our-tools). Stanford's Design Thinking
  Bootleg is [CC BY-NC-SA](https://dschool.stanford.edu/tools/design-thinking-bootleg), so it must not
  be bundled or adapted into a commercial Scout release.

## Security, privacy, and AI governance

Use outcome mappings rather than claiming certification:

- NIST's [Cybersecurity Framework 2.0](https://www.nist.gov/cyberframework),
  [Privacy Framework](https://www.nist.gov/privacy-framework), and
  [Zero Trust Architecture](https://csrc.nist.gov/pubs/sp/800/207/final) provide current public-sector
  reference models.
- NIST's [AI Risk Management Framework](https://www.nist.gov/itl/ai-risk-management-framework) and
  [Generative AI Profile](https://nvlpubs.nist.gov/nistpubs/ai/NIST.AI.600-1.pdf) support AI risk,
  evaluation, human oversight, and lifecycle records. AI RMF is voluntary and under revision; pin the
  version used.
- Map application risks to the
  [OWASP Top 10 for LLM Applications 2025](https://owasp.org/www-project-top-10-for-large-language-model-applications/assets/PDF/OWASP-Top-10-for-LLMs-v2025.pdf)
  with attribution and ShareAlike review. MITRE ATT&CK permits commercial use only under its
  [terms and required notice](https://attack.mitre.org/resources/terms-of-use/).
- ISO/IEC 27001:2022 and ISO/IEC 42001:2023 are useful management-system references, but Scout must
  not reproduce paid standard text or imply conformity/certification. Use the official ISO pages for
  [27001](https://www.iso.org/standard/27001) and [42001](https://www.iso.org/standard/42001).

Regulatory applicability, certification, and control effectiveness always require a qualified human
owner and recorded evidence. A framework mapping is never proof of compliance.

## Asset and logo policy

Default decision: **bundle Scout-owned assets, link third-party knowledge, and let customers bring
their own authorised enterprise assets.**

1. **Bundle:** original Scout logos/icons with source artwork, ownership/provenance, checksums,
   dark/light/monochrome variants, alt text, and a release-approved licence; fictional screenshots
   generated from test fixtures with no customer data; required third-party notices and SBOM.
2. **Link:** authoritative standards, methods, vendor documentation, and vendor brand pages. Store a
   Scout-authored summary and source metadata, not the upstream diagram, PDF, logo, or screenshot.
3. **Bring your own:** customer logos, screenshots, architecture exports, templates, and proprietary
   frameworks only through an explicit upload/connector with customer attestation of authority,
   retention/redaction controls, provenance, and a context-pack exclusion default.
4. **Do not include by default:** third-party logo packs, certification badges, partner marks, vendor
   UI screenshots, customer audio, unrestricted transcripts, or original/normalised customer images.

Vendor names may be used accurately in plain text and less prominently than Scout. Logos require a
use-specific rights review and an asset record containing owner, official source URL, retrieval date,
file hash, licence/terms, permitted surface, attribution, modification restrictions, approval owner,
and expiry. Never imply partnership, endorsement, certification, or customer adoption.

Current primary brand rules reinforce the text-first policy:

- [Microsoft](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks) says many logos,
  product icons, and badges require authorisation.
- [AWS](https://aws.amazon.com/trademark-guidelines/) conditions use of AWS marks on its current
  trademark licence and prohibits implied sponsorship or endorsement.
- [Google](https://about.google/brand-resource-center/guidance/) permits accurate plain-text reference
  more broadly than logo use and prohibits implied affiliation.
- [Salesforce](https://www.salesforce.com/company/legal/intellectual-property/) permits accurate
  plain-text reference subject to its rules; most logo/copyright uses require specific permission.
- [Oracle](https://www.oracle.com/legal/trademarks-rw/) publishes separate third-party trademark and
  logo guidance.

NIST-produced publications are generally public-domain US government works, but credit remains good
practice and NIST marks cannot be used to imply endorsement; see
[NIST copyright and disclaimer guidance](https://www.nist.gov/copyrights-disclaimers). Creative
Commons material still requires record-level attribution and, for ShareAlike or NonCommercial
licences, legal review before a commercial release.

## Maintenance and release gate

- Review volatile platform names, framework versions, source availability, and brand terms at least
  quarterly and before every public release.
- Keep source retrieval and licence changes as append-only registry events; do not silently replace a
  definition or asset.
- Test registry records against the domain schema, broken links, duplicate aliases, required
  attribution, expired approvals, and context-pack redaction policy.
- Require legal/product approval before changing any record from `reference-only` to bundled.
- Keep the catalogue non-exhaustive in UI and generated output, and show the source/version/date for
  every mapping a user can act on.
