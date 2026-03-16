# ================================
# Stage 1: Build stage
# ================================
FROM node:22-alpine AS builder

WORKDIR /build

# Install build dependencies needed for native modules (better-sqlite3)
RUN apk add --no-cache python3 make g++

# Copy package files first for better layer caching
COPY package.json yarn.lock ./

# Install all dependencies (including devDependencies for building)
RUN yarn config set network-timeout 600000 \
  && yarn --frozen-lockfile

# Copy source files needed for build
COPY index.html vite.config.js ./
COPY ui ./ui
COPY lib ./lib

# Build frontend assets
RUN yarn build:frontend

# ================================
# Stage 2: Production stage
# ================================
FROM node:22-alpine

WORKDIR /fredy

# Install Chromium and curl (for healthcheck)
# Using Alpine's chromium package which is much smaller
# tini is a minimal init process that runs as PID 1 instead of Node.js.
# Problem: Node.js as PID 1 does NOT reap zombie/orphaned child processes.
# Each Chromium crawl leaves behind ~6 dying sub-processes (renderer, GPU, crashpad-handler).
# Without tini, these accumulate over hours until the system hits its PID limit and
# can no longer spawn new processes ("Resource temporarily unavailable", EAGAIN errno 11).
# tini reaps these orphans automatically, preventing process exhaustion.
RUN apk add --no-cache chromium curl tini

ENV NODE_ENV=production \
    IS_DOCKER=true \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser \
    CHROMIUM_FLAGS="--disable-crash-reporter --disable-gpu"

# Install build dependencies for native modules, then remove them after yarn install
COPY package.json yarn.lock ./

RUN apk add --no-cache --virtual .build-deps python3 make g++ \
  && yarn config set network-timeout 600000 \
  && yarn --frozen-lockfile --production \
  && yarn cache clean \
  && apk del .build-deps

# Copy built frontend from builder stage
COPY --from=builder /build/ui/public ./ui/public

# Copy application source (only what's needed at runtime)
COPY index.js ./
COPY index.html ./
COPY lib ./lib

# Prepare runtime directories and symlinks for data and config
RUN mkdir -p /db /conf \
  && chown 1000:1000 /db /conf \
  && chmod 777 /db /conf \
  && ln -s /db /fredy/db \
  && ln -s /conf /fredy/conf

EXPOSE 9998
VOLUME /db
VOLUME /conf

# tini acts as PID 1 and reaps zombie child processes (e.g. orphaned Chromium sub-processes)
# Without tini, Node.js as PID 1 does NOT reap zombies, causing process exhaustion over time.
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "index.js"]
