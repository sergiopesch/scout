# Optional enterprise classification vocabulary

This compact reference helps Codex normalise terminology already present in an approved Scout context
pack or explicitly supplied by the user. It is not customer evidence, a requirements checklist, a
market-share ranking, or proof that a practice applies.

## Hard boundary

- Start from the approved pack. Never add a platform, data flow, method, policy, control, KPI, or
  compliance obligation because it is listed here.
- Preserve the pack's epistemic state and stable claim/evidence IDs. A vocabulary mapping is metadata;
  it cannot promote `heard`, `inferred`, or `suggested` content to `confirmed`.
- Keep current state and proposed state separate. Mark any Codex-added mapping or estimate as an
  engineering assumption with an owner and validation need.
- Use product names as plain-text identifiers only. Do not add third-party logos, diagrams,
  screenshots, certification marks, or copied framework text to a build.

## Neutral classification layers

1. Engagement/consent: participant, role, capture source, consent, purpose, retention, residency.
2. Outcome/value: KPI definition, baseline, target, timebox, cost/risk, accountable owner.
3. Organisation/domain: team, decision right, capability, value stream, bounded context, domain term.
4. Process/service: trigger, step, handoff, queue, exception, control, SLA/SLO, journey.
5. Application/platform: vendor, product, version, tenant, role, owner, lifecycle, system of record.
6. Integration: API, event, file, CDC, or manual; contract, auth, cadence, latency, retry, replay,
   idempotency, and failure owner.
7. Data: entity/term, producer, consumer, owner, classification, residency, retention, lineage,
   quality/SLO, data product.
8. Architecture: separate current/proposed business, application, data, technology, and security
   views; link assumptions and decisions.
9. Security/privacy/AI: threat, control objective, evidence, jurisdiction, AI model/provider/version,
   data/tool access, eval, human review, incident, fallback.
10. Delivery/operations/commercial: acceptance/non-goals, dependency, DORA/SLO/error budget, runbook,
    support, FinOps, contract, licence, renewal, vendor risk, exit plan.
11. Handoff: gap, contradiction, proposed question/action, estimate assumption, readiness, approval,
    selected POC closure.

## Conditional method aliases

- Map bronze/silver/gold to neutral raw/validated/curated only when the pack uses a medallion-style
  design: [Databricks](https://docs.databricks.com/gcp/en/lakehouse/medallion),
  [Microsoft Fabric](https://learn.microsoft.com/en-us/fabric/onelake/onelake-medallion-lakehouse-architecture).
- Data mesh means domain ownership, data as a product, self-service platform, and federated
  computational governance—not a product purchase:
  [original principles](https://martinfowler.com/articles/data-mesh-principles.html).
- Domain-driven design and event-driven architecture are conditional modelling lenses, not defaults:
  [domain analysis](https://learn.microsoft.com/en-us/azure/architecture/microservices/model/domain-analysis),
  [event-driven architecture](https://learn.microsoft.com/en-us/azure/architecture/guide/architecture-styles/event-driven).
- DORA metrics are contextual delivery signals, not individual or cross-team rankings:
  [current guide](https://dora.dev/guides/dora-metrics/).
- NIST CSF, Privacy Framework, Zero Trust, and AI RMF are outcome/risk mappings; a mapping is never
  certification or proof of control effectiveness:
  [CSF](https://www.nist.gov/cyberframework),
  [Privacy Framework](https://www.nist.gov/privacy-framework),
  [Zero Trust](https://csrc.nist.gov/pubs/sp/800/207/final),
  [AI RMF](https://www.nist.gov/itl/ai-risk-management-framework).
- OWASP LLM Top 10 is a risk taxonomy, not a complete security test:
  [2025 edition](https://owasp.org/www-project-top-10-for-large-language-model-applications/assets/PDF/OWASP-Top-10-for-LLMs-v2025.pdf).

## Representative platform families

Use only to resolve an evidenced name or ask a clarifying question. The list is non-exhaustive and
does not mean “most used by the Fortune 500.”

- CRM/revenue: Salesforce, Microsoft Dynamics 365, SAP Customer Experience, Oracle Customer Experience.
- ERP/finance/supply chain: SAP S/4HANA, Oracle Fusion Cloud ERP, Microsoft Dynamics 365, NetSuite.
- HCM and workflow: Workday, SAP SuccessFactors, Oracle HCM, ServiceNow, BMC Helix, Jira Service Management.
- Collaboration/content: Microsoft 365, Teams, SharePoint, Google Workspace, Slack, Box.
- Cloud/runtime: AWS, Azure, Google Cloud, Kubernetes, Red Hat OpenShift, VMware.
- Identity/security: Microsoft Entra ID, Okta, Ping Identity, CyberArk, CrowdStrike, Palo Alto Networks, Splunk.
- Integration/event: MuleSoft, Boomi, Informatica, Apigee, Kong, Kafka, Confluent.
- Data/analytics/AI: Snowflake, Databricks, Microsoft Fabric, Power BI, BigQuery, Looker, Redshift,
  QuickSight, Tableau, dbt.
- Delivery/observability: GitHub, GitLab, Azure DevOps, Jira, Datadog, Dynatrace, New Relic, Splunk.
- Service/commerce: Salesforce Service Cloud, Zendesk, ServiceNow CSM, Genesys, NICE, Five9, SAP
  Commerce Cloud, Salesforce Commerce Cloud, Adobe Commerce, Shopify Plus.
- Industry core: use the customer's evidenced banking, insurance, health, manufacturing, telecom, or
  other core-system name and version; never substitute a generic vendor assumption.

This archive-local reference intentionally contains only the vocabulary needed during the Scout build
workflow. It does not package upstream methods or brand assets.
