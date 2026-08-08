FROM node:22-slim
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY index.js ./
ENV NODE_ENV=production
CMD ["node", "index.js"]
