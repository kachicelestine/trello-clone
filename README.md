# Taskflow

A multi-tenant Kanban board. Organizations get workspaces, boards, lists, and cards with full drag-and-drop reordering. Free tier caps at five boards per org; a Stripe subscription removes the cap. Every mutation is recorded in an org-scoped audit log.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Browser                                                │
│  ├── Clerk.js (auth state, org switching)               │
│  ├── @hello-pangea/dnd (optimistic DnD)                 │
│  └── TanStack Query (server-state cache + invalidation) │
└────────────────────┬────────────────────────────────────┘
                     │  HTTP (RSC streaming + Server Actions)
┌────────────────────▼────────────────────────────────────┐
│  Next.js 14 — App Router                                │
│                                                         │
│  app/(marketing)/          Static landing — no auth     │
│  app/(platform)/dashboard/ Protected workspace shell    │
│  app/api/webhook/          Stripe event handler         │
│                                                         │
│  actions/                  Server Actions               │
│    └── validate (Zod) → mutate (Prisma) → revalidate   │
│                                                         │
│  middleware.ts             Clerk auth guard on /platform│
└──────────┬─────────────────────────┬───────────────────┘
           │                         │
    ┌──────▼──────┐           ┌──────▼──────┐
    │  MySQL 8    │           │  Stripe API  │
    │  (Prisma)   │           │  (webhooks)  │
    └─────────────┘           └─────────────┘
```

**No REST API.** Mutations go through Next.js Server Actions: the form calls an action, the action validates with Zod, writes via Prisma, then calls `revalidatePath`. The client never touches a route handler for data mutations — only Stripe webhooks use a route handler because Stripe requires a raw-body POST endpoint.

**Board limit enforcement** is a synchronous check inside the `create-board` Server Action, not middleware. It reads `OrgLimit.count` and compares against the constant in `config/`. Stripe subscription status is checked via `OrgSubscription.stripeCurrentPeriodEnd > now()`.

---

## System Design & Trade-offs

### Mutation architecture: Server Actions over REST

Every write goes through a Next.js Server Action — form → action → Zod → Prisma → `revalidatePath`. There is no API layer. This collocates validation and persistence logic with the feature that owns it, and gives end-to-end TypeScript safety with no generated client code. The cost is that nothing outside the Next.js process can call these mutations. No mobile app, no CLI, no third-party integration can write data without a dedicated route handler. If the product ever needs a public API or a native client, every Server Action becomes a migration target. Accept this trade-off consciously: it's the right call for a single-client web app, and the wrong default once you have more than one consumer.

### Multi-tenancy: Clerk owns identity and org membership

Org isolation is enforced by reading `auth().orgId` from Clerk on every Server Action and scoping every DB query to it. There is no tenant column on users, no org table in the local database — Clerk is the source of truth for who belongs to what org. This eliminates an entire class of auth bugs and removes all session management complexity. The cost is deep vendor lock-in: org membership data, user identities, and role assignments live in Clerk, not your database. You cannot query "all members of org X" from MySQL. If Clerk's availability SLA matters to you, it should be in your incident response runbook — when Clerk is down, the app is down.

### List and card ordering: integer ranks, bulk rewrite

`List.order` and `Card.order` are plain integers. Dragging an item updates the `order` of every affected sibling in a single Prisma transaction. This is simple to reason about and trivial to debug — inspect the integers and the order is obvious. The trade-off is O(N) writes on every reorder. Moving a card to the top of a list with 200 cards writes 200 rows. This is invisible at typical Kanban scale (10–30 cards per list) and becomes a latency problem above ~500. The correct fix at that scale is fractional indexing (maintain a float between the two neighbors; compact periodically), but that adds non-trivial complexity for a problem that hasn't materialized yet.

### Concurrent edits: last-write-wins, no conflict detection

There is no optimistic locking, no version field, no CRDT. Two users editing the same card title simultaneously will silently drop whichever write arrives first. This is an explicit product decision — Kanban boards have low per-entity write contention in practice (one person owns a card at a time), and the operational complexity of conflict detection is not justified. If the product evolves toward real-time collaborative editing (multiple cursors, live updates), this assumption breaks and the mutation model needs to be redesigned from the ground up.

### Board limit gate: read-check-then-write (not atomic)

`create-board` reads `OrgLimit.count`, compares against `MAX_FREE_BOARDS`, then inserts the board and increments the count as two separate operations. There is a race window: two simultaneous `create-board` calls from the same org can both read count=4, both pass the check, and both write — leaving the org with six boards instead of five. The correct fix is `SELECT ... FOR UPDATE` (pessimistic lock) or an atomic `UPDATE ... WHERE count < MAX` check. This is not fixed because the failure mode is tolerable — a free-tier user gets one extra board. It would not be tolerable if this gate guarded a financial transaction or a hard resource limit.

### Subscription state: local cache of Stripe truth

`OrgSubscription` is a local DB record written by the Stripe webhook handler. Subscription checks read from this table — no Stripe API call per request. The risk is drift: if a webhook is dropped (network partition, handler bug, Stripe delivery failure), the local record diverges from Stripe's truth. A user could retain access after cancellation, or lose access that they've paid for. Stripe retries failed webhook deliveries for 72 hours, which limits the drift window. For a harder guarantee, supplement with a periodic Stripe API reconciliation job or add a `?force_refresh=true` escape hatch that re-fetches from Stripe.

### Audit log: append-only, no retention, no index on `orgId`

`AuditLog` is append-only and grows forever. The current queries fetch all logs for an org with no pagination at the DB layer. There is no index on `orgId` in the schema — at scale this becomes a full table scan. Before this reaches production at meaningful volume, add `@@index([orgId])` to the schema, add cursor-based pagination to the audit log queries, and define a retention policy (archive or delete logs older than N days).

### Unsplash covers: third-party CDN dependency, no local storage

Board cover images are served directly from Unsplash's CDN. The DB stores the image URL, not the image. If Unsplash changes a URL format, rotates image IDs, or has a CDN outage, existing board covers break — with no recovery path short of re-fetching. The free-tier API limit is 50 requests per hour across all users. Under any meaningful concurrent load, board creation will start returning errors before rate limiting becomes visible. If this product scales, image metadata should be proxied through your own CDN with a local fallback.

### No real-time collaboration

There are no WebSockets, no Server-Sent Events, no Pusher, no PartyKit. Changes made by other users in the same org are not visible until the page refreshes. This is intentional: the infrastructure and operational complexity of a real-time layer (connection state, reconnection, presence, fan-out) is not justified at this stage. Trello itself launched without real-time and added it later. If real-time is added, the mutation model (Server Actions + `revalidatePath`) does not need to change — you add a pub/sub fan-out layer alongside it, not instead of it.

---

## Data Model

Six tables. The interesting constraints:

- `relationMode = "prisma"` — Prisma emulates FK constraints in application code rather than at the DB level. This is required for PlanetScale (which disables foreign keys) but works on any MySQL host. Swap to `"foreignKeys"` if you move to a standard host and want DB-enforced integrity.
- `List.order` and `Card.order` are plain integers. Reordering bulk-updates all affected rows in a single transaction via Server Action — no fractional-index scheme.
- `AuditLog` is append-only. Nothing deletes from it. Scoped to `orgId`.

```
Board ──< List ──< Card
                             AuditLog    (orgId-scoped, append-only)
                             OrgLimit    (one row per org, count of boards)
                             OrgSubscription (one row per org, Stripe data)
```

---

## External Dependencies

| Service | What breaks without it | Free tier |
|---------|------------------------|-----------|
| **Clerk** | Auth, org management — nothing works | Yes |
| **Unsplash** | Board cover images — boards can't be created | Yes (50 req/hr) |
| **Stripe** | Subscription upgrades only — free tier still works | Test mode |
| **MySQL** | Everything | n/a |

---

## Running Locally

### With Docker (recommended)

Requires Docker Desktop with Compose v2.

```sh
cp .env.example .env
# Fill in Clerk, Unsplash, and Stripe values

docker compose up --build
```

`docker compose up` starts MySQL, waits for it to be healthy, runs `prisma db push` to sync the schema, then starts the app on port 3000. Subsequent starts skip the build:

```sh
docker compose up          # start
docker compose down        # stop, keep data
docker compose down -v     # stop, delete database volume
```

### Without Docker

Requires Node 18 and a MySQL 8 instance.

```sh
npm install
npx prisma db push         # sync schema to your database
npm run dev                # http://localhost:3000
```

---

## Environment Variables

```sh
cp .env.example .env
```

| Variable | Where to get it |
|----------|----------------|
| `NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY` | Clerk dashboard → API Keys |
| `CLERK_SECRET_KEY` | Clerk dashboard → API Keys |
| `NEXT_PUBLIC_CLERK_SIGN_IN_URL` | `/sign-in` (Clerk handles the page) |
| `NEXT_PUBLIC_CLERK_SIGN_UP_URL` | `/sign-up` |
| `NEXT_PUBLIC_CLERK_AFTER_SIGN_IN_URL` | `/` |
| `NEXT_PUBLIC_CLERK_AFTER_SIGN_UP_URL` | `/` |
| `DATABASE_URL` | Your MySQL connection string |
| `NEXT_PUBLIC_UNSPLASH_ACCESS_KEY` | unsplash.com/developers → Your App |
| `STRIPE_API_KEY` | Stripe dashboard → Developers → API Keys |
| `STRIPE_WEBHOOK_SECRET` | Stripe dashboard → Webhooks → signing secret |
| `NEXT_PUBLIC_APP_URL` | `http://localhost:3000` locally; your public URL in production |
| `MYSQL_ROOT_PASSWORD` | Docker only — sets the compose `db` service root password |

**Build-time caveat:** Every `NEXT_PUBLIC_*` variable is inlined into the JavaScript bundle at `next build` time. Docker Compose passes them as `--build-arg` values automatically from your `.env`. If you build the image directly, pass them explicitly:

```sh
docker build \
  --build-arg NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=pk_live_... \
  --build-arg NEXT_PUBLIC_UNSPLASH_ACCESS_KEY=... \
  --build-arg NEXT_PUBLIC_APP_URL=https://your-domain.com \
  -t taskflow:latest .
```

---

## Stripe Webhooks

Stripe cannot reach `localhost`. During local development, use the Stripe CLI:

```sh
stripe listen --forward-to localhost:3000/api/webhook
```

The CLI prints a `whsec_...` signing secret — put that in `STRIPE_WEBHOOK_SECRET`. The webhook handler processes `invoice.payment_succeeded` and `customer.subscription.deleted` to write/clear `OrgSubscription`.

In production, create a webhook endpoint in the Stripe dashboard pointing to `https://your-domain.com/api/webhook` and add the same event types.

---

## Database

```sh
npx prisma db push        # apply schema changes without migrations (dev)
npx prisma studio         # browser GUI for your data
npx prisma generate       # regenerate the client after schema edits
```

For production on a standard MySQL host, replace `prisma db push` with proper migration files:

```sh
npx prisma migrate dev --name <description>   # create migration
npx prisma migrate deploy                      # apply in CI/CD
```

---

## Deployment

**Vercel + PlanetScale** — the path of least resistance. Import the repo into Vercel, set env vars in the dashboard, point `DATABASE_URL` at a PlanetScale branch. The `relationMode = "prisma"` setting is already correct for PlanetScale.

**Self-hosted Docker** — build the image, push to a registry, pull on your server, run `docker compose up -d` behind a reverse proxy (nginx, Caddy, or Traefik) on port 443. The `runner` stage is a non-root user on Alpine — no further hardening needed for a standard deployment.

```sh
# Build and push
docker build \
  --build-arg NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=... \
  --build-arg NEXT_PUBLIC_UNSPLASH_ACCESS_KEY=... \
  --build-arg NEXT_PUBLIC_APP_URL=https://your-domain.com \
  -t your-registry/taskflow:$(git rev-parse --short HEAD) .

docker push your-registry/taskflow:$(git rev-parse --short HEAD)
```

---

## Scripts

| Command | Description |
|---------|-------------|
| `npm run dev` | Dev server with hot reload |
| `npm run build` | Production build |
| `npm run start` | Serve the production build |
| `npm run lint` | ESLint |
