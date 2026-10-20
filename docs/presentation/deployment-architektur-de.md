# Deployment-Architektur von ProdFlow – kurze technische Erklärung (für die Präsentation)

Zielgruppe: Dozenten und Mitstudierende des Moduls „Fullstack, Backend & DevOps". Dauer beim Vortragen: etwa 2–3 Minuten (Folien „Cloud", „Docker", „CI/CD").
Stand: 20.10.2026 (aktualisiert nach der Auslieferung des Frontends). Alle Aussagen zum Cloud-Deployment sind auf AWS verifiziert; die Belege stehen im Abschnitt „Was wir verifiziert haben“.

## Das Ganze in einem Satz
Ein Merge auf `main` startet eine Pipeline, die die Anwendung testet, als Container-Image veröffentlicht – und der Server holt sich die neue Version
selbst, prüft sie auf Gesundheit und rollt sie bei Problemen automatisch zurück. Von außen wird anschließend geprüft, dass genau dieser Commit läuft.

## Architektur auf einen Blick

```
Browser ──HTTPS 443──►  Caddy (Reverse Proxy, automatische Zertifikate)
                          ├─ prodflow-farhad.duckdns.org       ─► Backend (Spring Boot) ─► PostgreSQL (Anwendung)
                          └─ prodflow-auth-farhad.duckdns.org  ─► Keycloak (Anmeldung)  ─► PostgreSQL (Keycloak)
                            (nur freigegebene Pfade; Admin-Konsole nicht öffentlich)

Alles auf einer EC2-Instanz (Ubuntu 24.04, t3.small) mit Docker Compose.
Öffentlich offen: nur Port 80 (Zertifikatsprüfung) und 443; SSH nur von der eigenen IP.
```

## Warum diese Entscheidungen
- **Eine Instanz, Docker Compose:** wenig Kosten (Budget 15 $/Monat), schnell wiederaufbaubar (ein Skript, etwa eine halbe Stunde), für den Projektumfang ausreichend.
  Bewusst kein Kubernetes und kein RDS: mehr Betrieb, mehr Kosten, kein Lerngewinn für dieses Projekt.
- **Caddy statt Nginx:** holt und erneuert Let's-Encrypt-Zertifikate selbst; die Konfiguration ist kurz und lesbar.
- **Zwei Hostnamen:** Anwendung und Anmeldung getrennt. Keycloak veröffentlicht nur die Pfade, die Nutzer brauchen (Anmeldung, Schlüssel);
  die Admin-Konsole ist nur über einen SSH-Tunnel erreichbar. Das Backend prüft Tokens gegen die **öffentliche** Issuer-Adresse, holt die Schlüssel aber intern.
- **Rollen und Sicherheit:** OAuth2 mit Authorization-Code-Flow und PKCE; drei Rollen (Planer, Einkäufer, Admin). Der Planer darf Bestellanforderungen **nicht** freigeben (Funktionstrennung) –
  das zeigt die Demo live (403 beim Planer, 200 beim Einkäufer).
- **Geheimnisse:** werden **auf dem Server** zufällig erzeugt (Datei mit Rechten 600), stehen nie in Git, im Chat oder in `user-data`.
  Ein Schutz vor dem ersten Import verhindert schwache oder fehlende Demo-Passwörter.

## Die Pipeline: Test → Build → Deploy → Verify
1. **Test:** bei jedem Push und Pull Request laufen drei Jobs: Backend (132 Tests, Testcontainers mit echter PostgreSQL), Frontend (Lint, 119 Unit-Tests, Produktions-Build) und Betrieb (Tests der Deployment-Skripte und der Caddyfile).
2. **Build:** nur bei grünen Tests auf `main`: **ein** Docker-Image mit Angular-Oberfläche und Backend, Commit im Label, veröffentlicht in GHCR (`sha-<commit>`, `latest` und der Zeiger `prod`).
3. **Deploy (pull-basiert):** ein kleiner Agent auf dem Server fragt jede Minute, ob das Image `prod` neu ist. Wenn ja: Konfiguration auf diesen Commit stellen,
   Container starten, auf „gesund“ warten **und** prüfen, dass die Oberfläche, die Laufzeitkonfiguration und ein 401 ohne Token wirklich ausgeliefert werden – sonst **automatischer Rollback** auf die vorherige Version. Es gibt **keinen eingehenden SSH-Zugang für Deployments**;
   der Server baut nur ausgehende Verbindungen auf.
4. **Verify:** die Pipeline fragt die öffentliche Adresse nach `/version`, wartet, bis dort **genau dieser Commit** läuft, und führt dann `scripts/verify-deployment.sh` aus (41 Prüfungen: Oberfläche, Deep Links, Konfiguration, API ohne Token, Header, Revision).
   Ein grüner Lauf heißt also: „Diese Version läuft wirklich in der Cloud". Ist die Prüfadresse nicht konfiguriert, wird der Schritt **übersprungen (grau)** und nicht fälschlich grün gezeigt.

## Was wir verifiziert haben (und womit)
- Lokal: kompletter Produktionsstapel in Wegwerf-Containern, 49–55 automatische Prüfungen (HTTPS, echte Logins, Rollen, Pfad-Allowlist, Neustart, keine Geheimnisse in Logs).
- Deployment-Skripte gegen eine saubere Ubuntu-24.04-Umgebung mit 2 GiB Speicher getestet (Ergebnis siehe `docs/first-deployment-runbook.md`).
- Der Agent mit Attrappen: neuer Stand, Rollback, Fehlermerker, Pause, Skript-Austausch während des Laufs, Statuszeilen-Varianten (42 Fälle); das **echte** `deploy.sh` gegen echte Container (Gate, Rollback in beide Richtungen, Caddy-Neuerzeugung; 18 Prüfungen).
- **AWS-Deployment (20.10.2026):** Revision `b509944` läuft; `verify-deployment.sh` 41/41, `smoke-auth.sh` 38/38 (Anmeldung mit PKCE, Token-Prüfung, Refresh, API 401/200/403 je Rolle), Browser-Test mit Planer und Einkäufer (keine CSP-Verstöße, Abmelden führt zurück zur Anmeldung), echte Let's-Encrypt-Zertifikate bis 16.01.2027.
- **Betrieb:** 30 Minuten Beobachtung ohne Neustart, OOM oder Backend-Fehler; sichtbare Unterbrechung bei der Auslieferung etwa 27 Sekunden.
- **Nicht vorhanden (ehrlich benennen):** Backups, Infrastruktur als Code, Alarmierung, Branch-Schutz für `main`, eingeübter Wiederaufbau.

## Gelernte Lektionen (Material für die Folie „Herausforderungen")
- Fehlende Passwort-Variable → Keycloak übernahm den Platzhaltertext als Passwort (Sicherheitslücke gefunden, geprüft, abgesichert).
- Windows-`openssl` liefert Zeilenenden mit `CR` → zufällige Passwörter waren „fast richtig" und Datenbank-Logins schlugen ohne klare Meldung fehl.
- `set -e` im Deploy-Skript übersprang den Rollback, wenn Compose selbst scheiterte – durch eine unabhängige Sicherheitsprüfung gefunden und mit Test abgesichert.
- Ein übersprungener Prüfschritt darf nie wie ein bestandener aussehen.
- Der Angular-Standardbuild setzt einen Inline-`onload` an das Stylesheet; unter der Content-Security-Policy würde die Seite unvollständig gestylt (Details: `docs/presentation/debugging-fall-csp-de.md`).
- Ein Anwendungs-Check im Deployment verweigert Releases ohne Oberfläche – und damit auch den Rollback auf das alte Release; gelöst mit einem expliziten, eng begrenzten Schalter.

## Mögliche Fragen
- *Warum nicht SSH-Deploy aus GitHub Actions?* Dann müsste der Server von außen erreichbar sein und ein privater Schlüssel in GitHub liegen. Pull-basiert braucht beides nicht.
- *Was, wenn die neue Version kaputt ist?* Gesundheitsprüfung schlägt fehl → Rollback auf den vorherigen Tag; die Pipeline wird rot, weil Verify den erwarteten Commit nie sieht.
- *Skalierung?* Nicht Ziel dieses Projekts; die Grenzen (eine Instanz, kein Hochverfügbarkeitskonzept) sind bewusst und dokumentiert.
