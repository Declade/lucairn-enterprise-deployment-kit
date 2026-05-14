# Starter Templates

These are example configurations for common industry verticals. They are **not product config** — they are reference material for customers requesting sanitizer customization.

The product uses a single default config (`config/default-sanitizer.yaml`) that works for any industry. Customers customize their config via:
- **Pro tier:** Request changes — DSA applies them (1 included/month)
- **Enterprise tier:** Edit config directly (self-service)

## Available Templates

| Template | Description | Key safe patterns | Custom recognizers |
|----------|-------------|-------------------|--------------------|
| `itsm/` | IT Service Management (ServiceNow) | `INC\d+`, `CHG\d+`, `REQ\d+` | — |
| `finance/` | Financial services (AML, fraud) | — | Sozialversicherungsnummer, Steuer-ID |
| `healthcare/` | Healthcare (clinical data) | `ICD-[A-Z]\d+`, `ATC-[A-Z]\d+` | Medical record number, Fallnummer |
| `government/` | Government services | — | Personalausweisnummer, Sozialversicherungsnummer, Steuer-ID |

## How to use

1. Browse the template closest to your industry
2. Identify safe patterns and recognizers relevant to your data
3. Request config changes via your tier's process (Pro: DSA applies; Enterprise: self-service)

These templates also include example prompt files for common use cases. You can reference these when writing your own `prompt_template` for the `/api/v1/proxy/messages` endpoint.

## Customer-scoped person name supplement

The global `german-names.txt` deny-list deliberately **excludes** surnames that collide with common German words (`Vogel`="bird", `Frank`, `Sommer`, `Winter`, `Wolf`, etc.) to avoid false positives for customers whose data contains those words in non-personal contexts.

If you are an operator whose real data uses some of those names as actual person names (e.g. a clinic with a patient named `Anna Vogel`), add them under `sanitizer.known_entity_matching.extra_person_names`:

```yaml
sanitizer:
  known_entity_matching:
    enabled: true
    extra_person_names:
      - Miriam
      - Vogel
```

Guarantees:

- **Empty by default.** No existing customer sees a behavior change.
- **Customer-scoped.** Your supplement is not added to `german-names.txt` and does not affect other customers.
- **Word-boundary matched.** Compound words (`Vogelgrippe`, `Frankreich`, `Wolfsburg`) are **not** matched — only the standalone name.
- **German-language recognizer.** Registered under `supported_language: de`.

This is a pure Presidio deny-list recognizer, so behavior is deterministic and auditable. Add names whose correct classification is `PERSON` even when spaCy NER misses them.
