FROM golang:1.22-alpine AS builder
WORKDIR /src
COPY go.mod ./
COPY main.go ./
COPY basin/ ./basin/
RUN CGO_ENABLED=0 go build -o /basin .

FROM alpine:3.19
RUN apk add --no-cache ca-certificates
COPY --from=builder /basin /basin
ENTRYPOINT ["/basin"]
