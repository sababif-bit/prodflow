# Backlog – GitHub Issues

Jede Überschrift = ein GitHub Issue (Titel kopieren, Inhalt als Beschreibung).
Ein Issue → ein Branch `feature/<GitHub-Issue-Nr>-<name>` → ein Pull Request.

Labels: `backend` `frontend` `devops` `docs` `stretch`

> **Stand 20.10.2026:** Nur verifizierter Status. ✅ = umgesetzt und geprüft, ⏳ = teilweise, offen = nicht umgesetzt.
> Quellen: Repository, GitHub Issues/PRs, `docs/devlog.md`, Verifikation der Produktion vom 20.10.2026.
>
> **Hinweis zur Nummerierung (Stand 15.10.):** Die Nummern #1–#18 in diesem Dokument sind
> **Backlog-Nummern**, keine GitHub-Nummern. Bisher wurden nur die Sicherheitsthemen als
> GitHub Issues angelegt (siehe „Zusätzlich umgesetzt"). GitHub Issues und Pull Requests teilen
> sich einen Nummernkreis, daher werden sie hier immer als „GitHub Issue #…" bzw. „PR #…"
> bezeichnet. Die oben genannten Labels sind auf GitHub noch nicht angelegt.

---

## Sprint 1 – MVP (Tag 1–4)

### #1 Projektgerüst Backend `backend` ✅
Spring Boot 3.4, PostgreSQL, Flyway, Docker Compose.
- [x] `docker compose up --build` startet DB und Backend
- [x] `/actuator/health` liefert `UP`
- [x] Swagger UI erreichbar

### #2 Datenmodell Artikel, Stückliste, Aufträge, Bestellanforderungen `backend` ✅
- [x] Flyway-Migration V1 mit allen vier Tabellen und Constraints
- [x] Stückliste als selbstreferenzierende Tabelle (vorbereitet für mehrere Ebenen)
- [x] Demo-Daten über Profil `demo`

### #3 Materialprüfung und Bestellanforderungen `backend` ✅
- [x] AC1: 10 × A (4 Schrauben je Stück), Bestand 25 → Auftrag `WAITING_MATERIAL`, Anforderung über 15
- [x] AC2: Erneute Prüfung erzeugt keine zweite Anforderung
- [x] Ausreichender Bestand → Auftrag direkt `RELEASED`

### #4 Wareneingang und Auftragsabschluss `backend` ✅
- [x] AC3: Wareneingang erhöht Bestand und gibt wartende Aufträge automatisch frei
- [x] AC4: Abschluss verbraucht Material, bucht Fertigprodukt ein
- [x] Wareneingang nur nach Genehmigung

### #5 CI-Pipeline Test → Build `devops` ⏳ (Pipeline ✅, Branch-Schutz offen)
- [x] Pipeline läuft bei Push und Pull Request grün *(geprüft 20.10.: Lauf 39340016246 auf `main` grün: `test`, `frontend`, `ops`, `build`, `verify`)*
- [x] Image erscheint in GHCR mit Tag `sha-…` *(`sha-b509944`, `latest`, `prod` mit demselben Digest)*
- [ ] Branch-Schutz für `main` aktiv *(geprüft 20.10.: `main` ist nicht geschützt; GitHub Issue #15)*

### #6 Erstes Deployment auf EC2 `devops` ✅ (mit Abweichungen vom Plan)
**Status (20.10.2026): umgesetzt und auf AWS verifiziert**, abweichend vom ursprünglichen Plan: kein SSH-Deploy, sondern pull-basiertes
Deployment (ADR #18); Zielarchitektur ADR #15 → #17 (eine EC2-Instanz, Docker Compose, Caddy, zwei PostgreSQL-Container, kein RDS/Nginx).
- [ ] Budget Alert aktiv *(nicht verifiziert; AWS-Konsole prüfen)*
- [x] EC2 eingerichtet (`deploy/bootstrap-server.sh`, Ablauf in `docs/first-deployment-runbook.md`)
- [x] Geheimnisse nur auf dem Server (`deploy/.env`, Rechte 600); GitHub kennt nur die nicht geheime Variable `PROD_APP_URL` (ADR #19)
- [x] Push auf `main` → Image in GHCR → Agent deployt → `https://prodflow-farhad.duckdns.org/actuator/health` liefert `UP` *(Revision `b509944` am 20.10.2026)*

---

## Sprint 2 – Frontend & Cloud (Tag 5–9)

### #7 Angular-Projekt + Nginx-Container `frontend` `devops` ✅ (Nginx ersetzt)
> Der ursprüngliche Plan mit Nginx ist überholt: Spring Boot liefert die kompilierte Angular-Anwendung selbst aus, Caddy ist der Reverse Proxy (ADR #21).
- [x] Angular 21 + PrimeNG 21, same-origin zur API (kein CORS); `/api` und `/config.json` im Entwicklungsmodus über den Dev-Proxy
- [x] API-URL nicht hartkodiert: die Oberfläche nutzt relative `/api`-URLs; der Anmeldeserver kommt zur Laufzeit aus `GET /config.json` (ADR #22)
- [x] Frontend in Pipeline und Compose: **kein eigenes Image**, die SPA liegt im Backend-Image (ein Image, ein Tag; CI-Job `frontend` mit Lint, Unit-Tests, Build)

### #8 Artikel- und Stücklistenpflege `frontend` ⏳ (nur lesend)
- [x] Artikelliste mit Bestand (Suche, Filter, Status), Artikeldetail
- [ ] Anlegen/Bearbeiten von Artikeln in der Oberfläche *(API vorhanden, keine Oberfläche)*
- [x] Stückliste eines Produkts anzeigen (**einstufig**, ehrlich so beschriftet)
- [ ] Positionen hinzufügen/entfernen in der Oberfläche *(API vorhanden, keine Oberfläche)*
- [x] Fehlermeldungen aus `ProblemDetail` werden angezeigt (409/400 mit Begründung des Servers)

### #9 Produktionsplan und Auftragsanlage `frontend` ✅
- [x] Aufträge nach Liefertermin sortiert, Status als Chip mit Text und Symbol (nicht nur Farbe)
- [x] Auftrag anlegen zeigt das Ergebnis der Materialprüfung (Bedarf / Bestand / Fehlmenge / neu angefordert)
- [x] Button „Abschließen“ für freigegebene Aufträge (nur Rollen ADMIN und PLANNER)

### #10 Einkaufsansicht `frontend` ✅
- [x] Liste der Bestellanforderungen mit auslösendem Auftrag
- [x] Buttons „Genehmigen“ und „Wareneingang buchen“ (nur Rollen ADMIN und PURCHASER; Planer sieht die Funktionstrennung erklärt)

### #11 RDS und Secrets `devops` ✅ (RDS entfällt)
> **Entschieden (ADR #17):** PostgreSQL läuft als Container auf der EC2-Instanz, RDS ist nicht vorgesehen. Die Anforderung an Zugangsdaten gilt unverändert (ADR #19).
- [x] Zugangsdaten nur in `.env` auf dem Server (Rechte 600), nie in Git, Chat, `user-data` oder Logs
- [ ] Backups: **nicht umgesetzt** (GitHub Issue #20, Bonus); der Datenbestand der Demo ist über `scripts/reset-demo-data.sh` reproduzierbar

---

## Sprint 3 – Stabilisierung & Präsentation (Tag 10–12)

### #12 Dokumentation und Architekturdiagramm `docs` ⏳
- [x] README aktuell *(Stand 20.10.2026)*
- [ ] Architekturdiagramm als Grafik *(Textdiagramm in `docs/presentation/folien-gliederung-de.md`; Folie noch zu erstellen, GitHub Issue #12)*
- [ ] Debugging-Fall im Devlog ausgearbeitet *(Entwurf: `docs/presentation/debugging-fall-csp-de.md`; GitHub Issue #11)*

### #13 Demo vorbereiten `docs` ⏳
- [x] Demo-Skript *(`docs/presentation/demo-skript-de.md`, Oberfläche, ca. 8 Minuten)*
- [ ] Backup-Video der Demo *(offen, GitHub Issue #24)*

---

## Zusätzlich umgesetzt (außerhalb des ursprünglichen Backlogs)

Ersetzt den ursprünglichen Plan „Kein Login im MVP" (ADR #12 → ADR #14).

### Keycloak OIDC Resource Server und rollenbasierte Zugriffe `backend` ✅
GitHub Issue #1 · PR #2 (gemergt)
- [x] Backend validiert Keycloak-JWTs (Signatur, Ablauf, Issuer, Audience `prodflow-api`)
- [x] Rollen ADMIN, PLANNER, PURCHASER; Zugriffe nach Berechtigungsmatrix, deny by default
- [x] Funktionstrennung: PLANNER kann Bestellanforderungen nicht genehmigen oder vereinnahmen
- [x] Tests: `AuthorizationMatrixTest`, `JwtValidationTest`, `KeycloakRoleConverterTest`

### Lokales Keycloak-Setup `devops` ✅
GitHub Issue #3 · PR #4 (gemergt)
- [x] Keycloak mit eigener PostgreSQL in `docker-compose.yml`, Realm-Import aus `keycloak/prodflow-realm.json`
- [x] Client `prodflow-web` mit PKCE (S256) für das spätere Frontend
- [x] Zugangsdaten nur über `.env` (Vorlage `.env.example`)

### Pull-basierte Pipeline, Produktionsstapel und erstes AWS-Deployment `devops` ✅
GitHub Issues #14, #16, #17 (teilweise), #18, #10 · PRs #27, #28, #29, #31, #32
- [x] Caddy mit HTTPS (Let's Encrypt), zwei Hostnamen, Keycloak-Pfad-Allowlist, Admin nur über SSH-Tunnel
- [x] Pull-Agent mit Health-Gate, automatischem Rollback und Fehlermerker; `GET /version` und Revisions-Label; `verify`-Job
- [x] Verifiziert auf AWS am 20.10.2026: `verify-deployment.sh` 41/41, `smoke-auth.sh` 38/38, 30 Minuten Beobachtung ohne Neustart
- [ ] GitHub Issue #17: Speichermessung als `t3.small`/`t3.medium`-Entscheidung dokumentiert *(Messwerte liegen vor, Entscheidungsvermerk fehlt)*

### Angular-Frontend in Produktion `frontend` ✅
GitHub Issue #33 · PR #34 · ADR #20–#23
- [x] Dashboard, Bestand mit einstufiger Stückliste, Fertigungsaufträge, Bestellanforderungen; Rollen und Funktionstrennung
- [x] Tests: 119 Unit-Tests, 30 Browser-Tests gegen einen Einweg-Stack, Browser-Test durch Caddy (CSP), Gate-Test mit echten Containern
- [x] Anwendungs-Gate im Deployment und Rollback-Schalter `DEPLOY_ROLLBACK_TO_BACKEND_ONLY`

### Offene GitHub Issues zur Präsentation (Stand 20.10.2026)
- Pflicht: #11 Debugging-Fall, #12 Folien, #19 Ende-zu-Ende-Abnahme der Demo, #23 Dokumentation/ADRs, #24 Finale Präsentation, Clips, Proben
- Unterstützend: #15 Branch-Schutz, #22 Wiederaufbau-Übung; Bonus: #20 Backups, #21 *(Rollback nach fehlgeschlagenem Deployment ist im Agenten bereits umgesetzt; Issue auf den Restumfang prüfen)*
- Nach der Präsentation: #13 AWS-Ressourcen abbauen

---

## Stretch Goals

- #14 Mehrstufige Stückliste (rekursive Auflösung, Zyklenprüfung, kein doppeltes Zählen von Bestand) `stretch`
- #15 Make-or-Buy mit Unteraufträgen `stretch`
- #16 Materialreservierung `stretch`
- #17 Excel-Import von Stücklisten (Apache POI) `stretch`
- #18 HTTPS mit Nginx + Let's Encrypt `stretch` *(erledigt mit Caddy statt Nginx, ADR #17)*
