# syntax=docker/dockerfile:1

# ---- Build stage ----
FROM golang:1.27 AS builder

ENV GOEXPERIMENT=jsonv2 \
    CGO_ENABLED=0

WORKDIR /src

# Cache module downloads separately from source changes.
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

COPY . .

# Build a static, trimmed binary (modernc.org/sqlite is pure Go, no CGO needed).
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go build -trimpath -ldflags="-s -w" -o /out/kirocc ./cmd/kirocc

# ---- Runtime stage ----
# Alpine from Docker Hub. ca-certificates is needed for HTTPS to the Kiro backend.
FROM alpine:3.22

RUN apk add --no-cache ca-certificates \
    && adduser -D -u 10001 kirocc

COPY --from=builder /out/kirocc /usr/local/bin/kirocc

USER kirocc

# Bind to all interfaces inside the container; publish/port-map on the host side.
ENV KIROCC_DB_PATH=/data/data.sqlite3

EXPOSE 3456

ENTRYPOINT ["/usr/local/bin/kirocc"]
