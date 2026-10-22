# hunters-map backend infrastructure

Cloud Run API (Go, `backend/`) + Firestore + Firebase Authentication, in the GCP project
`ai-project-479422` (shared with spotify-mcp for the POC), region `europe-north1`.

```
iPhone app ──HTTPS + Firebase ID token──▶ Cloud Run: hunters-map-api ──▶ Firestore db "hunters-map"
    └──────────── reads live positions (firestore.rules) ────────────────────▲
```

| Resource | Managed by |
|---|---|
| APIs, Firebase project, Firebase iOS app, Firestore database + TTL + rules, Artifact Registry, service account + IAM, Cloud Run service | Terraform (`terraform/`) |
| Terraform state bucket | Terraform (`bootstrap/`, local state) |
| Backend releases (image build + rollout) | `deploy.sh` (Cloud Build + `gcloud run services update`) |
| Sign-in providers (Google, later Apple) | Firebase console, once (see step 5) |

Separation from spotify-mcp: own Firestore database (`hunters-map`), own service account
with Firestore access limited to that database, every resource named `hunters-map*`, and
APIs are never disabled on destroy.

## First-time setup

Run everything from this folder (`infra/`). Terraform 1.9.5 is pinned in
`.terraform-version` (tfenv picks it up).

**1. Credentials for Terraform** (opens a browser):

```bash
gcloud auth application-default login
```

```bash
gcloud auth application-default set-quota-project ai-project-479422
```

**2. State bucket** (once; review the plan, answer `yes`). This first enables the Cloud
Resource Manager and Service Usage APIs with `gcloud` (`make apis`): Terraform's Google
provider needs them to read any project resource, so it can't enable them itself.

```bash
make bootstrap
```

**3. Connect Terraform to the state bucket:**

```bash
make init
```

**4. Create the infrastructure** (review the plan before applying):

```bash
make plan
```

```bash
make apply
```

If Firebase creation fails asking you to accept terms, open
<https://console.firebase.google.com> once with your account, accept, and re-run plan/apply.

**5. Enable Google sign-in** (Firebase console; OAuth consent screens and clients for
public apps can't be created with Terraform):

1. <https://console.firebase.google.com/project/ai-project-479422/authentication>
2. *Get started* → *Sign-in method* → *Google* → *Enable*, pick your support email → *Save*.

Note: this turns on Firebase Authentication for the whole project (spotify-mcp is not
affected; it doesn't use it).

**6. Deploy the backend:**

```bash
make deploy
```

```bash
make smoke
```

`smoke` should print `{"status":"ok"}` and `401` for an unauthenticated call.

**7. iOS config** (after step 5, so it includes the Google OAuth client):

```bash
make ios-config
```

## Day-to-day

- Code change → `make deploy` (image tag = git commit; `-dirty-…` for uncommitted changes).
- Infra change → edit `terraform/`, then `make plan` and `make apply`.
- Rules change → edit `firestore.rules`, then `make plan` and `make apply`.

Terraform ignores the running image (`lifecycle.ignore_changes`), so `make apply` never
rolls back a deploy.

## Local development

```bash
cd ../backend && go test ./...
```

```bash
cd ../backend && DEV_MODE=1 go run ./cmd/api
```

`DEV_MODE=1` uses an in-memory store and accepts `Authorization: Bearer dev:<uid>:<name>`
tokens, e.g.:

```bash
curl -X POST localhost:8080/v1/groups -H 'Authorization: Bearer dev:alice:Alice' -d '{"name":"Testiseurue"}'
```

The server refuses `DEV_MODE` on Cloud Run.

### Simulated hunter

To see other hunters on the map without a second phone, `simhunter` joins a group as a fake
member and walks it around, writing to the real Firestore database with your Application
Default Credentials. Ctrl-C stops it and removes the member.

```bash
cd ../backend && go run ./cmd/simhunter -group <groupId> -speed 5
```

The group id is the document id under `groups/` in Firestore (or `id` from `GET /v1/groups`).
Options: `-name`, `-lat`/`-lon` (centre of the walk), `-radius`, `-speed` (m/s), `-interval`.

## Costs (POC)

Cloud Run scales to zero (max 3 instances), Firestore and Firebase Authentication stay
within or near their free tiers for one hunting party: expect cents to a few euros a month.
Set a budget alert on the project's billing account.

## Tearing down

```bash
terraform -chdir=terraform destroy
```

Removes the service, repository, service account and rules. The Firestore database is
kept (delete protection + `deletion_policy = "ABANDON"`), and Firebase stays enabled on
the project.
