FROM golang:1.26-alpine AS builder
WORKDIR /app
COPY go.mod main.go ./
RUN go mod tidy && CGO_ENABLED=0 go build -ldflags="-s -w" -o /geoip-service .

FROM scratch
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /geoip-service /geoip-service
USER 1000
EXPOSE 8080
ENTRYPOINT ["/geoip-service"]
