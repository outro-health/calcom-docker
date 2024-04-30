FROM node:18-alpine as base

FROM base as builder
RUN apk add --no-cache libc6-compat
RUN apk update

WORKDIR /calcom
RUN yarn global add turbo
COPY calcom/. .
RUN turbo prune --scope=@calcom/web --docker

FROM base as installer

ENV CALCOM_TELEMETRY_DISABLED=1
# CHECKPOINT_DISABLE disables Prisma's telemetry
ENV CHECKPOINT_DISABLE=1
ENV NEXT_TELEMETRY_DISABLED=1
ENV NODE_ENV=production
ENV STORYBOOK_DISABLE_TELEMETRY=1

ARG NEXT_PUBLIC_LICENSE_CONSENT
ARG DATABASE_URL
ARG NEXTAUTH_SECRET=secret
ARG CALENDSO_ENCRYPTION_KEY=secret
ARG MAX_OLD_SPACE_SIZE=4096

ENV NEXT_PUBLIC_WEBAPP_URL=http://NEXT_PUBLIC_WEBAPP_URL_PLACEHOLDER \
    NEXT_PUBLIC_LICENSE_CONSENT=$NEXT_PUBLIC_LICENSE_CONSENT \
    DATABASE_URL=$DATABASE_URL \
    DATABASE_DIRECT_URL=$DATABASE_URL \
    NEXTAUTH_SECRET=${NEXTAUTH_SECRET} \
    CALENDSO_ENCRYPTION_KEY=${CALENDSO_ENCRYPTION_KEY} \
    NODE_OPTIONS=--max-old-space-size=${MAX_OLD_SPACE_SIZE}

RUN apk add --no-cache libc6-compat
RUN apk update
WORKDIR /calcom

COPY .gitignore .gitignore
COPY --from=builder /calcom/out/json/ .
COPY --from=builder /calcom/out/yarn.lock ./yarn.lock

# TODO: Determine which of these can go
COPY calcom/package.json calcom/yarn.lock calcom/.yarnrc.yml calcom/playwright.config.ts calcom/turbo.json calcom/git-init.sh calcom/git-setup.sh ./
COPY calcom/.yarn ./.yarn
COPY calcom/apps/web ./apps/web
COPY calcom/packages ./packages
COPY calcom/tests ./tests

RUN yarn install

COPY --from=builder /calcom/out/full/ .

# Set CI so that linting and type checking are skipped during the build.  This is to
# lower the build time.  to have no other effects in Cal.com during build (currently).
# Defaults `yarn install` to use `--immutable`, which isn't desirable here because
# `yarn.lock` needs to be rebuilt, so it is set here after `yarn install` has already
# run.
ENV CI=1

RUN yarn turbo run build --filter=@calcom/web...

FROM base as runner
WORKDIR /calcom

# Don't run production as root
RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs
USER nextjs

COPY --from=installer /calcom/apps/web/next.config.js .
COPY --from=installer /calcom/apps/web/package.json .
COPY --from=installer /calcom/packages/prisma ./packages/prisma

# TODO: Automatically leverage output traces to reduce image size
# https://nextjs.org/docs/advanced-features/output-file-tracing

COPY --chown=nextjs:nodejs \
    scripts/start.sh \
    scripts/wait-for-it.sh \
    /calcom/scripts/
COPY --from=installer --chown=nextjs:nodejs /calcom/apps/web/.next ./

ENV CALCOM_TELEMETRY_DISABLED=1
ENV NEXT_TELEMETRY_DISABLED=1
ENV NODE_ENV=production
ENV STORYBOOK_DISABLE_TELEMETRY=1
ENV CHECKPOINT_DISABLE=1
ENV NODE_ENV=production

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=30s --retries=5 \
    CMD wget --spider http://localhost:3000 || exit 1

CMD ["/calcom/scripts/start.sh"]
