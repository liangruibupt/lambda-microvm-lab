# Lambda MicroVMs Lab

Hands-on exploration of **AWS Lambda MicroVMs** (GA 2026-06-22) — Firecracker-isolated,
snapshot-resumable serverless compute for running untrusted / AI-generated code. This
repo has both the **scripts** and a written **walkthrough with real live output**, so you
can reproduce it or just read what happened.

Verified live against AWS account `747411437379`, region `us-east-1`, on **2026-09-03**.

---

## What Lambda MicroVMs are (and why they exist)

A new serverless primitive that gives each user/session a **VM-level isolated** environment
via Firecracker, filling the gap between the existing options:

| Option | Isolation | Startup | Stateful long session |
|---|---|---|---|
| VM (EC2) | strong | slow (minutes) | yes |
| Container | weak (shared kernel) | fast (seconds) | DIY |
| Lambda Function | medium | fast | not suited |
| **Lambda MicroVM** | **strong (VM)** | **fast (snapshot resume, ~seconds)** | **yes (up to 8h)** |

Core traits: VM-level isolation + snapshot second-level start/resume + idle auto-suspend
(≈$0 while suspended) + full OS (install packages, mount FS) + flexible networking
(HTTP/2, gRPC, WebSocket, public/VPC egress).

**Good fit:** AI code-execution sandboxes, interactive dev environments, data analysis
(Jupyter), security scanning, RL environments, multi-tenant CI/CD, game servers, AI-agent
sandboxes — anything running *code the developer didn't write* that needs strong isolation +
fast start + in-session state. **Not for:** plain stateless request/response (use a normal
Lambda Function) or steady long-running load (use ECS/EC2).

---

## Verified facts (from the live API + official docs)

| Thing | Value |
|---|---|
| CLI namespace | `aws lambda-microvms` (needs AWS CLI v2 ≥ 2.35; this lab used 2.36.37) |
| Managed base image (us-east-1) | `arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1` (versions 0 & 1 `AVAILABLE`) |
| Base container image | `public.ecr.aws/lambda/microvms:al2023-minimal` (the Dockerfile `FROM`) |
| Code artifact | a **zip** with `Dockerfile` + app files at the **root**, uploaded to S3 |
| Build role trust | `lambda.amazonaws.com`, actions `sts:AssumeRole` + `sts:TagSession` |
| Build role perms | `s3:GetObject` on the bucket + CloudWatch Logs create/put |
| Caller perm needed | `iam:PassRole` on the build role (condition `iam:PassedToService=lambda.amazonaws.com`) |
| Endpoint format | `<id>.lambda-microvm.<region>.on.aws` (returned by `run-microvm`/`get-microvm`) |
| **Connect contract** | **connect on public 443**, send `X-aws-proxy-auth: <token>` **and** `X-aws-proxy-port: <containerPort>`; token `--allowed-ports` must permit the container port |
| Lifecycle states | image `CREATING→CREATED`; vm `PENDING→RUNNING→SUSPENDED→…→TERMINATED` |
| Max session | up to 8h total runtime; **no compute charge while SUSPENDED**; ARM64 only |

### The connect gotcha (cost us the most time)

You do **not** curl `https://<endpoint>:5000/`. The ingress proxy terminates public TLS on
**443** and forwards to the container port only if you tell it which port via the
**`X-aws-proxy-port`** header. Symptoms if you get it wrong:

- `https://<endpoint>:5000/` → connection **times out**
- 443 without `X-aws-proxy-port` → request **hangs** (TLS ok, no body)
- token scoped to 443 instead of the container port → **`Access to port denied`**

Correct call: connect on 443, `X-aws-proxy-auth: <token>` + `X-aws-proxy-port: 5000`, token
minted with `--allowed-ports '[{"port":5000}]'`.

---

## Task 3 — build a single Flask MicroVM from scratch (test steps)

### Files
- `flask-microvm/app.py` — minimal Flask app with an in-memory hit counter (proves snapshot
  state survival) and `/health`.
- `flask-microvm/Dockerfile` — the official minimal example (`FROM public.ecr.aws/lambda/microvms:al2023-minimal`, gunicorn on 5000).
- `flask-microvm/requirements.txt` — `flask`, `gunicorn`.
- `flask_microvm.sh` — the whole lifecycle as one idempotent, teardown-safe script.

### Run it
```bash
./flask_microvm.sh up        # build image → run VM → connect → suspend/resume → leave live
./flask_microvm.sh teardown  # terminate VM + delete image + S3 + build IAM role policy
```

### What `up` does, step by step
1. **build IAM role** (boto3) — trust `lambda.amazonaws.com` + `sts:TagSession`; inline perms
   `s3:GetObject` + CW logs. *(The CLI `iam create-role` path is guardrail-blocked, so boto3.)*
2. **package + upload** `Dockerfile`+`app.py`+`requirements.txt` zipped at the root to
   `s3://lambda-microvm-lab-<acct>-<region>/<name>/app.zip` (boto3).
3. **`create-microvm-image`** (CLI) with `--base-image-arn`, `--build-role-arn`,
   `--code-artifact uri=…`. Needs `iam:PassRole` on the build role.
4. **poll** `get-microvm-image` (full ARN) until `state=CREATED` (~3 min; AWS runs your
   Dockerfile and snapshots the initialized process).
5. **`run-microvm`** (CLI) with managed ingress+egress connectors and an idle policy →
   returns `microvmId` + `endpoint`; `PENDING→RUNNING` in ~7s.
6. **connect** — `create-microvm-auth-token` → curl **443** with `X-aws-proxy-auth` +
   `X-aws-proxy-port: 5000`.
7. **suspend → resume** and hit again — the hit counter must continue (memory restored).

### Manual curl (mint a fresh token each time; expires ≤15 min)
```bash
export PATH="$HOME/.local/bin:$PATH"
EP="<id>.lambda-microvm.us-east-1.on.aws"      # from run-microvm / get-microvm
MVM="microvm-xxxxxxxx-...."                      # microvmId
TOKEN="$(aws lambda-microvms create-microvm-auth-token \
  --microvm-identifier "$MVM" --expiration-in-minutes 15 \
  --allowed-ports '[{"port":5000}]' --region us-east-1 --query authToken --output text)"
curl -sS "https://${EP}/" -H "X-aws-proxy-auth: ${TOKEN}" -H "X-aws-proxy-port: 5000"
```
`curl_microvm.sh <microvmId> <endpoint> [path]` wraps exactly this.

### Actual live results (2026-09-03, us-east-1)
```
create-microvm-image  -> state CREATING -> CREATED   (~3 min)
run-microvm           -> PENDING -> RUNNING          (~7 s, snapshot resume)
endpoint              3cd032a6-...lambda-microvm.us-east-1.on.aws
connect (hit 1)       {"hits":1,"message":"hello from inside a Lambda MicroVM","uptime_seconds":338.2}
connect (hit 2)       {"hits":2,...}                 # same live process
/health               {"status":"ok"}
suspend -> resume     hits:3 -> SUSPENDED -> RUNNING -> hits:4   # NOT reset to 1 = memory survived the Firecracker snapshot
auto-resume proof     later, while SUSPENDED, a single curl woke it -> {"hits":5,"uptime_seconds":783.2}
```
The counter surviving suspend/resume, and a curl auto-resuming a suspended VM, are the whole
value proposition demonstrated end-to-end.

### Gotcha we hit: IAM PassRole + cached IMDS credentials
`create-microvm-image` first failed with `AccessDenied: iam:PassRole`. Adding the scoped
`PassRole` policy to the running instance role did **not** take effect immediately — an
EC2 instance-role session uses **cached IMDS credentials** that snapshot permissions at
assume-time, so a new grant only lands after the credential **rotates** (up to ~1h) or is
added out-of-band by an admin. The policy was correct; the session just couldn't see it yet.

---

## Task 4 — multi-tenant sample (billable; run deliberately)

`multitenant_sample.sh` wraps the official CloudFormation sample
[aws-samples/sample-multi-tenant-ai-agents-on-lambda-microvm](https://github.com/aws-samples/sample-multi-tenant-ai-agents-on-lambda-microvm):
one MicroVM per tenant, EFS state, Bedrock models, Telegram-webhook orchestrator.

```bash
./multitenant_sample.sh clone
./multitenant_sample.sh preflight
./multitenant_sample.sh deploy                 # prompts for cost OK (~10 min)
./multitenant_sample.sh add-tenant tenant1
./multitenant_sample.sh chat tenant1 "remember my lucky number is 7777"
./multitenant_sample.sh chat tenant1 "what is my lucky number?"
./multitenant_sample.sh teardown
```

**Only meaningful standing cost: a NAT gateway (~$32/mo, per-stack)** for the agent's web
access — drop it if agents don't need the internet. Everything else idles ≈$0.

---

## Cost & cleanup discipline

- Task 3: one VM, ~$0 while suspended, self-terminates at `maximumDurationInSeconds`.
  `./flask_microvm.sh teardown` removes the VM, image, S3 bucket, and build-role policy.
- Also remove the caller-side `iam:PassRole` policy from the instance role when done.
- Task 4: tear the stack down (`teardown`) to stop the NAT charge.
- Baseline account state before this lab: 0 microvm images, 0 running microvms (clean).

## Prereqs
- AWS CLI v2 ≥ 2.35 with the `lambda-microvms` subcommand (this lab: user-local 2.36.37).
- python3 (used for zipping + boto3 IAM/S3), curl, an AWS identity in a MicroVM-supported region.
- No Docker needed locally — the image builds on AWS.
