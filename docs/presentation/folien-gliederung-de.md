# Folien-Gliederung, Architekturerklärung und Beleg-Matrix (Entwurf)

Stand: 20.10.2026 · Präsentation am Montag, 26.10.2026 · Material für GitHub Issues #12 und #24. Zielzeit: Folien **ca. 9–10 Minuten** plus **Live-Demo 8 Minuten** (≈ 18 Minuten; Rahmen laut Issue #24: 15–20 Minuten).
**Zu klären:** die offizielle Zeitvorgabe (10–15 Minuten reine Folien oder Gesamtzeit). Kurzvariante unten.

## 1. Gliederung (13 Folien + Demo)

| # | Folie | Kernaussage (1 Satz) | Zeit | Beleg/Bild |
|---|---|---|---|---|
| 1 | Titel und Problem | „Können wir diesen Auftrag fertigen – und wenn nicht, was müssen wir einkaufen?“ | 0:30 | Titelbild, ein Satz Problem |
| 2 | Lösung: der Business-Workflow | Auftrag → Materialprüfung gegen Stückliste und Bestand → Fehlmenge wird Bestellanforderung → Wareneingang gibt automatisch frei → Abschluss | 0:45 | Ablaufdiagramm aus der README |
| 3 | Architektur im Überblick | Ein Image (Oberfläche + Backend), Caddy mit HTTPS, Keycloak, zwei PostgreSQL, alles auf einer EC2-Instanz | 1:00 | Architekturdiagramm (siehe 2.) |
| 4 | Technologien und Begründung | Java 21/Spring Boot, PostgreSQL/Flyway, Angular/PrimeNG, Keycloak, Docker/Compose, GitHub Actions/GHCR, AWS/Caddy – je ein Satz „warum“ | 0:30 | Tabelle (README „Tech-Stack“) |
| 5 | Rollen und Funktionstrennung | Planer plant, Einkäufer kauft ein; das Backend erzwingt es (deny by default) | 0:45 | Rollenmatrix, Screenshot `08-bestellanforderungen-planer-lesend.png` |
| – | **Live-Demo** | Geschäftsablauf mit zwei Rollen | **8:00** | `docs/presentation/demo-skript-de.md` |
| 6 | Docker | Mehrstufiger Build (Node → Maven → JRE), nicht-root, Healthcheck, Commit im Label: ein Image, ein Tag | 0:40 | `backend/Dockerfile` |
| 7 | CI/CD | Tests → Image → Server holt sich die Version selbst → Gesundheits- und Anwendungs-Gate → Rollback → Verify von außen | 1:15 | Pipeline-Diagramm, Lauf auf GitHub |
| 8 | Cloud und Sicherheit | EC2 + Compose + Caddy, Let's Encrypt, nur 80/443, SSH nur eigene IP, Admin nur per Tunnel, Geheimnisse nur auf dem Server | 0:50 | Beleg-Matrix (siehe 3.), Zertifikat |
| 9 | Technische Herausforderung und Debugging-Fall | Die CSP blockiert Angulars Inline-`onload`; Ursache, Diagnose, Fix, Lehre | 1:15 | `docs/presentation/debugging-fall-csp-de.md` |
| 10 | Qualität und Verifikation | 132 + 119 + 30 Tests, Tests der Deployment-Skripte mit echten Containern, 41 + 38 Prüfungen gegen die Produktion | 0:30 | Zahlenfolie |
| 11 | Grenzen und Ausblick | Einstufige Stückliste, keine Reservierung, Oberfläche überwiegend lesend, keine Backups; Ausblick mehrstufige Stückliste | 0:40 | ehrliche Liste |
| 12 | Lessons Learned | 3–4 Punkte (siehe 4.) | 0:30 | – |
| 13 | Fragen | Reserve-Folien: ADR-Tabelle, Speichermessung, Kosten | – | `docs/architecture.md` |

**Live-CI/CD (optional, empfohlen):** Direkt **nach** der Demo einen vorbereiteten, harmlosen Pull Request mergen (z. B. eine Textänderung in der Dokumentation, Checks vorher grün). Die Pipeline läuft, während Folien 6–9 gesprochen werden;
bei Folie 9/10 den Lauf grün und `/version` mit dem neuen Commit zeigen. Zeitbedarf (zu messen in den Proben): Image nach ca. 4 Minuten (Lauf 39340016246: `test` 56 s, `build` 2 m 17 s), danach bis zu 70 s Agententakt und ca. 30–40 s Neustart
(beobachtet: 27 s sichtbare Unterbrechung). **Während des Neustarts kein Klick in der Anwendung.** Wird der Merge nicht live gezeigt: Lauf aus der Vorbereitung als Screenshot/Clip.

**Kurzvariante (ca. 13 Minuten):** Folien 4 und 12 entfallen, Demo ohne Schritt 7 und ohne die optionalen Einschübe (ca. 6 Minuten), Folien 10 und 11 zusammenlegen.

## 2. Architektur in 60 Sekunden (Sprechtext)

```
Browser ──HTTPS 443──► Caddy (Reverse Proxy, Zertifikate, CSP/HSTS)
                          ├─ prodflow-farhad.duckdns.org       ─► Backend (Spring Boot + Angular-Oberfläche) ─► PostgreSQL (Anwendung)
                          └─ prodflow-auth-farhad.duckdns.org  ─► Keycloak (Anmeldung, nur freigegebene Pfade) ─► PostgreSQL (Keycloak)

GitHub Actions ─► GHCR (Image sha-<commit>) ◄── Agent auf dem Server (jede Minute, nur ausgehende Verbindungen)
Eine EC2-Instanz (Ubuntu 24.04, t3.small), Docker Compose; öffentlich nur 80/443; SSH nur von der eigenen IP; Keycloak-Admin nur per SSH-Tunnel
```

**Sagen:** „ProdFlow ist ein Monolith: ein Spring-Boot-Backend, das auch die Angular-Oberfläche ausliefert, damit Oberfläche und API immer zusammen ausgeliefert und zurückgerollt werden. Davor sitzt Caddy; er holt die HTTPS-Zertifikate selbst und setzt Sicherheits-Header.
Die Anmeldung übernimmt Keycloak, das Backend prüft nur Tokens – Signatur, Ablauf, Aussteller und Zielgruppe – und erzwingt die Rollen. Anwendung und Keycloak haben je eine eigene PostgreSQL-Datenbank. Alles läuft auf **einer** kleinen EC2-Instanz mit Docker Compose:
bewusst einfach, günstig und erklärbar. Neue Versionen schiebt die CI nicht auf den Server; der Server holt sie selbst, prüft sie und rollt bei Problemen zurück.“

## 3. Beleg-Matrix Cloud und DevOps

| Praxis | Beleg (zeigbar) | Quelle / Befehl | Status |
|---|---|---|---|
| Automatisierte Tests in der CI | Lauf auf `main` mit Jobs `test`, `frontend`, `ops`, `build`, `verify` grün (Lauf 39340016246) | GitHub → Actions | belegt |
| Container, mehrstufiger Build | Ein Image mit Oberfläche und Backend; nicht-root; Healthcheck; Revision im Label | `backend/Dockerfile`, `docker buildx imagetools inspect ghcr.io/sababif-bit/prodflow:prod` | belegt |
| Unveränderliche Versionierung | Tags `sha-<7>` mit Digest; `/version` zeigt den Commit | GHCR, `https://prodflow-farhad.duckdns.org/version` | belegt |
| Pull-basiertes Deployment | systemd-Agent, keine eingehende Verbindung für Deployments | `deploy/agent.sh`, `deploy/deploy.sh` | belegt |
| Automatischer Rollback | `deploy.sh` stellt das alte Release wieder her; mit echten Containern getestet (18 Prüfungen) | `scripts/test-deploy-gate.sh` | belegt (lokal getestet, im Betrieb nicht ausgelöst) |
| Verifikation von außen | 41 Prüfungen (Oberfläche, Konfiguration, API ohne Token, Header, Revision) | `scripts/verify-deployment.sh`, Job `verify` | belegt |
| HTTPS | Let's-Encrypt-Zertifikate bis 16.01.2027, TLS 1.3, HTTP → HTTPS (308), HSTS | Browser-Schloss, `openssl s_client` | belegt |
| Sicherheits-Header | CSP (`script-src 'self'`), `frame-ancestors 'none'`, nosniff | `curl -I https://prodflow-farhad.duckdns.org/` | belegt |
| Authentifizierung/Autorisierung | PKCE-Anmeldung, 401 ohne Token, 403 für den Planer bei Genehmigung | `scripts/smoke-auth.sh` (38 Prüfungen) | belegt |
| Netzwerk-Härtung | nur 80/443 öffentlich, SSH nur eigene IP, Keycloak-Admin nur per Tunnel | Security Group (AWS-Konsole zeigen), Caddyfile-Allowlist | **zeigen in der Konsole** (nicht von mir geprüft) |
| Geheimnisse | zufällig auf dem Server, Rechte 600, nie in Git/Logs (Test: kein Geheimnis in Logs) | `scripts/test-prod-stack.sh` | belegt (Logs) / Rechte: Server |
| Ressourcen | Messung: Instanz nach 30 Minuten ca. 1,3 GB belegt, 560 MB verfügbar | S8A-Beobachtung, `docs/architecture.md` ADR #17 | belegt |
| Reproduzierbarkeit | Bootstrap-Skript, Runbooks; Wiederaufbau **nicht** geübt | `deploy/bootstrap-server.sh`, GitHub Issue #22 | teilweise |
| Kostenkontrolle | Budget 15 $/Monat geplant; Alarm **nicht verifiziert**; Abbau nach der Präsentation (Issue #13) | AWS-Konsole | offen/prüfen |
| Backups, Infrastruktur als Code, Monitoring/Alarme, Branch-Schutz | **nicht vorhanden** (Issues #20, #15) | – | ehrlich als Grenze nennen |

## 4. Lessons Learned (Folie 12, Auswahl)
1. **Klein anfangen, früh in die Cloud:** ein lauffähiger, getesteter, deployter Kern vor Erweiterungen (einstufige Stückliste statt halber Mehrstufigkeit).
2. **Pull statt Push:** Der Server holt sich Versionen selbst – kein SSH-Schlüssel in GitHub, kein offener Verwaltungsport.
3. **„Healthy“ reicht nicht:** Der Gesundheitscheck sagt nichts darüber, ob die Anwendung wirklich ausgeliefert wird; deshalb prüft das Deployment auch Oberfläche, Konfiguration und 401.
4. **Ein übersprungener Test darf nie wie ein bestandener aussehen** (Verify-Job grau statt grün).
5. **Sicherheit am echten Artefakt testen** (CSP-Debugging-Fall).

## 5. Mögliche Fragen
- *Warum Monolith und eine Instanz?* Ein Entwickler, wenig Zeit; Microservices und Kubernetes hätten nur Betriebsaufwand erzeugt (ADR #1, #17).
- *Warum nicht SSH-Deploy aus GitHub Actions?* Pull-basiert braucht weder einen offenen Server-Port noch einen privaten Schlüssel in GitHub (ADR #18).
- *Warum nur eine Stücklistenebene?* MVP-Umfang; das Datenmodell ist vorbereitet, die rekursive Auflösung mit Zyklenprüfung fehlt (ADR #4).
- *Was passiert bei einer kaputten Version?* Gate schlägt fehl → Rollback; die Pipeline wird rot, weil Verify den Commit nie sieht. Gezeigt in den Tests, nicht live ausgelöst.
- *Was fehlt noch?* Backups, Alarmierung, Infrastruktur als Code, Branch-Schutz, Zero-Downtime.
