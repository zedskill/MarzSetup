<div align="center">

<p align="center">
  <a href="https://github.com/gozargah/marzban" target="_blank" rel="noopener noreferrer">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://github.com/Gozargah/Marzban-docs/raw/master/screenshots/logo-dark.png">
      <img width="160" height="160" src="https://github.com/Gozargah/Marzban-docs/raw/master/screenshots/logo-light.png">
    </picture>
  </a>
</p>

# MarzSetup

One-shot Marzban panel installer with Nginx reverse proxy, firewall rules and credential saving.

[![Bash](https://img.shields.io/badge/shell-bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Docker](https://img.shields.io/badge/runtime-docker-2496ED?style=flat-square&logo=docker&logoColor=white)](https://www.docker.com/)
[![Nginx](https://img.shields.io/badge/proxy-nginx-009639?style=flat-square&logo=nginx&logoColor=white)](https://nginx.org/)
[![Marzban](https://img.shields.io/badge/panel-marzban-1a1a2e?style=flat-square)](https://github.com/gozargah/Marzban)

</div>

---

### Install

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/zedskill/MarzSetup/main/install.sh)"
```

That's it. The script handles everything else.

---

### What it does

| Step | Action |
|------|--------|
| 1 | Installs Docker if not present |
| 2 | Deploys Marzban via Docker Compose |
| 3 | Creates admin account with random credentials |
| 4 | Configures Nginx reverse proxy on port `3169` |
| 5 | Sets up 4 inbound protocols |
| 6 | Opens required ports in firewall |
| 7 | Saves credentials to `/root/marzban-credentials.txt` |

---

### Protocols

Marzban supports VLESS, VMess, Trojan, Shadowsocks. Installer opens every practical transport (no domain/TLS cert required). HTTP/2 raw inbound is omitted — Xray 24+ removed it (use XHTTP).

| Inbound | Port | Notes |
|---------|------|-------|
| VLESS TCP | 5000 | |
| VLESS WS | 5004 | path `/ws` |
| VLESS gRPC | 5005 | service `grpc` |
| VLESS XHTTP | 5006 | path `/xhttp` |
| VLESS HTTPUpgrade | 5007 | path `/hu` |
| VLESS TCP REALITY | **443** | dest/SNI `www.cloudflare.com` |
| VLESS gRPC REALITY | 8443 | |
| VLESS XHTTP REALITY | 8444 | |
| VMess TCP | 5001 | |
| VMess WS | 5008 | |
| VMess gRPC | 5009 | |
| Trojan TCP | 5002 | |
| Trojan WS | 5010 | |
| Trojan gRPC | 5011 | |
| Shadowsocks | 5003 | chacha20-ietf-poly1305 tcp/udp |

Dashboard: port **3169**. Reality `publicKey` + `shortId` → `/root/marzban-credentials.txt`.

---

### After install

Credentials are printed to stdout and saved to:

```
/root/marzban-credentials.txt
```

Panel URL, username and password are stored there with `chmod 600`.

---

### Requirements

- Debian / Ubuntu based VPS
- Root or sudo access
- Clean server (no existing Nginx config on port 3169)

---

### Notes

- Dashboard path is proxied through Nginx, not exposed directly on the Marzban port.
- Admin credentials are randomly generated on every run.
- Xray core config is applied via the Marzban API after container is healthy.

---

<div align="center">

Based on [Marzban](https://github.com/gozargah/Marzban) by Gozargah

</div>
