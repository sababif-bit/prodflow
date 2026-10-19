# Erste Inbetriebnahme auf AWS – Schritt für Schritt (Issue #17)

Stand: 17.10.2026. Dieses Runbook nutzt ausschließlich die vorhandenen Projektskripte (`deploy/bootstrap-server.sh`, `deploy/preflight.sh`, `deploy/deploy.sh`,
`deploy/agent.sh`, `scripts/duckdns-update.sh`, `scripts/smoke-auth.sh`). **Das AWS-Deployment ist noch nicht ausgeführt**; alles unter „Verifiziert" wurde lokal belegt.

| Name | Wert |
|---|---|
| Instanz | `prodflow-server`, Ubuntu 24.04, `t3.small` (2 vCPU, 2 GiB), 20 GiB – derzeit **gestoppt** |
| Anwendung | `https://prodflow-farhad.duckdns.org` (Swagger UI unter `/swagger-ui.html`) |
| Anmeldung (Keycloak) | `https://prodflow-auth-farhad.duckdns.org` |
| Server-Verzeichnis | `/opt/prodflow/repo` (Konfiguration und Geheimnisse: `/opt/prodflow/repo/deploy/.env`, Rechte 600) |
| Compose-Projekt | `prodflow-prod` (Container heißen `prodflow-prod-<dienst>-1`) |

## 0. Was verifiziert ist – und was nicht

| Bereich | Stand | Beleg |
|---|---|---|
| Bootstrap auf **sauberem Ubuntu 24.04** mit 2 GiB RAM + 2 GiB Swap (eigener Docker-Daemon in einem Wegwerf-Container) | ✅ 48/48 (auch mit halber CPU: `BOOT_CPUS=1`, 177 s) | `scripts/test-bootstrap-ubuntu.sh`: Docker-Installation, Compose-Plugin, Klon, `.env` (Rechte 600, ohne CR), echtes GHCR-Image, alle Dienste laufen, HTTPS, echte Logins, Agent, Token in keinem Container, Wiederholbarkeit, Abbruch bei falschem Tag; Bootstrap-Dauer ca. 2–3 Minuten |
| Produktionsstapel (Caddy, Backend, Keycloak, 2× PostgreSQL) | ✅ 51/51 | `scripts/test-prod-stack.sh`: Pfad-Allowlist, Ports, Rollen, Neustart, keine Geheimnisse in Logs, Speicher-Spitzen |
| Caddyfile in allen Modi (Produktion, Staging, `tls internal`) | ✅ 9/9 | `scripts/test-caddyfile.sh` |
| Pre-flight (Image-Tag, DNS) und Reihenfolge im Bootstrap | ✅ 14/14 | `scripts/test-preflight.sh` |
| Agent, Rollback, Pausenschalter | ✅ 23/23 | `scripts/test-deploy-agent.sh` |
| Speicher | ✅ Spitze aller Container zusammen ≈ **0,95 GiB** (Keycloak ≈ 560 MiB, Backend ≈ 300 MiB, Datenbanken ≈ 75 MiB, Caddy ≈ 16 MiB); im 2-GiB-Testkasten insgesamt ≤ 1,6 GiB ohne OOM | `test-prod-stack.sh`, `test-bootstrap-ubuntu.sh` |
| Echte Zertifikate (Let's Encrypt), echtes DuckDNS, echte EC2-Instanz, Zeitverhalten auf der `t3.small` | ❌ **nicht verifiziert** | erst beim ersten echten Lauf prüfbar |
| GitHub-Schritt „Verify" mit gesetzter `PROD_APP_URL` | ❌ nicht verifiziert | erst nach Schritt 7 |

## 1. Voraussetzungen (vor dem ersten Server-Befehl)

1. **Der Branch `feature/17-first-deployment-readiness` muss in `main` sein.** Der Bootstrap wird von `main` geladen und enthält erst dort die Prüfungen und die Staging-Umschaltung.
   (Zustimmung des Projektverantwortlichen nötig; siehe Abschnitt 8.)
2. **Neuer DuckDNS-Token.** Der alte Token war offengelegt und **gilt als kompromittiert**: im DuckDNS-Konto einen **neuen Token erzeugen** (Token neu generieren) und den alten nie verwenden.
   Den neuen Token nur in das verdeckte Eingabefeld des Servers tippen – nicht in PowerShell, nicht in Chat, nicht in Git.
3. Beide DuckDNS-Namen (`prodflow-farhad`, `prodflow-auth-farhad`) existieren im Konto.
4. Der **Image-Tag** des aktuellen `main`-Standes (PowerShell auf dem Laptop):
   ```powershell
   cd C:\Projects\prodflow
   git fetch origin
   $tag = "sha-" + (git rev-parse --short=7 origin/main)
   $tag
   docker manifest inspect "ghcr.io/sababif-bit/prodflow:$tag" | Select-Object -First 3    # muss Text ausgeben, sonst ist das Image (noch) nicht gebaut
   ```
   Ist die Ausgabe leer: den CI-Lauf auf `main` abwarten (`gh run list --branch main --limit 3`).

## 2. AWS-Konsole (Region der Instanz, Konto: Syntax-Sandbox)

1. **Instanz starten:** EC2 → Instances → `prodflow-server` → *Instance state* → *Start instance*. Die öffentliche IPv4 ändert sich bei jedem Stopp/Start,
   außer eine Elastic IP ist zugeordnet (*Networking* → *Elastic IPs* prüfen). Die neue IP notieren: `<IP>`.
2. **Security Group** (*Security* → Security group → *Edit inbound rules*) – genau diese Regeln:
   | Typ | Port | Quelle |
   |---|---|---|
   | SSH | 22 | **My IP** (nur Ihre aktuelle Adresse) |
   | HTTP | 80 | 0.0.0.0/0 (Let's-Encrypt-Prüfung) |
   | HTTPS | 443 | 0.0.0.0/0 |
   Keine weitere Regel (insbesondere nicht 8180).
3. **Metadaten:** *Actions* → *Instance settings* → *Modify instance metadata options*: *IMDSv2* = **Required**, *Hop limit* = **1**. Kein IAM-Instanzprofil zuordnen
   (*Actions* → *Security* → *Modify IAM role*: keine Rolle).
4. **Speicher** prüfen: Root-Volume 20 GiB. **user-data bleibt leer.**

## 3. Verbindung von PowerShell

```powershell
# einmalig: Schlüsseldatei nur für Ihr Konto lesbar machen (sonst verweigert ssh sie)
$key = "$env:USERPROFILE\.ssh\<schluessel>.pem"
icacls $key /inheritance:r
icacls $key /grant:r "$($env:USERNAME):(R)"

ssh -i $key ubuntu@<IP>
```
Beim ersten Mal den Fingerabdruck bestätigen. Kommt ein Timeout: Security Group (Quelle *My IP* aktuell?) und öffentliche IP prüfen.

## 4. Bootstrap auf dem Server (Ubuntu) – zuerst als Probe gegen Let's-Encrypt-STAGING

```bash
cd ~
curl -fsSL https://raw.githubusercontent.com/sababif-bit/prodflow/main/deploy/bootstrap-server.sh -o bootstrap-server.sh
less bootstrap-server.sh        # ansehen; mit q beenden

# 1. Lauf: Staging-Zertifikate (verbraucht keine Produktions-Limits). IMAGE_TAG = der Wert aus Abschnitt 1 (z. B. sha-1a2b3c4)
sudo APP_HOST=prodflow-farhad.duckdns.org AUTH_HOST=prodflow-auth-farhad.duckdns.org IMAGE_TAG=sha-XXXXXXX \
     ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory bash bootstrap-server.sh
```
Das Skript fragt **verdeckt** nach dem DuckDNS-Token (Eingabe wird nicht angezeigt) und erledigt der Reihe nach:
Pakete und Docker installieren → 2 GiB Swap → Repository nach `/opt/prodflow/repo` → **Pre-flight: Image-Tag existiert** → `deploy/.env` mit zufälligen Geheimnissen (Rechte 600) →
DuckDNS aktualisieren → **Pre-flight: beide Namen zeigen auf diesen Server (bis zu 5 Minuten)** → Stapel starten und auf „gesund" warten → Agent-Timer einrichten.
Dauer: etwa 6–12 Minuten. Bricht ein Pre-flight ab, ist **nichts gestartet** und keine Geheimnisse-Datei überschrieben: Ursache beheben und den Befehl **erneut** ausführen (das Skript ist wiederholbar).

**Nach erfolgreichem Staging-Lauf auf echte Zertifikate umstellen:**
```bash
sudo sed -i '/^ACME_CA=/d' /opt/prodflow/repo/deploy/.env
cd /opt/prodflow/repo/deploy
sudo docker compose --env-file .env -f docker-compose.prod.yml up -d caddy      # erstellt nur den Proxy neu; holt echte Zertifikate
sudo docker logs --since 2m prodflow-prod-caddy-1 2>&1 | grep -i -E "certificate obtained|error" | tail
```
(Wer die Probe überspringt, lässt `ACME_CA=…` im ersten Befehl weg. Scheitert dann die Zertifikatsausstellung, erst Ursache beheben – Let's Encrypt zählt Fehlversuche.)

## 5. Prüfen (auf dem Server – es verlassen keine Passwörter den Server)

```bash
# Gesundheit und Revision
curl -fsS https://prodflow-farhad.duckdns.org/actuator/health ; echo
curl -fsS https://prodflow-farhad.duckdns.org/version ; echo           # {"revision":"<40 Zeichen>"} = Commit des Images

# Echte Anmeldungen (PKCE) für planner, purchaser, admin + API-Rollen (liest die Passwörter aus deploy/.env, gibt sie nicht aus)
sudo bash -c 'set -a; . /opt/prodflow/repo/deploy/.env; set +a; /opt/prodflow/repo/scripts/smoke-auth.sh --auth-url "$AUTH_URL" --app-url "$APP_URL"'
```
Erwartet: nur `PASS`-Zeilen, am Ende `0 FAIL`. Öffentliche Fläche (müssen **404** liefern): `curl -s -o /dev/null -w "%{http_code}\n" https://prodflow-auth-farhad.duckdns.org/admin/` und `.../realms/master`.

Speicher nach dem Lauf (Entscheidung `t3.small` ↔ `t3.medium`):
```bash
free -m ; sudo docker stats --no-stream --format '{{.Name}}: {{.MemUsage}}'
sudo dmesg | grep -i -E "out of memory|killed process" || echo "keine OOM-Meldung"
```
Bleibt `available` dauerhaft unter ca. 300 MB, wird viel Swap genutzt oder gibt es OOM-Meldungen: Instanz stoppen, Typ auf `t3.medium` ändern, starten (Elastic IP bleibt; sonst DuckDNS neu setzen, Abschnitt 7).

Im Browser: `https://prodflow-farhad.duckdns.org/swagger-ui.html` → *Authorize* → Anmeldung (Demo-Passwörter nur bei Bedarf ansehen: `sudo grep '^DEMO_' /opt/prodflow/repo/deploy/.env`, nie kopieren/teilen).
Rollenwechsel: privates Fenster oder bei Keycloak abmelden (`prompt=login` wechselt den Benutzer nicht).

Optional vom Laptop (PowerShell, Passwörter verdeckt eingeben):
```powershell
foreach ($u in 'PLANNER','PURCHASER','ADMIN') {
  $s = Read-Host "DEMO_${u}_PASSWORD" -AsSecureString
  Set-Item "env:DEMO_${u}_PASSWORD" ([Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)))
}
.\scripts\smoke-auth.ps1 -KeycloakUrl https://prodflow-auth-farhad.duckdns.org -RedirectUri https://prodflow-farhad.duckdns.org/swagger-ui/oauth2-redirect.html
Remove-Item env:DEMO_PLANNER_PASSWORD, env:DEMO_PURCHASER_PASSWORD, env:DEMO_ADMIN_PASSWORD
```

## 6. Demo-Daten und Demoablauf (nach Merge von PR #30)
```bash
cd /opt/prodflow/repo
echo 'PRODFLOW_DEMO_RESET=allowed' | sudo tee -a deploy/.env >/dev/null          # einmalig, nur Demo-Server
sudo scripts/reset-demo-data.sh --project prodflow-prod --env-file deploy/.env --dry-run
sudo scripts/reset-demo-data.sh --project prodflow-prod --env-file deploy/.env --yes
sudo bash -c 'set -a; . deploy/.env; set +a; scripts/demo-run.sh --auth-url "$AUTH_URL" --app-url "$APP_URL"'
```
Nach jedem Demolauf erneut zurücksetzen (der Lauf verbraucht den Ausgangszustand). Der Agent bringt die Skripte mit dem ersten Release nach dem Merge auf den Server.

## 7. Pipeline „scharf schalten" (GitHub, auf dem Laptop)
```powershell
gh variable set PROD_APP_URL --body "https://prodflow-farhad.duckdns.org"
```
Danach prüft der Job **Verify** nach jedem Merge auf `main`, dass `/version` genau diesen Commit liefert (max. 15 Minuten) und die Anwendung gesund ist.
**Ohne** die Variable wird der Job **übersprungen (grau)** – ein graues Verify bedeutet „niemand hat das Live-System geprüft", nie „alles in Ordnung".
Wirkungsprüfung: nach dem nächsten Merge zeigt der Lauf *Verify* grün **und** auf dem Server `journalctl -u prodflow-agent -n 20` den Release.

## 8. Freigaben des Projektverantwortlichen (Claude Code hat sie nicht)
- [ ] Merge des Branches `feature/17-first-deployment-readiness` in `main` (PR; Merge-Commit). Ohne diesen Merge fehlen dem Bootstrap von `main` die neuen Prüfungen.
- [ ] Merge von PR #30 (Demo-Reset, Demolauf-Skript) – nur nötig für Abschnitt 6.
- [ ] Branch-Schutz für `main` (Issue #15; der Agent rollt alles aus, was auf `main` landet).
- [ ] `PROD_APP_URL` setzen (Abschnitt 7).
- [ ] Alle AWS-Schritte (Abschnitt 2) und der neue DuckDNS-Token.

## 9. Betrieb
| Aufgabe | Befehl (auf dem Server, mit `sudo`) |
|---|---|
| Status | `docker ps --format '{{.Names}}  {{.Status}}'` · `systemctl list-timers prodflow-agent.timer` |
| Logs | `docker logs --tail 50 prodflow-prod-backend-1` (oder `-caddy-1`, `-keycloak-1`) · `journalctl -u prodflow-agent -n 50 --no-pager` |
| Neue Version von Hand | `cd /opt/prodflow/repo/deploy && sudo flock -n -E 99 /var/lib/prodflow/agent.lock bash deploy.sh sha-<commit>` (die Sperre des Agenten verhindert einen gleichzeitigen Agentenlauf; Exit 99 = Agent läuft gerade) |
| Rollback auf ein Release ohne Oberfläche (z. B. `sha-fb08e68`) | `cd /opt/prodflow/repo/deploy && sudo env DEPLOY_ROLLBACK_TO_BACKEND_ONLY=1 flock -n -E 99 /var/lib/prodflow/agent.lock bash deploy.sh sha-<früherer Commit>`; der Schalter überspringt NUR die Prüfung von `/` und `/config.json`, Health und die 401-Prüfung gelten weiter. Ohne den Schalter lehnt das Gate das alte Release ab und stellt das neue wieder her. |
| Agent pausieren / fortsetzen | `touch /var/lib/prodflow/hold` / `rm /var/lib/prodflow/hold` |
| Keycloak-Administration | vom Laptop: `ssh -i $key -N -L 18280:127.0.0.1:8180 ubuntu@<IP>` (PowerShell; lokal **18280**, weil der Entwicklungs-Keycloak lokal 8180 belegt), dann `http://localhost:18280` (Benutzer/Passwort: `KC_BOOTSTRAP_ADMIN_*` in `deploy/.env`) |
| IP hat sich geändert (Stopp/Start ohne Elastic IP) | `bash /opt/prodflow/repo/scripts/duckdns-update.sh /opt/prodflow/repo/deploy/.env` und 1–2 Minuten warten |
| DuckDNS-Token wechseln | `read -rs -p "Neuer Token: " T; echo; sudo sed -i "s/^DUCKDNS_TOKEN=.*/DUCKDNS_TOKEN=$T/" /opt/prodflow/repo/deploy/.env; unset T` |
| Abbau (nach 26.10., Issue #13) | Instanz beenden, Elastic IP freigeben, Volumes löschen, DuckDNS-Namen entfernen |

**Nie:** `deploy/.env` neu erzeugen, solange die Datenbank-Volumes existieren (die Datenbanken behalten ihre alten Passwörter) – nur zusammen mit `docker compose down -v` auf einem leeren System.

## 10. Fehlersuche
| Symptom | Wahrscheinliche Ursache | Prüfen / Beheben |
|---|---|---|
| `preflight: FAILED - image '…' cannot be found` | Tag falsch, CI-Lauf noch nicht fertig oder Paket nicht öffentlich | Abschnitt 1, Schritt 4; `gh run list --branch main`; GHCR-Paket auf *public* |
| `preflight: FAILED - … resolves to 'nothing' / to '<andere IP>'` | DuckDNS-Namen nicht (neu) gesetzt oder Token/Name falsch | `getent ahostsv4 prodflow-farhad.duckdns.org`; `sudo bash /opt/prodflow/repo/scripts/duckdns-update.sh /opt/prodflow/repo/deploy/.env` (muss `OK` liefern) |
| `ERROR: DuckDNS update failed` | Token falsch/abgelaufen oder Name nicht im Konto | neuen Token erzeugen und eintragen (Tabelle Betrieb), Bootstrap wiederholen |
| `preflight: cannot determine this server's public IPv4` | ausgehender Verkehr blockiert | Security Group (Outbound), Internetzugang der Instanz |
| Caddy meldet Zertifikatsfehler | Port 80 nicht offen, DNS zeigt nicht auf die Instanz, Rate-Limit | `sudo docker logs prodflow-prod-caddy-1 \| tail -30`; Security Group; erst mit `ACME_CA`-Staging üben |
| Browser: Zertifikatswarnung | Staging-Zertifikat aktiv | `ACME_CA` aus der `.env` entfernen (Abschnitt 4) |
| `deploy: … did NOT become healthy` | Backend startet nicht (Datenbank, Speicher) | `sudo docker logs --tail 80 prodflow-prod-backend-1`; `free -m`; das Skript hat automatisch zurückgerollt |
| Keycloak lange nicht „healthy" | Erststart baut zuerst (1–3 Minuten auf `t3.small`) | `sudo docker logs -f prodflow-prod-keycloak-1`; Geduld bis zu 6 Minuten |
| `import-guard: REFUSED …` | Demo-Passwort schwach/fehlt auf **frischer** Datenbank | die Meldung nennt die Variable; nur auf leerem System: Volumes löschen und neu bootstrappen |
| `502` von Caddy direkt nach dem Start | Backend noch nicht bereit | 1 Minute warten; `docker ps` |
| Login schlägt fehl (`invalid_redirect_uri`) | `APP_URL` in `.env` ≠ Aufruf-URL (http/https, Schreibweise) | `.env` prüfen; Realm-Redirect-URIs entstehen aus `APP_URL` beim ersten Import |
| Agent rollt nichts aus | Pause aktiv, Tag früher gescheitert, kein neues `prod`-Image | `ls /var/lib/prodflow` (`hold`, `failed`); `journalctl -u prodflow-agent -n 50` |
| Verify grau | `PROD_APP_URL` nicht gesetzt | Abschnitt 7 |
| Verify rot | Release kam nicht an oder wurde zurückgerollt | `journalctl -u prodflow-agent`; `curl https://prodflow-farhad.duckdns.org/version` |
| SSH-Timeout | Ihre IP hat sich geändert / Instanz gestoppt | Security Group *My IP* erneuern; Instanzstatus |
| Speicher knapp / OOM | `t3.small` am Limit | Abschnitt 5 (Messung), auf `t3.medium` wechseln |

## 11. Reihenfolge in einem Blick (Kurzfassung)
1. Freigaben/Merge (Abschnitt 8) → 2. neuen DuckDNS-Token erzeugen → 3. Image-Tag ermitteln (Abschnitt 1) → 4. Instanz starten, Security Group/Metadaten prüfen (Abschnitt 2) →
5. SSH (Abschnitt 3) → 6. Bootstrap mit Staging (Abschnitt 4) → 7. auf echte Zertifikate umstellen → 8. Prüfen (Abschnitt 5) → 9. `PROD_APP_URL` setzen (Abschnitt 7) → 10. Gate-Checkliste der Roadmap.
