#!/bin/bash
# ============================================================
# user_data.sh.tpl — runs as root on first EC2 boot
# Installs Docker, Jenkins, clones all 5 repos,
# builds Docker images and starts containers.
# ============================================================
set -euxo pipefail
exec > >(tee -a /var/log/bootstrap.log) 2>&1
echo "====== Bootstrap started $(date) ======"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get upgrade -y
apt-get install -y git curl wget unzip ca-certificates gnupg lsb-release

# ── 1. Install Docker ────────────────────────────────────────
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  gpg --dearmor -o /usr/share/keyrings/docker.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

# ── 2. Install Jenkins ───────────────────────────────────────
apt-get install -y openjdk-17-jdk
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | \
  tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
  https://pkg.jenkins.io/debian-stable binary/" \
  > /etc/apt/sources.list.d/jenkins.list
apt-get update -y && apt-get install -y jenkins
usermod -aG docker jenkins
systemctl enable jenkins && systemctl start jenkins

# ── 3. Install Terraform (stored on server) ──────────────────
TF_VER="1.8.4"
wget -q "https://releases.hashicorp.com/terraform/$${TF_VER}/terraform_$${TF_VER}_linux_amd64.zip" \
  -O /tmp/tf.zip
unzip -o /tmp/tf.zip -d /usr/local/bin/
chmod +x /usr/local/bin/terraform

# ── 4. Clone repos ───────────────────────────────────────────
APP_DIR="/opt/apps"
mkdir -p "$APP_DIR"
cd "$APP_DIR"

git clone ${node_repo}   node-app   || git -C node-app   pull origin main
git clone ${python_repo} python-app || git -C python-app pull origin main
git clone ${java_repo}   java-app   || git -C java-app   pull origin main
git clone ${go_repo}     go-app     || git -C go-app     pull origin main
git clone ${php_repo}    php-app    || git -C php-app    pull origin main

# ── 5. Copy Dockerfiles into each app directory ──────────────
mkdir -p /opt/devops/docker/{node-app,python-app,java-app,go-app,php-app}
mkdir -p /opt/devops/nginx

# Write each Dockerfile to the cloned app directories
cat > "$APP_DIR/node-app/Dockerfile" <<'NDOCKEREOF'
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production 2>/dev/null || npm install --only=production
FROM node:20-alpine
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY . .
EXPOSE 3000
ENV PORT=3000 NODE_ENV=production
CMD ["node", "index.js"]
NDOCKEREOF

cat > "$APP_DIR/python-app/Dockerfile" <<'PDOCKEREOF'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt* ./
RUN pip install --no-cache-dir -r requirements.txt 2>/dev/null || pip install flask gunicorn
COPY . .
EXPOSE 5000
ENV PORT=5000 PYTHONUNBUFFERED=1
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", "app:app"]
PDOCKEREOF

cat > "$APP_DIR/java-app/Dockerfile" <<'JDOCKEREOF'
FROM maven:3.9-eclipse-temurin-17 AS builder
WORKDIR /app
COPY pom.xml* ./
RUN mvn dependency:go-offline -q 2>/dev/null || true
COPY . .
RUN mvn clean package -DskipTests -q 2>/dev/null || echo "Maven build attempted"
FROM eclipse-temurin:17-jre-alpine
WORKDIR /app
COPY --from=builder /app/target/*.jar app.jar 2>/dev/null || true
EXPOSE 8081
ENTRYPOINT ["java", "-jar", "app.jar", "--server.port=8081"]
JDOCKEREOF

cat > "$APP_DIR/go-app/Dockerfile" <<'GDOCKEREOF'
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod* go.sum* ./
RUN go mod download 2>/dev/null || true
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o go-app . 2>/dev/null || \
    go build -o go-app ./main.go 2>/dev/null || \
    go build -o go-app ./cmd/... 2>/dev/null || true
FROM alpine:3.19
RUN apk --no-cache add ca-certificates
WORKDIR /root/
COPY --from=builder /app/go-app .
EXPOSE 8082
ENV PORT=8082
CMD ["./go-app"]
GDOCKEREOF

cat > "$APP_DIR/php-app/Dockerfile" <<'PHPDOCKEREOF'
FROM php:8.2-apache
RUN docker-php-ext-install pdo pdo_mysql 2>/dev/null || true
COPY . /var/www/html/
RUN chown -R www-data:www-data /var/www/html
EXPOSE 80
CMD ["apache2-foreground"]
PHPDOCKEREOF

# ── 6. Nginx proxy config ────────────────────────────────────
cat > /opt/devops/nginx-proxy.conf <<'NGINXEOF'
events { worker_connections 1024; }
http {
    upstream node_up   { server node-app:3000; }
    upstream python_up { server python-app:5000; }
    upstream java_up   { server java-app:8081; }
    upstream go_up     { server go-app:8082; }
    upstream php_up    { server php-app:80; }

    server {
        listen 80;
        location /node/   { proxy_pass http://node_up/;   proxy_set_header Host $host; }
        location /python/ { proxy_pass http://python_up/; proxy_set_header Host $host; }
        location /java/   { proxy_pass http://java_up/;   proxy_set_header Host $host; }
        location /go/     { proxy_pass http://go_up/;     proxy_set_header Host $host; }
        location /        { proxy_pass http://php_up/;    proxy_set_header Host $host; }
        location /health  { return 200 "OK\n"; add_header Content-Type text/plain; }
    }
}
NGINXEOF

# ── 7. Build Docker images ───────────────────────────────────
cd "$APP_DIR/node-app"   && docker build -t node-app:latest   . || true
cd "$APP_DIR/python-app" && docker build -t python-app:latest . || true
cd "$APP_DIR/java-app"   && docker build -t java-app:latest   . || true
cd "$APP_DIR/go-app"     && docker build -t go-app:latest     . || true
cd "$APP_DIR/php-app"    && docker build -t php-app:latest    . || true

# ── 8. Create Docker network ─────────────────────────────────
docker network create app-network 2>/dev/null || true

# ── 9. Run all containers ────────────────────────────────────
docker run -d --name node-app   --network app-network --restart unless-stopped node-app:latest   || true
docker run -d --name python-app --network app-network --restart unless-stopped python-app:latest || true
docker run -d --name java-app   --network app-network --restart unless-stopped java-app:latest   || true
docker run -d --name go-app     --network app-network --restart unless-stopped go-app:latest     || true
docker run -d --name php-app    --network app-network --restart unless-stopped php-app:latest    || true

# ── 10. Run Nginx reverse proxy ──────────────────────────────
docker run -d --name nginx-proxy \
  --network app-network \
  -p 80:80 \
  -v /opt/devops/nginx-proxy.conf:/etc/nginx/nginx.conf:ro \
  --restart unless-stopped \
  nginx:alpine || true

# ── 11. Store Terraform project on server ────────────────────
mkdir -p /opt/terraform/project
echo "${project_name}" > /opt/terraform/project/.project-name

# ── 12. Health summary ───────────────────────────────────────
sleep 15
echo ""
echo "====== Container Status ======"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""
echo "====== Bootstrap complete $(date) ======"
