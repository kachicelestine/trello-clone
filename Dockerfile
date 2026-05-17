FROM node:18-alpine AS base
RUN apk add --no-cache libc6-compat openssl

# ─── Stage 1: Install dependencies ───────────────────────────────────────────
FROM base AS deps
WORKDIR /app
COPY package.json package-lock.json ./
# skip postinstall (prisma generate) — handled explicitly in later stages
RUN npm ci --ignore-scripts

# ─── Stage 2: Prisma client + schema (reused by migrate service) ──────────────
FROM base AS prisma
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json package-lock.json ./
COPY prisma ./prisma
RUN npx prisma generate

# ─── Stage 3: Next.js build ───────────────────────────────────────────────────
FROM base AS builder
WORKDIR /app
COPY --from=prisma /app/node_modules ./node_modules
COPY . .

# NEXT_PUBLIC_* vars are inlined at build time — pass them via --build-arg
ARG NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY
ARG NEXT_PUBLIC_CLERK_SIGN_IN_URL=/sign-in
ARG NEXT_PUBLIC_CLERK_SIGN_UP_URL=/sign-up
ARG NEXT_PUBLIC_CLERK_AFTER_SIGN_IN_URL=/
ARG NEXT_PUBLIC_CLERK_AFTER_SIGN_UP_URL=/
ARG NEXT_PUBLIC_UNSPLASH_ACCESS_KEY
ARG NEXT_PUBLIC_APP_URL

ENV NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=$NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY
ENV NEXT_PUBLIC_CLERK_SIGN_IN_URL=$NEXT_PUBLIC_CLERK_SIGN_IN_URL
ENV NEXT_PUBLIC_CLERK_SIGN_UP_URL=$NEXT_PUBLIC_CLERK_SIGN_UP_URL
ENV NEXT_PUBLIC_CLERK_AFTER_SIGN_IN_URL=$NEXT_PUBLIC_CLERK_AFTER_SIGN_IN_URL
ENV NEXT_PUBLIC_CLERK_AFTER_SIGN_UP_URL=$NEXT_PUBLIC_CLERK_AFTER_SIGN_UP_URL
ENV NEXT_PUBLIC_UNSPLASH_ACCESS_KEY=$NEXT_PUBLIC_UNSPLASH_ACCESS_KEY
ENV NEXT_PUBLIC_APP_URL=$NEXT_PUBLIC_APP_URL
ENV NEXT_TELEMETRY_DISABLED=1

RUN npm run build

# ─── Stage 4: Production runner ───────────────────────────────────────────────
FROM base AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

RUN addgroup --system --gid 1001 nodejs && \
    adduser  --system --uid 1001 nextjs

COPY --from=builder /app/public                          ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static     ./.next/static

USER nextjs

EXPOSE 3000
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

CMD ["node", "server.js"]
