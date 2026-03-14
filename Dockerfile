FROM alpine:3.19

# Install dependencies
RUN apk add --no-cache \
    bash \
    git \
    jq \
    curl \
    yq \
    github-cli

# Copy worker scripts
COPY worker/ /worker/
RUN chmod +x /worker/*.sh

# Persistent repo storage
VOLUME /workspace/repos

ENTRYPOINT ["/worker/entrypoint.sh"]
