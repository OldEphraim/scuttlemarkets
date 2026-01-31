# Scuttle API — multi-stage Docker build
# Build context: repository root

# --- Stage 1: Build TypeScript ---
FROM node:20-alpine AS builder
WORKDIR /app

# Copy root workspace files
COPY package.json yarn.lock ./

# Copy workspace package.json files for dependency resolution
COPY common/package.json common/
COPY backend/shared/package.json backend/shared/
COPY backend/api/package.json backend/api/

# Install all dependencies (including devDependencies for building)
RUN yarn install --frozen-lockfile

# Copy source code
COPY common/ common/
COPY backend/shared/ backend/shared/
COPY backend/api/ backend/api/

# Build: compile TypeScript and create dist
RUN yarn --cwd common build && \
    yarn --cwd backend/shared build && \
    yarn --cwd backend/api build

# --- Stage 2: Production runtime ---
FROM node:20-alpine
WORKDIR /usr/src/app

# Install PM2 globally
RUN yarn global add pm2

# Copy the built dist output (contains compiled JS + package.json + yarn.lock)
COPY --from=builder /app/backend/api/dist/package.json /app/backend/api/dist/yarn.lock ./

# Install production dependencies only
RUN yarn install --frozen-lockfile --production

# Copy compiled JS
COPY --from=builder /app/backend/api/dist/ ./

# Copy PM2 config
COPY backend/api/ecosystem.config.js ./

EXPOSE 80/tcp
EXPOSE 8090/tcp
EXPOSE 8091/tcp
EXPOSE 8092/tcp

CMD ["pm2-runtime", "ecosystem.config.js"]
