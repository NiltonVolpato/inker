# All-in-one Dockerfile for Inker
# Bundles: frontend (nginx), backend (bun/nestjs), PostgreSQL 17, Redis 8

# =============================================================================
# Stage 1: Build frontend
# =============================================================================
FROM oven/bun:1-slim AS frontend-builder

WORKDIR /app

COPY frontend/package.json frontend/bun.lock* ./
RUN bun install --frozen-lockfile

COPY frontend/ .

# Accept optional build argument to toggle authentication
ARG VITE_AUTH_ENABLED
ENV VITE_AUTH_ENABLED=${VITE_AUTH_ENABLED}

RUN bun run build

# =============================================================================
# Stage 2: Install backend production dependencies
# =============================================================================
FROM oven/bun:1-slim AS backend-install
ARG DB_PROVIDER=postgresql
ENV DB_PROVIDER=${DB_PROVIDER} \
    PUPPETEER_SKIP_DOWNLOAD=true \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true

WORKDIR /app

# Node.js for Prisma generate (bun segfaults with Prisma CLI); ca-certificates
# required for Prisma to fetch the query engine binary over HTTPS
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates nodejs && rm -rf /var/lib/apt/lists/*

COPY backend/package.json backend/bun.lock* ./
COPY backend/prisma ./prisma/
COPY backend/scripts ./scripts/

# Install all deps → generate prisma → reinstall production-only → prune
RUN bun install --frozen-lockfile && \
    node scripts/set-db-provider.js && \
    node ./node_modules/prisma/build/index.js generate --schema=prisma/.generated/schema.prisma && \
    cp -r node_modules/.prisma /tmp/ && \
    rm -rf node_modules && \
    PRISMA_SKIP_POSTINSTALL_GENERATE=true bun install --production --frozen-lockfile && \
    rm -rf node_modules/.prisma && \
    cp -r /tmp/.prisma node_modules/ && \
    rm -rf /tmp/.prisma \
    node_modules/typescript \
    node_modules/@types && \
    # Prune unnecessary files from production node_modules
    find node_modules \( \
        -name "*.md" -o -name "*.map" -o -name "CHANGELOG*" -o \
        -name "README*" -o -name "LICENSE*" -o -name "*.d.ts" -o \
        -name "*.test.*" -o -name "*.spec.*" -o \
        -name "__tests__" -o -name "docs" -o -name ".github" -o \
        -name "example" -o -name "examples" -o -name ".npmignore" -o \
        -name "tsconfig.json" -o -name ".eslintrc*" -o -name ".prettierrc*" \
    \) -exec rm -rf {} + 2>/dev/null || true && \
    # Remove swagger UI (not needed in production)
    rm -rf node_modules/swagger-ui-dist && \
    # Remove musl variants of sharp (production image uses Ubuntu/glibc)
    rm -rf node_modules/@img/sharp-libvips-linux-x64-musl \
           node_modules/@img/sharp-linuxmusl-x64 \
           node_modules/@img/sharp-libvips-linux-arm64-musl \
           node_modules/@img/sharp-linuxmusl-arm64

# =============================================================================
# Stage 3: Build backend
# =============================================================================
FROM oven/bun:1-slim AS backend-builder
ARG DB_PROVIDER=postgresql
ENV DB_PROVIDER=${DB_PROVIDER} \
    PUPPETEER_SKIP_DOWNLOAD=true \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true

WORKDIR /app

# Node.js for Prisma generate; ca-certificates for Prisma HTTPS downloads
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates nodejs && rm -rf /var/lib/apt/lists/*

COPY backend/package.json backend/bun.lock* ./
RUN bun install --frozen-lockfile

COPY backend/prisma ./prisma/
COPY backend/scripts ./scripts/
RUN node scripts/set-db-provider.js && node ./node_modules/prisma/build/index.js generate --schema=prisma/.generated/schema.prisma && node scripts/fix-prisma-types.js

COPY backend/ .
RUN bun run build

# =============================================================================
# Stage 4: Production (all-in-one)
# =============================================================================
FROM ubuntu:24.04 AS production

ARG S6_OVERLAY_VERSION=3.2.1.0
ARG DB_PROVIDER=postgresql
# Playwright chromium-headless-shell revision and CfT browser version.
# arm64 uses the playwright CDN (builds/chromium/{revision}/...).
# x64 uses Chrome for Testing via the playwright CDN (builds/cft/{browserVersion}/...).
# Update both together when bumping:
#   https://github.com/microsoft/playwright/blob/main/packages/playwright-core/browsers.json
ARG PLAYWRIGHT_REVISION=1219
ARG PLAYWRIGHT_BROWSER_VERSION=147.0.7727.49

ENV DB_PROVIDER=${DB_PROVIDER} \
    DEBIAN_FRONTEND=noninteractive

# Persist build-time DB_PROVIDER to a read-only file so runtime scripts can
# verify the image was built with the expected provider; unlike ENV, this file
# cannot be overridden via docker run -e.
RUN mkdir -p /etc/inker && echo "${DB_PROVIDER}" > /etc/inker/image-db-provider

# Install system packages, Playwright chromium-headless-shell, and s6-overlay
# in one layer to minimise image size.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        # Bootstrap: needed to add the PGDG repository
        curl ca-certificates gnupg \
        # Build utilities
        unzip xz-utils \
    && \
    # ---------- PostgreSQL 17 via PGDG (Ubuntu 24.04 ships PG16 only) ----------
    install -d /usr/share/postgresql-common/pgdg && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
         -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc && \
    . /etc/os-release && \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
         > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && \
    if [ "$DB_PROVIDER" = "postgresql" ]; then \
        apt-get install -y --no-install-recommends postgresql-17 postgresql-client-17; \
    fi && \
    # ---------- Application runtime packages ----------
    apt-get install -y --no-install-recommends \
        # Redis
        redis-server \
        # Nginx
        nginx \
        # Node.js (for Prisma migrations at container startup)
        nodejs \
        # Playwright chromium-headless-shell runtime dependencies
        # (sourced from playwright/nativeDeps.ts ubuntu24.04 chromium section)
        libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 \
        libcairo2 libcups2t64 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 \
        libnspr4 libnss3 libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 \
        libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2 \
        # Fonts for Unicode, CJK, and general rendering in Puppeteer
        fonts-noto fonts-noto-cjk fontconfig \
    && \
    # Rebuild font cache
    fc-cache -f && \
    # ---------- Playwright chromium-headless-shell ----------
    # arm64: Playwright custom build from playwright CDN
    #   zip structure: chrome-linux/headless_shell
    # x64:  Chrome for Testing build hosted on playwright CDN
    #   zip structure: chrome-headless-shell-linux64/chrome-headless-shell
    ARCH=$(dpkg --print-architecture) && \
    if [ "$ARCH" = "arm64" ]; then \
        CHROME_URL="https://cdn.playwright.dev/dbazure/download/playwright/builds/chromium/${PLAYWRIGHT_REVISION}/chromium-headless-shell-linux-arm64.zip"; \
    else \
        CHROME_URL="https://cdn.playwright.dev/builds/cft/${PLAYWRIGHT_BROWSER_VERSION}/linux64/chrome-headless-shell-linux64.zip"; \
    fi && \
    curl -fL "$CHROME_URL" -o /tmp/chromium.zip && \
    unzip -q /tmp/chromium.zip -d /opt/chromium-headless-shell && \
    CHROME_BIN=$(find /opt/chromium-headless-shell -type f \( -name "headless_shell" -o -name "chrome-headless-shell" \) | head -1) && \
    chmod +x "$CHROME_BIN" && \
    ln -sf "$CHROME_BIN" /usr/local/bin/chrome-headless-shell && \
    rm /tmp/chromium.zip && \
    # ---------- s6-overlay process supervisor ----------
    S6_ARCH=$(uname -m) && \
    curl -fL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" \
         -o /tmp/s6-noarch.tar.xz && \
    tar -C / -Jxpf /tmp/s6-noarch.tar.xz && \
    curl -fL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" \
         -o /tmp/s6-arch.tar.xz && \
    tar -C / -Jxpf /tmp/s6-arch.tar.xz && \
    rm /tmp/s6-noarch.tar.xz /tmp/s6-arch.tar.xz && \
    # Remove default nginx server block (conflicts with our config on port 80)
    rm -f /etc/nginx/sites-enabled/default && \
    # Clean apt caches
    rm -rf /var/lib/apt/lists/* && \
    # Remove auto-created PostgreSQL cluster (will be initialized on first run)
    if [ "$DB_PROVIDER" = "postgresql" ]; then \
        rm -rf /var/lib/postgresql; \
    fi

# Install Bun runtime (copy from slim image — glibc build, matches Ubuntu)
COPY --from=oven/bun:1-slim /usr/local/bin/bun /usr/local/bin/bun
RUN ln -s /usr/local/bin/bun /usr/local/bin/bunx

# Puppeteer configuration — points at the Playwright chromium-headless-shell
ENV PUPPETEER_EXECUTABLE_PATH=/usr/local/bin/chrome-headless-shell
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true

# Application environment defaults
ENV NODE_ENV=production \
    PORT=3002 \
    DATABASE_URL= \
    REDIS_HOST=localhost \
    REDIS_PORT=6379 \
    REDIS_PASSWORD=inker_redis \
    REDIS_URL=redis://:inker_redis@localhost:6379 \
    ADMIN_PIN=1111 \
    CORS_ORIGINS=* \
    LOG_LEVEL=info

# Set up application directory
WORKDIR /app

# Copy backend production dependencies
COPY --from=backend-install /app/node_modules ./node_modules

# Copy Prisma schema and generated client
COPY --from=backend-install /app/prisma ./prisma/
COPY --from=backend-install /app/node_modules/.prisma ./node_modules/.prisma
COPY --from=backend-install /app/node_modules/@prisma ./node_modules/@prisma

# Copy backend build
COPY --from=backend-builder /app/dist ./dist
COPY backend/package.json ./

# Copy backend font assets
COPY backend/assets/fonts /app/assets/fonts

# Copy frontend build to nginx html directory
COPY --from=frontend-builder /app/dist /usr/share/nginx/html

# Copy frontend font files
COPY frontend/public/fonts /usr/share/nginx/html/fonts

# Copy nginx config (goes into conf.d/ — included inside http{} by Ubuntu's nginx.conf)
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf

# Copy s6-overlay service definitions
COPY docker/cont-init.d/ /etc/cont-init.d/
COPY docker/services.d/ /etc/services.d/
RUN chmod +x /etc/cont-init.d/* && \
    chmod +x /etc/services.d/*/run

# Create required directories
RUN mkdir -p /app/uploads/screens /app/uploads/firmware /app/uploads/widgets \
    /app/uploads/captures /app/uploads/drawings /app/logs /app/data \
    /data && \
    if [ "$DB_PROVIDER" = "postgresql" ]; then \
        mkdir -p /var/lib/postgresql/17/main /run/postgresql && \
        chown -R postgres:postgres /var/lib/postgresql /run/postgresql; \
    fi

# Create non-root user for backend process
RUN groupadd -r inker && \
    useradd -r -g inker -M -s /usr/sbin/nologin inker && \
    chown -R inker:inker /app /data

EXPOSE 80

# Health check via nginx
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD bun -e "const r=await fetch('http://127.0.0.1/health');process.exit(r.ok?0:1)" || exit 1

# s6-overlay entrypoint
ENTRYPOINT ["/init"]
