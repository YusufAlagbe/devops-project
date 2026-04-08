# ─────────────────────────────────────────────
# Dockerfile — PHP App (Nginx + PHP-FPM)
# Runs on port 80
# ─────────────────────────────────────────────
FROM composer:2 AS composer
WORKDIR /app
COPY composer.json composer.lock* ./
RUN composer install --no-dev --optimize-autoloader --no-interaction 2>/dev/null || echo "No composer.json found"

FROM php:8.2-fpm-alpine AS php
RUN docker-php-ext-install pdo pdo_mysql mbstring opcache 2>/dev/null || true
COPY --from=composer /app/vendor /var/www/html/vendor
COPY . /var/www/html/
RUN chown -R www-data:www-data /var/www/html

FROM nginx:alpine
COPY --from=php /var/www/html /var/www/html
COPY ./nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD wget -qO- http://localhost/health || exit 1
CMD ["nginx", "-g", "daemon off;"]
