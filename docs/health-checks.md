# Health checks

Every backend exposes two probes. They are not the same and must not be conflated.

| Probe | Question it answers | Dependencies | Failure action |
|---|---|---|---|
| `/livez` | Is the process alive and not deadlocked? | **NONE** | Platform restarts the instance |
| `/readyz` | Can this instance serve traffic right now? | Critical deps | Platform removes from rotation |

## /livez — liveness, dependency-FREE

`/livez` answers one question: is this process wedged? It returns `200` whenever the
host is running and the request pipeline responds. It MUST NOT check the database,
Key Vault, downstream APIs, or any network dependency.

Rationale: liveness failure causes a **restart**. If `/livez` probed a flaky
downstream, a transient blip would restart every replica at once — a restart storm
that turns a recoverable outage into a self-inflicted one. A dependency check belongs
in `/readyz`, where the consequence is "stop sending traffic," not "kill the process."

## /readyz — readiness, gates traffic

`/readyz` answers: should the load balancer send this instance requests *now*? It
checks the critical dependencies the instance needs to do useful work (DB reachable,
Key Vault reachable, warm caches primed, migrations applied). On failure it returns a
non-`200` and the platform pulls the instance from rotation **without restarting it**,
so it can recover and rejoin.

Keep readiness checks cheap and bounded — short timeouts, no fan-out to every
transitive dependency, only what *this* instance must have to serve.

## How to add them

Do not hand-roll these. Use the **health-endpoints** skill, which wires
`/livez` (dependency-free) and `/readyz` (gated) idiomatically for the chosen backend
(Functions, ACA, MCP) using `Microsoft.Extensions.Diagnostics.HealthChecks`
with the correct tag filtering so the two probes map to the right check sets.

## Contract for operations

- The platform liveness probe targets `/livez`; the readiness/traffic probe targets `/readyz`.
- `/readyz` returning `200` is part of the agent "definition of done" for any deploy task.
- The availability test and alerting baseline run against `/readyz` — see
  [observability](observability.md) and [operations](operations.md).
