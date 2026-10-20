# AWS-Deployment: Hintergrund und Entscheidungen (Issue #17)

> **Die Schritt-für-Schritt-Anleitung mit allen Befehlen (PowerShell und Ubuntu) und der Fehlersuche steht in `docs/first-deployment-runbook.md`.**
> Dieses Dokument enthält den Hintergrund (Ressourcen, Sicherheits- und Kostenhinweise, Betriebswege).

Stand: vorbereitet am 16.10.2026; **ausgeführt am 18.10.2026**, in Betrieb und verifiziert (20.10.2026: Revision `b509944`, automatische Auslieferung aktiv). Alle Schritte in der AWS-Konsole führt der Projektverantwortliche aus;
Claude Code hat keinen AWS-Zugriff. Die Sandbox-Regeln (Berechtigungen, Budget 15 $/Monat, Zurücksetzung) sind nicht bestätigt
(Roadmap D-6): vor dem ersten Schritt prüfen, welche der folgenden Ressourcen die Sandbox erlaubt.

## Zielbild
Eine EC2-Instanz (Ubuntu 24.04) mit Docker Compose: Caddy (HTTPS), Backend, Keycloak, zwei PostgreSQL-Container
(`deploy/docker-compose.prod.yml`). Öffentlich nur **80/443**; SSH nur von der eigenen IP; die Keycloak-Admin-Konsole ist nur über
einen SSH-Tunnel erreichbar. Zwei DuckDNS-Namen (`app-…` und `auth-…`).

## 0. Vorbereitung (lokal, ohne AWS)
1. DuckDNS-Konto, zwei Subdomains anlegen, Token **nur** für den Server-Schritt bereithalten (nie in Git, Chat, Logs oder user-data).
2. Das Backend-Image muss in GHCR liegen: `ghcr.io/sababif-bit/prodflow:sha-<commit>` (CI-Lauf auf `main`, Paket öffentlich).
3. Den Image-Tag notieren (letzter grüner `main`-Lauf).

## 1. AWS-Ressourcen (jeweils einzeln bestätigen, Kosten beachten)
| Ressource | Einstellung | Anmerkung |
|---|---|---|
| EC2-Instanz | Ubuntu Server 24.04 LTS, `t3.small` (2 GB) oder `t3.medium` (4 GB) | Entscheidung nach Speichermessung (siehe unten); Speicher 20 GB gp3 |
| Security Group | eingehend TCP 80, 443 von `0.0.0.0/0`; TCP 22 **nur von der eigenen IP** | sonst nichts; keine Regel für 8180 |
| Elastic IP | der Instanz zuordnen | Ohne Elastic IP ändert sich die IP nach Stop/Start; dann `scripts/duckdns-update.sh` erneut ausführen |
| Schlüsselpaar | neu, privater Schlüssel nur lokal | nie committen |
| user-data | **leer** (oder nur `apt-get update`) | keine Geheimnisse in user-data |

### Sicherheits- und Kostenhinweise für die Instanz
- **Metadaten-Dienst:** beim Anlegen *IMDSv2 erforderlich* (Metadata version V2 only) und *Hop limit 1* wählen und der Instanz **kein IAM-Instanzprofil** geben.
  So kann ein Container (z. B. bei einer SSRF-Lücke im Backend) keine AWS-Zugangsdaten abgreifen; es gibt auch keine, die man stehlen könnte.
- **SSH nur von der eigenen IP:** wechselt Ihre IP (Heimnetz, Hotspot), sperren Sie sich aus. Ersatz: EC2 Instance Connect im Browser (falls die Sandbox es erlaubt) oder die Regel in der Konsole anpassen.
- **Speicher:** `t3.small` (2 GB) + 2 GB Swap reicht für den gemessenen Betrieb (Spitze aller Container zusammen ca. 0,95 GiB; im 2-GiB-Testkasten insgesamt ≤ 1,6 GiB ohne OOM), aber der Start von Keycloak (`start` baut zuerst) hat eine Spitze und Ubuntu selbst braucht ca. 0,2–0,3 GiB. Bei Out-of-Memory-Meldungen
  (`dmesg | grep -i oom`) oder hoher Swap-Nutzung auf `t3.medium` wechseln (Instanz stoppen, Typ ändern, starten; Elastic IP bleibt).
- **Kosten (Schätzung, in der AWS-Preisliste prüfen):** `t3.small` ca. 0,02 $/h, `t3.medium` ca. 0,05 $/h in eu-central-1; dazu öffentliche IPv4 ca. 0,005 $/h und 20 GB EBS ca. 2 $/Monat. Für ca. 10 Tage (bis 26.10.) ergibt das etwa 6 $ (small)
  bzw. 13 $ (medium) und liegt damit unter 15 $, wenn danach abgebaut wird (Issue #13). Instanz nicht unnötig 24/7 laufen lassen, falls die Sandbox das erlaubt.
- **Vorab-Prüfungen:** `deploy/preflight.sh` prüft im Bootstrap, dass der Image-Tag in GHCR existiert und beide DuckDNS-Namen auf **diese** Instanz zeigen, bevor Caddy startet
  (sonst verbraucht Caddy Let's-Encrypt-Versuche). Überspringen nur mit `SKIP_DNS_CHECK=1`.
- **Demo-Werkzeuge:** `scripts/reset-demo-data.sh` und `scripts/demo-run.sh` (PR #30) liegen im Repository; auf dem Server stehen sie, sobald der Agent einen Stand ab diesem Merge ausgerollt hat.

## 2. Server einrichten (per SSH)
```bash
ssh -i <schluessel>.pem ubuntu@<elastic-ip>
curl -fsSL https://raw.githubusercontent.com/sababif-bit/prodflow/main/deploy/bootstrap-server.sh -o bootstrap-server.sh   # Skript vorher ansehen
sudo APP_HOST=app-<name>.duckdns.org AUTH_HOST=auth-<name>.duckdns.org IMAGE_TAG=sha-<commit> bash bootstrap-server.sh
```
Das Skript installiert Docker, legt 2 GB Swap an, klont das (öffentliche) Repository nach `/opt/prodflow/repo`, erzeugt **auf dem Server**
alle Passwörter zufällig (`deploy/.env`, Rechte 600), setzt die DuckDNS-Namen und startet den Stack über `deploy/deploy.sh`
(mit automatischer Rückkehr zum vorherigen Tag, wenn das Backend nicht gesund wird). Das DuckDNS-Token wird verdeckt abgefragt.
Zertifikate holt Caddy beim ersten Aufruf selbst (Let's Encrypt; DNS muss bereits auf die Elastic IP zeigen).

Demo-Passwörter ansehen (nur wenn nötig, nie in Chat/Logs kopieren): `sudo grep '^DEMO_' /opt/prodflow/repo/deploy/.env`

### Zertifikate: Proben nicht gegen Let's Encrypt
Let's Encrypt begrenzt identische Zertifikate (ca. 5 pro Namen und Woche) und Fehlversuche. Das Volume `caddy_data` **nie** ohne Not löschen.
Für Proben/Neuaufbauten beim Bootstrap `ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory` mitgeben (landet in `deploy/.env`; die Zertifikate sind dann nicht
vertrauenswürdig, der Ablauf ist aber derselbe). Für den echten Betrieb die Zeile `ACME_CA=` aus der `.env` entfernen und Caddy neu erstellen (siehe Runbook, Abschnitt 4).
**Nicht** verwenden: eine einzeilige `TLS_DIRECTIVE` mit `tls { ca … }` – das ist in Caddy ungültig (`scripts/test-caddyfile.sh` stellt das sicher).
Voraussetzungen: Port 80 offen (HTTP-Challenge), DuckDNS-Namen zeigen auf die Instanz, bevor Caddy startet (das Bootstrap-Skript aktualisiert DuckDNS und wartet per Pre-flight darauf).

## 3. Prüfen
Vom Laptop (Passwörter als Umgebungsvariablen, nie als Argument):
```bash
DEMO_PLANNER_PASSWORD=… DEMO_PURCHASER_PASSWORD=… DEMO_ADMIN_PASSWORD=… \
  scripts/smoke-auth.sh --auth-url https://auth-<name>.duckdns.org --app-url https://app-<name>.duckdns.org
```
Erwartet: alle Zeilen `PASS`. Zusätzlich manuell: Swagger UI `https://app-<name>.duckdns.org/swagger-ui.html` → Authorize → Login als
`planner`, Auftrag anlegen, Materialprüfung; Freigabe als `planner` → 403, als `purchaser` → 200 (Demoablauf Schritte 1–5).

Negativ: `https://auth-<name>.duckdns.org/admin/` und `/realms/master` müssen 404 liefern; Port 8180 darf von außen nicht erreichbar sein.

### Demo zurücksetzen und Ablauf prüfen (auf dem Server)
```bash
cd /opt/prodflow/repo
echo 'PRODFLOW_DEMO_RESET=allowed' | sudo tee -a deploy/.env >/dev/null      # einmalig: Demo-Marker (nur auf dem Demo-Server)
sudo scripts/reset-demo-data.sh --project prodflow-prod --env-file deploy/.env --dry-run     # Ziel und Plan ansehen
sudo scripts/reset-demo-data.sh --project prodflow-prod --env-file deploy/.env --yes         # zurücksetzen
sudo bash -c 'set -a; . deploy/.env; set +a; scripts/demo-run.sh --auth-url "$AUTH_URL" --app-url "$APP_URL"'   # Ablauf mit echten Tokens
```
Nach jedem Durchlauf wieder zurücksetzen. `demo-run.sh` verweigert den Start, wenn der Ausgangszustand nicht intakt ist.

## 4. Betrieb
- **Keycloak-Admin:** `ssh -L 8180:127.0.0.1:8180 ubuntu@<ip>`, dann `http://localhost:8180` (Benutzer/Passwort aus `deploy/.env`: `KC_BOOTSTRAP_ADMIN_*`).
- **Neue Version:** kommt von selbst: CI setzt den GHCR-Zeiger `prod`, der Agent (`prodflow-agent.timer`, jede Minute) rollt aus, prüft die Gesundheit und kehrt bei Fehlern automatisch zurück (`journalctl -u prodflow-agent`). Handweg: `sudo /opt/prodflow/repo/deploy/deploy.sh sha-<commit>`.
- **Rollback von Hand:** zuerst `sudo touch /var/lib/prodflow/hold` (Agent pausieren), dann `sudo flock -n -E 99 /var/lib/prodflow/agent.lock bash deploy.sh sha-<früherer Commit>` (bei einem Release ohne Oberfläche zusätzlich `sudo env DEPLOY_ROLLBACK_TO_BACKEND_ONLY=1 …`, siehe `docs/frontend-rollout.md`); fortsetzen mit `sudo rm /var/lib/prodflow/hold`.
- **Pipeline-Prüfung (Verify):** GitHub → Settings → Secrets and variables → Actions → *Variables* → `PROD_APP_URL` = `https://app-<name>.duckdns.org` (kein Geheimnis). Ohne diese Variable wird der Verify-Job **übersprungen (grau)** – nie grün; grau heißt „nicht geprüft".
- **IP-Wechsel:** `sudo bash /opt/prodflow/repo/scripts/duckdns-update.sh /opt/prodflow/repo/deploy/.env`.
- **Speicher messen (Entscheidung t3.small/t3.medium):** nach einem vollständigen Demolauf `docker stats --no-stream` und `free -m`;
  bleibt `available` unter ca. 300 MB oder wird Swap genutzt, auf `t3.medium` wechseln.
- **Abbau (nach der Präsentation, Issue #13):** Instanz beenden, Elastic IP freigeben, Volumes löschen, DuckDNS-Namen entfernen.

## 5. Gate-Checkliste (Mo 19.10. abends)
Siehe `PRODFLOW_ROADMAP.md`, Abschnitt 5. Kurz: beide Hostnamen mit gültigem Zertifikat · Login planner und purchaser über HTTPS ·
Demoschritte 1–5 · nur 80/443 öffentlich, SSH nur eigene IP, Admin-Konsole nicht öffentlich · Geheimnisse nur in `deploy/.env` (600) ·
Speicher gemessen und Instanztyp entschieden · DNS-Aktualisierung dokumentiert.
