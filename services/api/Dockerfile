# Build context: repo root
# docker build -f services/api/Dockerfile -t wheres_the_bus-api .

ARG PROTOC_GEN_GO_VERSION=v1.36.11
ARG PROTOC_GEN_GO_GRPC_VERSION=v1.6.2

FROM golang:1.26-alpine AS builder
ARG PROTOC_GEN_GO_VERSION
ARG PROTOC_GEN_GO_GRPC_VERSION
RUN apk add --no-cache git protobuf-dev
WORKDIR /app
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
ENV PATH $PATH:/go/bin
RUN --mount=type=cache,target=/go/pkg/mod \
    go install google.golang.org/protobuf/cmd/protoc-gen-go@${PROTOC_GEN_GO_VERSION} && \
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@${PROTOC_GEN_GO_GRPC_VERSION}
COPY models/ ./models/
RUN protoc --go_out=paths=source_relative:models \
           --go-grpc_out=paths=source_relative:models \
           -I models models/*.proto
COPY services/obs/ ./services/obs/
COPY services/shared/ ./services/shared/
COPY services/api/ ./services/api/
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o api ./services/api

FROM alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40
RUN apk add --no-cache ca-certificates tzdata && \
    addgroup -g 10001 app && \
    adduser -D -u 10001 -G app -h /home/app app && \
    mkdir -p /data && chown app:app /data
WORKDIR /home/app
COPY --from=builder --chown=app:app /app/api .
USER app:app
EXPOSE 50051 8080
ENTRYPOINT ["./api"]
