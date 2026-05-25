# Supabase stack for: __PROJECT_NAME__
# Ports: __PORT_BASE__ - __PORT_END__
# Generated: __TIMESTAMP__

services:
  db:
    image: supabase/postgres:15.8.1.060
    container_name: __PROJECT_NAME__-db
    restart: unless-stopped
    mem_limit: 256m
    cpus: 1.0
    ports:
      - "127.0.0.1:__PORT_DB__:5432"
    environment:
      POSTGRES_PASSWORD: __DB_PASSWORD__
      POSTGRES_DB: postgres
      JWT_SECRET: __JWT_SECRET__
    volumes:
      - __PROJECT_NAME__-db-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

  auth:
    image: supabase/gotrue:v2.170.0
    container_name: __PROJECT_NAME__-auth
    restart: unless-stopped
    mem_limit: 128m
    cpus: 0.5
    ports:
      - "127.0.0.1:__PORT_AUTH__:9999"
    environment:
      GOTRUE_API_HOST: 0.0.0.0
      GOTRUE_API_PORT: 9999
      API_EXTERNAL_URL: https://__PROJECT_NAME__.__DEV_DOMAIN__
      GOTRUE_DB_DRIVER: postgres
      GOTRUE_DB_DATABASE_URL: postgres://supabase_auth_admin:__DB_PASSWORD__@__PROJECT_NAME__-db:5432/postgres
      GOTRUE_SITE_URL: http://localhost:3000
      GOTRUE_URI_ALLOW_LIST: "*"
      GOTRUE_DISABLE_SIGNUP: "false"
      GOTRUE_JWT_SECRET: __JWT_SECRET__
      GOTRUE_JWT_EXP: "3600"
      GOTRUE_JWT_DEFAULT_GROUP_NAME: authenticated
      GOTRUE_EXTERNAL_EMAIL_ENABLED: "true"
      GOTRUE_MAILER_AUTOCONFIRM: "true"
      GOTRUE_SMTP_ADMIN_EMAIL: admin@__DEV_DOMAIN__
      GOTRUE_MAILER_URLPATHS_INVITE: /auth/v1/verify
      GOTRUE_MAILER_URLPATHS_CONFIRMATION: /auth/v1/verify
      GOTRUE_MAILER_URLPATHS_RECOVERY: /auth/v1/verify
      GOTRUE_MAILER_URLPATHS_EMAIL_CHANGE: /auth/v1/verify
    depends_on:
      db:
        condition: service_healthy

  rest:
    image: postgrest/postgrest:v12.2.8
    container_name: __PROJECT_NAME__-rest
    restart: unless-stopped
    mem_limit: 64m
    cpus: 0.25
    ports:
      - "127.0.0.1:__PORT_REST__:3000"
    environment:
      PGRST_DB_URI: postgres://authenticator:__DB_PASSWORD__@__PROJECT_NAME__-db:5432/postgres
      PGRST_DB_SCHEMAS: public,storage,graphql_public
      PGRST_DB_ANON_ROLE: anon
      PGRST_JWT_SECRET: __JWT_SECRET__
      PGRST_DB_USE_LEGACY_GUCS: "false"
      PGRST_APP_SETTINGS_JWT_SECRET: __JWT_SECRET__
      PGRST_APP_SETTINGS_JWT_EXP: "3600"
    depends_on:
      db:
        condition: service_healthy

  storage:
    image: supabase/storage-api:v1.14.5
    container_name: __PROJECT_NAME__-storage
    restart: unless-stopped
    mem_limit: 192m
    cpus: 0.5
    ports:
      - "127.0.0.1:__PORT_STORAGE__:5000"
    environment:
      ANON_KEY: __ANON_KEY__
      SERVICE_KEY: __SERVICE_KEY__
      AUTH_JWT_SECRET: __JWT_SECRET__
      AUTH_JWT_ALGORITHM: HS256
      DATABASE_URL: postgres://supabase_storage_admin:__DB_PASSWORD__@__PROJECT_NAME__-db:5432/postgres
      FILE_SIZE_LIMIT: 52428800
      STORAGE_BACKEND: file
      FILE_STORAGE_BACKEND_PATH: /var/lib/storage
      TENANT_ID: stub
      REGION: local
      GLOBAL_S3_BUCKET: stub
      IS_MULTITENANT: "false"
      POSTGREST_URL: http://__PROJECT_NAME__-rest:3000
    volumes:
      - __PROJECT_NAME__-storage-data:/var/lib/storage
    depends_on:
      db:
        condition: service_healthy
      rest:
        condition: service_started

  kong:
    image: kong:2.8.1
    container_name: __PROJECT_NAME__-kong
    restart: unless-stopped
    mem_limit: 128m
    cpus: 0.25
    ports:
      - "127.0.0.1:__PORT_KONG__:8000"
      - "127.0.0.1:__PORT_KONG_SSL__:8443"
    environment:
      KONG_DATABASE: "off"
      KONG_DECLARATIVE_CONFIG: /var/lib/kong/kong.yml
      KONG_DNS_ORDER: LAST,A,CNAME
      KONG_PLUGINS: request-transformer,cors,key-auth,acl,basic-auth
      KONG_NGINX_PROXY_PROXY_BUFFER_SIZE: 160k
      KONG_NGINX_PROXY_PROXY_BUFFERS: 64 160k
    volumes:
      - ./kong.yml:/var/lib/kong/kong.yml:ro
    depends_on:
      auth:
        condition: service_started
      rest:
        condition: service_started
      storage:
        condition: service_started

volumes:
  __PROJECT_NAME__-db-data:
  __PROJECT_NAME__-storage-data:
