# Frontend-Rollout nach AWS (Plan, nichts davon ist ausgeführt)

Stand: 19.10.2026. Gilt für den Branch `feature/frontend-foundation`. **Alle Schritte unter „Freigabe nötig“ führt der Projektverantwortliche aus oder gibt sie ausdrücklich frei**
(`CLAUDE.md`: Push, PR, Merge, Deployment, Live-Keycloak). Lokal geprüft ≠ in Produktion geprüft: Abschnitt 6 benennt die Unterschiede.

Adressen (aus `docs/first-deployment-runbook.md`): Anwendung `https://prodflow-farhad.duckdns.org`, Anmeldung `https://prodflow-auth-farhad.duckdns.org`,
Server-Verzeichnis `/opt/prodflow/repo`.

## 1. Vor dem Push (lokal, ohne Freigabe wiederholbar)
```
cd frontend && npm run lint && npm test -- --no-watch && npm run build        # Lint, 119 Unit-Tests, Build
cd backend && mvn -B verify                                                   # 132 Tests, Docker nötig
bash scripts/test-deploy-agent.sh && bash scripts/test-caddyfile.sh           # Betriebsskripte, Caddyfile
bash frontend/e2e/stack.sh reset && (cd frontend && npx playwright test)      # 30 Browser-Tests gegen den Einweg-Stack
docker build -f backend/Dockerfile --build-arg GIT_SHA=$(git rev-parse HEAD) -t prodflow-backend:prodcheck .
TEST_IMAGE_TAG=prodcheck bash scripts/test-prod-stack.sh                      # Caddy, HTTPS, CSP, Keycloak, Browser durch Caddy
```
Erwartet: überall grün, `test-prod-stack.sh` mit `0 FAIL`. Die Ports 18080/18180 (e2e) und 18088/18443/18181 (Prod-Stack) kollidieren nicht mit dem Entwicklungs-Stack (8080/8180).

## 2. Issue, Branch, Pull Request (Freigabe nötig)
`CLAUDE.md` verlangt: ein Issue → Branch `feature/<Issue-Nr.>-<name>` → PR nach `main`. Der Entwurf des Issues liegt in `docs/agents/ISSUE_DRAFT_frontend.md` (nicht angelegt).
Der Branch heißt derzeit `feature/frontend-foundation`; er kann nach Anlegen des Issues umbenannt werden (lokal, ohne Verlust). Ein Push auf `main` startet die Pipeline
inklusive Deployment: **erst Schritt 3 (Keycloak), dann den Merge**.

## 3. Keycloak: `prodflow-web` ergänzen (Live-Änderung, Freigabe nötig, rein additiv)
Warum: Der Client erlaubt bisher nur `http://localhost:4200/*`. Ohne die Ergänzung scheitert die Anmeldung der ausgelieferten Oberfläche mit „Invalid parameter: redirect_uri“.
Keycloak importiert die Realm-Datei nur beim ersten Start, deshalb wird der laufende Realm nachgezogen. Die Änderung entfernt nichts; Standardwert `+` für die Abmelde-URIs
folgt den Redirect-URIs (im lokalen Test bestätigt).

Ergänzt werden: Redirect-URI `https://prodflow-farhad.duckdns.org/*`, Web-Origin `https://prodflow-farhad.duckdns.org`, Abmelde-URI (`+` = wie Redirect-URIs, sonst zusätzlich `https://prodflow-farhad.duckdns.org/*`).

Vom Laptop (PowerShell), Verwaltung nur über den SSH-Tunnel (Port 18280 lokal, damit der Entwicklungs-Keycloak auf 8180 unberührt bleibt):
```
ssh -i $key -L 18280:127.0.0.1:8180 ubuntu@<IP>          # Fenster offen lassen
$env:KC_BOOTSTRAP_ADMIN_USERNAME = '<aus deploy/.env auf dem Server>'
$env:KC_BOOTSTRAP_ADMIN_PASSWORD = '<aus deploy/.env auf dem Server, nie ins Log/Chat kopieren>'
.\scripts\provision-web-client.ps1 -KeycloakUrl http://localhost:18280 -AppUrl https://prodflow-farhad.duckdns.org -DryRun     # zeigt „vorher/nachher“
.\scripts\provision-web-client.ps1 -KeycloakUrl http://localhost:18280 -AppUrl https://prodflow-farhad.duckdns.org             # schreibt
.\scripts\provision-web-client.ps1 -KeycloakUrl http://localhost:18280 -AppUrl https://prodflow-farhad.duckdns.org             # zweiter Lauf: „Already up to date“
Remove-Item Env:KC_BOOTSTRAP_ADMIN_PASSWORD
```
Exit 0 = fertig; 4 = der Client weicht vom erwarteten öffentlichen PKCE-Client ab (nichts geändert); 3 = Eingabefehler (nichts geändert). Das Skript ist idempotent.
Stattdessen per Admin-Konsole (`http://localhost:18280`, Realm `prodflow` → Clients → `prodflow-web`): die drei Werte von Hand ergänzen, nichts löschen.

Rollback: die drei ergänzten Werte wieder entfernen. Folge: die Anmeldung der Oberfläche schlägt fehl, API und Swagger bleiben unberührt (anderer Client).
Prüfen: `https://prodflow-auth-farhad.duckdns.org/realms/prodflow/protocol/openid-connect/auth?client_id=prodflow-web&response_type=code&scope=openid&code_challenge_method=S256&code_challenge=x&redirect_uri=https%3A%2F%2Fprodflow-farhad.duckdns.org%2F`
zeigt die Anmeldemaske (kein Fehler „Invalid parameter: redirect_uri“).

## 4. Merge und automatische Auslieferung (Freigabe nötig)
1. PR nach `main`, Pipeline grün (Jobs `test`, `frontend`, `ops`). Merge.
2. Der Build-Job baut das Image aus dem Repository-Wurzelverzeichnis (Angular + Backend) und setzt `sha-<commit>`, `latest`, `prod`.
3. Der Pull-Agent auf dem Server (jede Minute) zieht `prod` und startet `deploy.sh sha-<commit>` (Repository auf den Commit, `IMAGE_TAG`, `docker compose up -d`): Backend neu,
   **Caddy wird neu erzeugt** (Compose-Variable `RELEASE_TAG`) und liest die neue Caddyfile (CSP, Cache-Header). Kurze Unterbrechung (Sekunden bis wenige Minuten).
4. Wichtig: Der **erste** Rollout läuft noch mit dem alten `deploy.sh` des Servers. Er wartet nur auf `healthy`; die neue Anwendungsprüfung (`verify_app`) und ihr Rollback greifen
   ab dem **zweiten** Release. Deshalb zusätzlich Schritt 5 sofort ausführen. Zum Anhalten vor dem Merge: `touch /var/lib/prodflow/hold` (Auslieferung später mit `rm`).
5. Der `verify`-Job (Variable `PROD_APP_URL`) wartet auf die Revision und ruft `scripts/verify-deployment.sh` auf.

## 5. Prüfung nach der Auslieferung (nur lesend)
```
bash scripts/verify-deployment.sh --app-url https://prodflow-farhad.duckdns.org --expect-revision <40-stelliger Commit> --expect-auth-url https://prodflow-auth-farhad.duckdns.org
```
Erwartet: nur `PASS`. Dann im Browser: `https://prodflow-farhad.duckdns.org` → Anmeldung (Planer/Einkäufer, Demo-Passwörter nur bei Bedarf auf dem Server lesen) → vier Seiten öffnen, Seite neu laden (Deep Link),
Abmelden (führt zurück zur Anmeldemaske), Entwicklerkonsole ohne „Content Security Policy“-Fehler. `/swagger-ui.html` funktioniert weiter. API-Rechte unverändert (`scripts/smoke-auth.sh`).
Das Zurücksetzen der Demo-Daten (`reset-demo-data.sh`) und `demo-run.sh` brauchen weiterhin eine eigene Freigabe.

## 6. Rollback
- **Anwendung/Caddy:** `touch /var/lib/prodflow/hold`; `cd /opt/prodflow/repo/deploy && sudo bash deploy.sh sha-<früherer Commit>` (stellt Repository, Compose und Caddyfile des alten Releases wieder her; Caddy wird neu erzeugt);
  danach Fehler beheben, `rm /var/lib/prodflow/hold`. Ab dem zweiten Release erledigt `deploy.sh` das bei einem Fehler selbst.
- **Keycloak:** additiv, kein Rollback nötig; bei Bedarf die drei Werte wieder entfernen (Abschnitt 3).
- **Daten:** keine Schemaänderung, keine Migration, keine Datenänderung durch diesen Rollout.

## 7. Lokal verifiziert vs. in Produktion noch nicht verifiziert
| Lokal belegt | Erst in Produktion prüfbar |
|---|---|
| Anmeldung, alle Seiten, kompletter Ablauf mit echten Rollen (Einweg-Stack) | echte Let's-Encrypt-Zertifikate, DuckDNS, HSTS im Browser |
| SPA-Auslieferung durch Spring, Deep Links, 401/403 bei allem übrigen (132 Backend-Tests) | Anmeldung mit den echten Hostnamen (Keycloak-Ergänzung aus Abschnitt 3 angewendet) |
| CSP/Cache-Header durch Caddy mit HTTPS (internes CA), keine CSP-Verstöße im Browser, Abmelden | Verhalten hinter dem echten Netz (Firewall, IPv6, Proxys), CSP in anderen Browsern |
| `verify-deployment.sh` und `deploy.sh`-Gate (Attrappen + Produktionsnaher Stack) | der erste Rollout mit dem alten `deploy.sh` des Servers, der CI-`verify`-Job |
| Speicher: Spitze 952 MiB (Summe der Einzelspitzen) bei Limits von 1760 MiB | Verhalten auf der `t3.small` unter echter Last, Swap |

## 8. Offene Risiken
- Erster Rollout ohne automatisches Rollback bei defekter Oberfläche (siehe 4.4) → Schritt 5 sofort, Rollback-Befehl bereithalten.
- Die CSP braucht `style-src 'unsafe-inline'` (PrimeNG); ein unbekannter Browser-Fall (Erweiterungen, ältere Browser) kann Verstöße melden, die lokal nicht auftreten.
- `http://localhost:4200/*` bleibt als Redirect-URI im Produktions-Realm (bestehende Entscheidung für die Entwicklung); es erlaubt nur Umleitungen auf den lokalen Rechner des Nutzers.
- Swagger UI ist weiter öffentlich (dokumentierte Demo-Ausnahme).
