FROM node:24.1.0-alpine AS build
WORKDIR /src
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM nginxinc/nginx-unprivileged:1.29.0-alpine
COPY --from=build /src/dist /usr/share/nginx/html
EXPOSE 8080
