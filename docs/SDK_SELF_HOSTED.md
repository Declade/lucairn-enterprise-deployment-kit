# SDK Behavior Against Self-Hosted Instances

Enterprise customers should point SDKs at their own Lucairn gateway URL. The code path is the same as hosted Lucairn; only the base URL changes.

## Version Pinning

- Enterprise installs pin SDK minor versions.
- Patch updates are safe by default.
- Minor updates require changelog review.
- Major updates require a test environment rollout before production.

## TypeScript

```ts
import { LucairnClient } from "@lucairn/sdk";

const client = new LucairnClient({
  apiKey: process.env.LUCAIRN_API_KEY!,
  baseUrl: process.env.LUCAIRN_BASE_URL || "https://lucairn.customer.example",
});
```

## Python

```python
import os
from lucairn import LucairnClient

client = LucairnClient(
    api_key=os.environ["LUCAIRN_API_KEY"],
    base_url=os.environ.get("LUCAIRN_BASE_URL", "https://lucairn.customer.example"),
)
```

## Go

```go
client := lucairn.NewClient(lucairn.Config{
    APIKey:  os.Getenv("LUCAIRN_API_KEY"),
    BaseURL: getenvDefault("LUCAIRN_BASE_URL", "https://lucairn.customer.example"),
})
```

## Enterprise Changelog Policy

Every enterprise SDK release note must state:

- Minimum gateway version.
- Compatibility with self-hosted base URLs.
- Breaking config changes.
- Auth header changes.
- Streaming behavior changes.

