FROM node:22-bookworm-slim

ENV NODE_ENV=production
ENV PORT=8080
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY server ./server
COPY dist ./dist

USER node
EXPOSE 8080
CMD ["node", "server/index.js"]
