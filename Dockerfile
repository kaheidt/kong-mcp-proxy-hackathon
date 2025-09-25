FROM kong/kong-gateway:3.11-amazonlinux-2023

# Ensure any patching steps are executed as root user
USER root

# Add MCP custom plugins to the image
COPY kong/plugins/mcp-server /usr/local/share/lua/5.1/kong/plugins/mcp-server
COPY kong/plugins/mcp-tool /usr/local/share/lua/5.1/kong/plugins/mcp-tool

# Add certs
COPY certs /usr/local/share/certs

# Set Kong plugins to include our MCP plugins
ENV KONG_PLUGINS=bundled,mcp-server,mcp-tool
ENV KONG_CLUSTER_CERT=/usr/local/share/certs/control-plane.crt
ENV KONG_CLUSTER_CERT_KEY=/usr/local/share/certs/control-plane.key

# Ensure kong user is selected for image execution
USER kong

# Run kong
ENTRYPOINT ["/entrypoint.sh"]
EXPOSE 8000 8001 8100 8443
STOPSIGNAL SIGQUIT
HEALTHCHECK --interval=10s --timeout=10s --retries=10 CMD kong health
CMD ["kong", "docker-start"]