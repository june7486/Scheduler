# June Scheduler — NAS sync server
#
# Build:  docker build -t june-sync .
# Run:    docker run -d -p 8099:8099 -e SYNC_SECRET='...' \
#           -v /volume1/docker/june-sync/data:/data june-sync
#
# The whole server is one dependency-free Node file, so the image stays tiny and
# there is nothing to `npm install` — fewer moving parts on a NAS.
FROM node:22-alpine

WORKDIR /app
COPY server.js ./

# Data lives outside the container so backups are a plain folder copy.
ENV DATA_DIR=/data \
    PORT=8099
RUN mkdir -p /data

EXPOSE 8099

# Health check so Docker/compose can restart a wedged process on its own.
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8099)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "server.js"]
