# Task 4 — Multi-tenant MicroVM verification results

Live testing of the deployed `openclaw-mt` stack (account `747411437379`, `us-east-1`,
2026-09-03), against the dimensions in the sample README plus lifecycle / isolation /
resilience / observability. Honest results — including what did **not** behave as the
headline claim would suggest.

Stack config observed (orchestrator Lambda env + EventBridge):
`IDLE_REAP_SECONDS=3600` (1h idle before reap), sweeper `rate(10 minutes)`,
`BEDROCK_MODEL_ID=us.anthropic.claude-haiku-4-5`, exec role
`openclaw-mt-MicroVMExecutionRole`, dedicated egress connector `nc-8e56320d…`.

---

## A. Core functional tests

### A1. State persistence (within a VM generation) — ✅ PASS
tenant1: turn 1 "remember my lucky number is 7777" → turn 2 "what is my lucky number?" →
**"Your lucky number is 7777."** State held across turns on the same VM (EFS-backed dir).

### A2. Multi-tenant isolation — ✅ PASS (headline claim confirmed)
- tenant1 and tenant2 each get their **own Firecracker MicroVM**: `microvm-8be10b44…` vs
  `microvm-9afade3d…` (different VM ids, hard VM-level isolation).
- Cross-query: tenant2 asked about "mango" (tenant1's value) →
  **"I don't have that in memory. No one has told me their favorite fruit was mango."**
- Own-query still works: tenant2 → **"Your favorite fruit is durian."**
- Zero cross-tenant visibility. Each tenant's EFS subtree is `/mnt/efs/tenants/$TENANT`,
  bind-mounted over the agent state dir — so isolation is enforced at both the VM and the
  EFS-namespace layer.
- Note: the word **"secret"** triggers the agent's own safety refusal ("I won't store
  secrets in memory files"), so use neutral phrasing (e.g. "favorite fruit") when testing
  storage/recall — otherwise a recall miss is the agent being cautious, not an isolation or
  persistence failure.

---

## B. MicroVM lifecycle tests

### B1. Cold start vs warm turn latency — ✅ measured
- **Cold start:** first turn for a COLD tenant provisions + boots the VM; the synchronous
  `chat.sh` returns `cold: None | reply: None` because the ~90-156s cold start exceeds the
  CLI wait window (tenant1 ~90s+, tenant2 156s). **This is cold-start-in-progress, not a
  failure** — DynamoDB shows the tenant flip to `state=RUNNING` seconds later.
- **Warm turn:** 3-6s end-to-end (`cold: False`). Large, clear delta — the snapshot-resume
  value proposition.

### B2. Idle auto-reap + cross-generation state survival — ❌ FAIL (confirmed sample bug)
Real idle-reap needs `IDLE_REAP_SECONDS=3600` (1h) of inactivity, so we **forced** a
generation turnover: confirm a durable write, then `terminate-microvm` (simulating the reap),
then message again to force a fresh-generation cold start.

**Careful retest (tenant3, 2026-09-03):**
1. Stored "project codename FALCON"; the agent confirmed it wrote
   `/home/node/.openclaw/workspace/MEMORY.md` (which is `STATE_DIR` = the EFS-bind-mount root).
2. Confirmed EFS actually mounted on gen-1:
   `[efs-monitor] EFS mounted … ; tenant tenant3 first generation: seeding from local state`.
3. Same-generation recall worked: **"Your project codename is FALCON."**
4. Terminated the gen-1 VM → messaged again → gen-2 VM cold-started
   (`generation 1→2`, new id `microvm-02863892…`).
5. Gen-2 recall: **"I don't have your project codename stored… no record of it."** — FALCON lost.

**Confirmed root cause (a real bug in the sample, reproduced twice — durian, then FALCON):**
Gen-2's log said `tenant tenant3 first generation: seeding from local state` — but this is the
*second* generation. `efs-monitor.sh` decides adopt-vs-seed by testing
`[ ! -f "$EFS_DIR/tenants/$TENANT/openclaw.json" ]`:
```sh
if [ ! -f "$TDIR/openclaw.json" ]; then
    echo "… first generation: seeding from local state"
    cp -a "$STATE_DIR/." "$TDIR/"          # overwrites EFS with the image's empty local state
else
    echo "… has prior state - adopting it"  # never reached on gen-2 in our runs
fi
```
On gen-2 the marker file was **not present**, so the sample took the *seed* branch and
overwrote the tenant's EFS state with the image's fresh local state — discarding the
persisted `MEMORY.md`. The "adopt prior state" path never triggered. Net effect: **every
generation re-seeds, so agent memory does NOT survive a full VM death + regeneration**, even
though the write genuinely reached the EFS mount within the generation.

**Distinction that matters:**
- State survives across **turns within one generation** — ✅ (A1, and step 3 above).
- State survives a **VM suspend/resume** — ✅ (B3 / Task 3, snapshot restores memory).
- State survives a full **VM termination + regeneration** — ❌ broken by the adopt-vs-seed
  marker bug above. This is the sample's headline "state parks on EFS, survives across VM
  generations" claim, and it does **not** hold as shipped.

**Suggested fix (for a sample PR):** make the adopt-vs-seed decision key on a dedicated
state marker the seed writes durably *after* `cp -a` completes (e.g. a `.tenant-initialized`
sentinel), rather than on `openclaw.json` — which the code overwrites unconditionally right
after the check, muddying the signal.

### B3. Suspend / resume — ✅ PASS (Task 3, same primitive)
Verified in Task 3 on the single Flask MicroVM: `suspend-microvm` → `resume-microvm`
restored the in-VM process memory (hit counter continued 3→4, not reset), faster than a cold
boot. Same Firecracker snapshot primitive the multi-tenant stack uses.

### B4. 8-hour max lifetime — ⏭️ not tested (by design)
Boundary test, too time-consuming to run live; understood from docs (VM auto-terminates at
`maximumDurationInSeconds`, ≤8h).

---

## C. Resilience (unplanned finding)

### C1. In-agent failure is tenant-isolated — ✅ POSITIVE signal
After a burst of rapid-fire turns, **tenant1's in-VM agent wedged**: the orchestrator
reached the VM fine but `/chat` returned **HTTP 500** (seen in
`/aws/lambda/openclaw-mt-orchestrator` logs), so subsequent tenant1 turns returned
`cold: None | reply: None` at 1-3s (too fast to be a cold start). **tenant2 was completely
unaffected** and kept answering. This is an in-VM *agent* crash, not an infra/isolation
problem — and one tenant's agent crashing not touching another is itself the isolation
guarantee working. Mitigation would be VM recycle (terminate → next turn cold-starts a fresh
gen) or an in-agent supervisor restart.

---

## D. Observability & cost

### D1. Observability — ✅ available
- Orchestrator (router/worker/sweeper): CloudWatch log group `/aws/lambda/openclaw-mt-orchestrator`
  (surfaced the HTTP 500 root cause).
- MicroVM **build** logs: `/aws/lambda-microvms/openclaw-mt-openclaw`.
- Tenant→VM mapping + lifecycle: DynamoDB `openclaw-mt-tenants`
  (`state`, `microvmId`, `generation`, `lastActiveAt`, `launchedAt`, `endpoint`, `authToken`).
- Live VMs: `aws lambda-microvms list-microvms`.
- Sweeper cadence: EventBridge rule `openclaw-mt-sweeper` = `rate(10 minutes)`.

### D2. Idle cost — ✅ reasoned/confirmed
Idle VMs auto-suspend (≈$0 compute) and are reaped after 1h idle; state parks on EFS. The one
always-on cost is the stack's **NAT gateway (~$32/mo, per-stack)** for agent web egress —
drop it if agents don't need the internet.

---

## E. Better reasoned than tested (deliberately not run live)

These are either design properties verifiable by reading the sample, or too
expensive/complex to force for marginal added signal:

- **Credential isolation (zero static creds)** — *design property.* The MicroVM assumes
  `openclaw-mt-MicroVMExecutionRole` via IMDSv2; no static keys in the image or env
  (confirmed: orchestrator env carries only ARNs/IDs + the gateway token, no AWS secrets).
  Verifiable by inspecting the template/Dockerfile, not worth a live exploit attempt.
- **Network egress path** — *design property.* Bedrock + EFS reach via private VPC
  endpoint / mount target; public traffic (`web_search`/`web_fetch`) via the NAT gateway.
  One egress connector per VM (`nc-8e56320d…`), bound at run time, immutable through
  suspend/resume.
- **Tenant cross-EFS-path exploit** — the A2 agent-level isolation test already proved the
  boundary; a raw EFS-path exploit needs an in-VM shell (`create-microvm-shell-auth-token`),
  deep and risky for marginal added signal over A2.
- **Long turn > 15-min self-invoke chain** — needs a genuinely 15-min+ agent turn to
  trigger the chained async self-invoke; expensive to force. Mechanism understood from the
  README (worker hands polling to a fresh async self-invoke so a turn is bounded only by the
  VM's 8h lifetime, not Lambda's 15-min max).
- **`/model` switch + failed-model self-heal** — Telegram-path features; the HTTP `chat.sh`
  test path doesn't expose `/model`. Model catalog is discovered from Bedrock at cold start
  (so a pinned-but-retired model self-heals on the next cold start).
- **8h max lifetime** (see B4).

---

## Summary

Confirmed live: **multi-tenant isolation** (the headline claim), **within-generation state
persistence**, **cold-vs-warm latency delta**, **suspend/resume** (Task 3), and
**tenant-isolated agent failure**. **Cross-generation state survival is BROKEN as shipped** —
a careful retest (tenant3/FALCON) pinned the root cause to an adopt-vs-seed marker bug in
`efs-monitor.sh` that re-seeds every generation from empty local state, discarding the
EFS-persisted agent memory (reproduced twice; fix suggested in B2). Security/egress/credential
properties are design-verified rather than live-exploited. NAT (~$32/mo) is the only standing
cost.
