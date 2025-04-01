#!/bin/bash

cd /home/"$user""/docker

containers=$(docker ps --format "{{.Names}}")

for container in $containers; do
    if docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}NoHealthCheck{{end}}' "$container" | grep -q "unhealthy"; then
        echo "Container $container is unhealthy. Restarting..."
        docker compose restart "$container"
    fi
done