# Taskflow — Full-Stack Trello Clone

![App screenshot](https://github.com/AntonioErdeljac/next13-trello/assets/23248726/fd260249-82fa-4588-a67a-69bb4eb09067)

A production-grade Kanban board built on the Next.js 14 App Router. Multi-tenant workspaces, real-time drag-and-drop, per-org Stripe subscriptions, and a full audit trail. Ships with Docker for zero-friction local and cloud deployment.

---

## Tech Stack

| Layer | Technology | Why |
|-------|-----------|-----|
| Framework | Next.js 14 — App Router + Server Actions | Collocates data mutations with UI; eliminates a separate API layer |
| Auth | Clerk | Org-aware auth with zero session management overhead |
| Database | MySQL 8 + Prisma ORM | Strong relational guarantees; Prisma Client gives end-to-end type safety |
| Payments | Stripe — subscriptions + webhooks | Metered per-org billing with idempotent webhook handling |
| Media | Unsplash API | Royalty-free board covers without an asset pipeline |
| Client state | Zustand + TanStack Query | Zustand for ephemeral UI state; TQ for server-state caching and optimistic updates |
| UI | shadcn/ui + Tailwind CSS | Unstyled primitives — zero CSS specificity fights |
| Drag and drop | @hello-pangea/dnd | Maintained DnD Kit fork with accessible keyboard support |
| Runtime | Node 18 LTS | Required by Next.js 14 |

---

## Architecture

```
Browser
  │
  ▼
Next.js 14 (App Router)
  ├── (marketing)/          Landing page — static, no auth
  ├── (platform)/
  │   └── (dashboard)/      Authenticated workspace shell
  │       ├── /board/[id]   Board view with lists + cards
  │       └── /settings     Org subscription management
  └── /api/
      └── /webhook          Stripe webhook handler
           │
  Server Actions ──────────── Zod validation → Prisma → MySQL
           │
  Clerk Middleware           Protects all /platform routes
```

Data flow for mutations: **React form → Server Action → Zod parse → Prisma → revalidatePath**. No REST layer. The audit log (`AuditLog` table) records every CREATE / UPDATE / DELETE across Boards, Lists, and Cards, keyed by Clerk `orgId` + `userId`.

The free tier caps boards at 5 per org (`OrgLimit` table). Upgrading via Stripe sets an `OrgSubscription` record; the cap check reads that record on every board-creation action.

---

## Prerequisites

- **Docker + Docker Compose v2** — recommended; see [Quick Start](#quick-start-docker)
- **Node 18.x** — for local development without Docker

### External services you must provision

| Service | What you need | Link |
|---------|---------------|------|
| Clerk | Application with "Organizations" enabled | https://dashboard.clerk.com |
| Unsplash | API application (free tier is enough) | https://unsplash.com/developers |
| Stripe | Account + a product/price for the subscription | https://dashboard.stripe.com |

---

## Environment Variables

Copy `.env.example` to `.env` and fill in every value.

```sh
cp .env.example .env
```

| Variable | Required | Description |
|----------|----------|-------------|
| `NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY` | Yes | Clerk publishable key — exposed in browser bundle |
| `CLERK_SECRET_KEY` | Yes | Clerk secret key — server-side only |
| `NEXT_PUBLIC_CLERK_SIGN_IN_URL` | Yes | Defaults to `/sign-in` |
| `NEXT_PUBLIC_CLERK_SIGN_UP_URL` | Yes | Defaults to `/sign-up` |
| `NEXT_PUBLIC_CLERK_AFTER_SIGN_IN_URL` | Yes | Redirect after login |
| `NEXT_PUBLIC_CLERK_AFTER_SIGN_UP_URL` | Yes | Redirect after signup |
| `DATABASE_URL` | Yes | MySQL connection string |
| `NEXT_PUBLIC_UNSPLASH_ACCESS_KEY` | Yes | Unsplash API access key |
| `STRIPE_API_KEY` | Yes | Stripe secret key (`sk_test_…` or `sk_live_…`) |
| `STRIPE_WEBHOOK_SECRET` | Yes | Stripe webhook signing secret (`whsec_…`) |
| `NEXT_PUBLIC_APP_URL` | Yes | Public base URL — used by Stripe + Clerk (`http://localhost:3000` locally) |
| `MYSQL_ROOT_PASSWORD` | Docker only | MySQL root password for the compose `db` service |

> **Important — build-time inlining:** All `NEXT_PUBLIC_*` variables are compiled into the JavaScript bundle at build time by Next.js. When building with Docker you must pass them as `--build-arg` values (docker-compose handles this automatically from your `.env` file).

---

## Quick Start — Docker

The compose stack spins up MySQL, runs schema migrations, then starts the app.

```sh
# 1. Configure environment
cp .env.example .env
#    Fill in Clerk, Unsplash, and Stripe credentials in .env

# 2. Build and start (first run pulls images + builds the app ~2 min)
docker compose up --build

# 3. Open http://localhost:3000
```

**Subsequent starts** (no code changes):

```sh
docker compose up
```

**Tear down** (keeps the database volume):

```sh
docker compose down
```

**Full reset** (drops all data):

```sh
docker compose down -v
```

### Stripe webhooks in local Docker

Stripe cannot reach `localhost`. Use the Stripe CLI to forward events:

```sh
stripe listen --forward-to localhost:3000/api/webhook
# Copy the printed whsec_... value into STRIPE_WEBHOOK_SECRET in .env, then rebuild
```

---

## Local Development (without Docker)

Requires Node 18 and a running MySQL 8 instance (local or remote).

```sh
# Install dependencies
npm install

# Push the schema to your database (first time and after schema changes)
npx prisma db push

# Start the dev server with hot reload
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

---

## Database

The schema lives in [prisma/schema.prisma](prisma/schema.prisma). `relationMode = "prisma"` is used for PlanetScale compatibility (no foreign-key constraints enforced at the DB level — referential integrity is enforced by Prisma instead).

### Common commands

```sh
# Reflect schema changes to the database (dev)
npx prisma db push

# Open Prisma Studio (GUI browser for your data)
npx prisma studio

# Generate the Prisma Client after editing the schema
npx prisma generate
```

> **Production note:** If you switch to a standard MySQL host (not PlanetScale), you can change `relationMode` to `"foreignKeys"` and use `prisma migrate deploy` instead of `db push` for tracked, reversible migrations.

---

## Project Structure

```
.
├── actions/            Server Actions — one file per mutation domain
│   ├── create-board/
│   ├── create-card/
│   ├── stripe-redirect/
│   └── ...
├── app/
│   ├── (marketing)/    Public landing page
│   ├── (platform)/
│   │   └── (dashboard)/
│   │       └── organization/[organizationId]/
│   └── api/
│       └── webhook/    Stripe webhook route
├── components/
│   ├── modals/         Card detail modal, pro modal
│   ├── providers/      Query client, modal, theme providers
│   └── ui/             shadcn/ui re-exports
├── config/             Feature flags (board free limit)
├── hooks/              Zustand store hooks + TanStack Query wrappers
├── lib/
│   ├── db.ts           Prisma client singleton
│   ├── stripe.ts       Stripe client singleton
│   └── utils.ts        cn() helper
├── prisma/
│   └── schema.prisma
├── Dockerfile
├── docker-compose.yml
└── .env.example
```

---

## Available Scripts

| Script | Description |
|--------|-------------|
| `npm run dev` | Start Next.js dev server with hot reload |
| `npm run build` | Production build |
| `npm run start` | Start production server (requires `npm run build` first) |
| `npm run lint` | ESLint check |

---

## Deployment

### Vercel + PlanetScale (recommended managed path)

1. Import the repo into [Vercel](https://vercel.com) — auto-detects Next.js.
2. Set all environment variables in the Vercel dashboard.
3. Use a [PlanetScale](https://planetscale.com) database — the schema's `relationMode = "prisma"` is already configured for it.
4. Set up a Stripe webhook pointing to `https://your-domain.com/api/webhook`.

### Self-hosted Docker

1. Push the image to a registry (Docker Hub, ECR, GCR):
   ```sh
   docker build \
     --build-arg NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=pk_live_... \
     --build-arg NEXT_PUBLIC_UNSPLASH_ACCESS_KEY=... \
     --build-arg NEXT_PUBLIC_APP_URL=https://your-domain.com \
     -t your-org/taskflow:latest .
   
   docker push your-org/taskflow:latest
   ```
2. Pull and run on your server with `docker compose up -d`.
3. Put a reverse proxy (nginx, Caddy, Traefik) in front on port 443.
4. Point the Stripe webhook at `https://your-domain.com/api/webhook`.

---

## License

MIT
