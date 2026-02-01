# Scuttle API — multi-stage Docker build
# Works with Railway root directory set to backend/api/
# Clones the full repo in the build stage to access all workspace packages

# --- Stage 1: Build TypeScript ---
FROM node:20-alpine AS builder
RUN apk add --no-cache git rsync
WORKDIR /app

# Clone the full repo to get common/ and backend/shared/
RUN git clone --depth 1 https://github.com/OldEphraim/scuttlemarkets.git .

# Install all dependencies (including devDependencies for building)
RUN yarn install --frozen-lockfile

# Build: compile TypeScript across all workspace packages
RUN yarn --cwd common build && \
    yarn --cwd backend/shared build && \
    yarn --cwd backend/api build

# --- Stage 2: Production runtime ---
FROM node:20-alpine
WORKDIR /usr/src/app

RUN yarn global add pm2

# Copy built dist (self-contained: compiled JS + package.json + yarn.lock)
COPY --from=builder /app/backend/api/dist/package.json /app/backend/api/dist/yarn.lock ./
RUN yarn install --frozen-lockfile --production

COPY --from=builder /app/backend/api/dist/ ./
COPY --from=builder /app/backend/api/ecosystem.config.js ./

EXPOSE 80/tcp
EXPOSE 8090/tcp
EXPOSE 8091/tcp
EXPOSE 8092/tcp

CMD ["pm2-runtime", "ecosystem.config.js"]
