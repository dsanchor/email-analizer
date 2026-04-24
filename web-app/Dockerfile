# Stage 1: Build React
FROM node:20-alpine AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

# Stage 2: Production
FROM node:20-alpine
RUN addgroup -S appuser && adduser -S appuser -G appuser
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY server.js .
COPY --from=build /app/dist ./dist
RUN chown -R appuser:appuser /app
USER appuser
EXPOSE 8000
CMD ["node", "server.js"]
