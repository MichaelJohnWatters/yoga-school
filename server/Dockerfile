# Multi-stage build for the yoga-school Go API.
#
# modernc SQLite is pure Go, so we build a fully static binary (CGO disabled)
# and run it on a minimal Alpine image. Alpine (not distroless) is deliberate:
# the entrypoint needs a shell to migrate-then-serve, and M4 wraps the process
# with Litestream. Build context is the repo root (see fly.toml [build]).

FROM golang:1.26-alpine AS build
WORKDIR /src/server
# Dep layer first for cache reuse. The go.mod `toolchain go1.26.9` directive
# makes `go` fetch that exact patch if the base image ships an older 1.26.x.
COPY server/go.mod server/go.sum ./
RUN go mod download
COPY server/ ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/server ./cmd/server

FROM alpine:3.20
# ca-certificates: the server makes outbound TLS calls (Firebase, Stripe, GCS).
# tzdata: studios have IANA timezones.
RUN apk add --no-cache ca-certificates tzdata \
 && adduser -D -u 10001 app
WORKDIR /app
COPY --from=build /out/server /app/server
# schema.sql must live at /app/db/schema.sql so projectRoot() (walks up from CWD
# looking for db/schema.sql) resolves it when the entrypoint runs `-migrate`.
COPY server/db/schema.sql /app/db/schema.sql
COPY server/docker-entrypoint.sh /app/docker-entrypoint.sh
RUN chmod +x /app/docker-entrypoint.sh && mkdir -p /data && chown app /data
USER app
EXPOSE 8080
ENTRYPOINT ["/app/docker-entrypoint.sh"]
