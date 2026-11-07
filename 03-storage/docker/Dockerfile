FROM alpine:latest

COPY --from=scanner:v1 /scanner /scanner
ENTRYPOINT ["/bin/sh", "-c", "exec /scanner >> /reports/scanner.log 2>&1"]
