# Stride Server Deployment

Runs alongside ColorArchive on the same DigitalOcean Droplet.

## Setup on Droplet

```bash
# Clone or copy server/ to the Droplet
cd /root/stride-server
npm install --production

# Create .env
cp .env.example .env
# Edit .env with real values

# Start with PM2
pm2 start index.js --name stride-server
pm2 save
```

## Static Pages

Legal/support pages (privacy, terms, support) live in `server/docs/`.
The source of truth is `docs/` at the repo root — copy them into
`server/docs/` when they change:

```bash
cp docs/*.html server/docs/
```

The server serves these via `express.static` with `extensions: ["html"]`,
so `/privacy` resolves to `docs/privacy.html`.

## Nginx Config

Add to `/etc/nginx/sites-available/stride-api`:

```nginx
server {
    listen 80;
    server_name api.stride.yyh.app;

    location / {
        proxy_pass http://localhost:3002;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

```bash
ln -s /etc/nginx/sites-available/stride-api /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# SSL
certbot --nginx -d api.stride.yyh.app
```

## DNS

Add A record: `api.stride.yyh.app` → Droplet IP

## Ports

- ColorArchive: 3001
- Stride: 3002
