# Supabase proxy for: __PROJECT_NAME__
# Generated: __TIMESTAMP__

server {
    listen 80;
    server_name __PROJECT_NAME__.__DEV_DOMAIN__ __STUDIO_DOMAIN__;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name __PROJECT_NAME__.__DEV_DOMAIN__;

    ssl_certificate /opt/supabase/certs/fullchain.pem;
    ssl_certificate_key /opt/supabase/certs/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    # ── Kong API Gateway (auth, rest, storage) ──
    # Route API paths to Kong; Studio lives on a separate hostname.
    location /auth/v1/ {
        proxy_pass http://127.0.0.1:__PORT_KONG__;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /rest/v1/ {
        proxy_pass http://127.0.0.1:__PORT_KONG__;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /storage/v1/ {
        proxy_pass http://127.0.0.1:__PORT_KONG__;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        return 302 https://__STUDIO_DOMAIN__;
    }
}

server {
    listen 443 ssl;
    server_name __STUDIO_DOMAIN__;

    ssl_certificate /opt/supabase/certs/fullchain.pem;
    ssl_certificate_key /opt/supabase/certs/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    # ── Studio Dashboard ──
    location / {
        auth_basic "Supabase Studio";
        auth_basic_user_file /opt/supabase/stacks/__PROJECT_NAME__/studio.htpasswd;

        proxy_pass http://127.0.0.1:__PORT_STUDIO__;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
