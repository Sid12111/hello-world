# --- Build stage ---
FROM golang:1.22-alpine AS builder

WORKDIR /src

COPY go.mod go.sum* ./
COPY main.go ./
RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux go build -o /out/hello-world .

# --- Runtime stage ---
FROM gcr.io/distroless/static-debian12:nonroot

WORKDIR /app
COPY --from=builder /out/hello-world /app/hello-world

USER nonroot:nonroot
EXPOSE 8080

ENTRYPOINT ["/app/hello-world"]
