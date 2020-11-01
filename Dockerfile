FROM golang:1.15 as BUILD
WORKDIR /src
COPY go.sum go.mod ./
RUN go mod download
COPY . .
#RUN chmod 777 certificate.sh && ./certificate.sh
RUN CGO_ENABLED=0 go build -o /bin/app .
FROM debian:stretch-slim
WORKDIR /app
COPY --from=BUILD /bin/app .
ENTRYPOINT ["./app"]