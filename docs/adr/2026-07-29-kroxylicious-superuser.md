# ADR: Kroxylicious retains broker super_user privilege

**Date:** 2026-07-29
**Status:** Accepted
**Supersedes deferred PR17 (principal projection)**

## Context

Kroxylicious authenticates to the brokers as `User:kroxylicious`, which is listed in every broker's `super.users`:

```
super.users=User:admin;User:host-admin;User:broker1;User:broker2;User:broker3;User:controller1;User:controller2;User:controller3;User:kroxylicious
```

This is broader than desired: any client reaching a broker through the proxy runs with full superuser rights.

The original goal (PR17) was to project each downstream client's mTLS CN as the upstream principal so ACLs enforce per-client identity.

## Decision

**Keep `User:kroxylicious` in `super.users`. Do not implement principal projection at this time.**

## Rationale

Verified against kroxylicious `0.23.0` (current pin in `clusters/.env`):

- No built-in principal-projection filter exists (checked CHANGELOG 0.11 → 0.23).
- `SaslInspectionFilter` (0.17.0) reads client SASL credentials for observability but does not rewrite them upstream.
- Alternatives require significant effort:
  - **Custom Maven `RequestFilter`** to rewrite SASL PLAIN — new build artifact, upgrade tax on every kroxylicious bump.
  - **Broker delegation tokens** — token-lifecycle service and broker admin-API access from the proxy.

The current deployment is a homelab / dev cluster. The risk of a compromised proxy having superuser rights is accepted; the payoff of a bespoke filter does not justify the maintenance cost.

## Consequences

- Any client passing through kroxylicious effectively bypasses ACLs.
- Non-proxy clients (broker↔broker, controller↔broker, direct admin) still authenticate as their own identities and are subject to normal ACL rules.
- Revisit if:
  - kroxylicious ships a first-class principal-projection filter, OR
  - the cluster is promoted beyond dev/homelab use.

## References

- `services/kroxylicious/config/proxy.yaml`
- Kroxylicious CHANGELOG: https://github.com/kroxylicious/kroxylicious/blob/main/CHANGELOG.md
