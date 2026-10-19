# ProdFlow – Produktions- und Beschaffungsmanagement

ProdFlow beantwortet eine Frage, die sich jede Fertigungsplanung täglich stellt:
**„Können wir diesen Auftrag fertigen – und wenn nicht, was genau müssen wir einkaufen?"**

Ein Fertigungsauftrag wird gegen die Stückliste (BOM) und den Lagerbestand geprüft.
Fehlmengen werden automatisch zu Bestellanforderungen für den Einkauf. Nach dem
Wareneingang wird der Auftrag automatisch freigegeben.

> Abschlussprojekt Modul „Fullstack, Backend & DevOps" – Syntax Institut

## Business-Workflow

```
Fertigungsauftrag anlegen ──► Materialprüfung (Stückliste × Menge vs. Bestand)
                                   │
                 ┌─────────────────┴──────────────────┐
           Bestand reicht                        Fehlmenge
                 │                                    │
            FREIGEGEBEN                 WARTET_AUF_MATERIAL + Bestellanforderung
                 │                                    │
                 │                     Einkauf genehmigt ► Wareneingang
                 │                                    │
                 │◄──────── automatische Neuprüfung ──┘
                 ▼
     Auftrag abschließen (Material wird verbraucht, Fertigprodukt eingelagert)
```

## Tech-Stack

| Bereich | Technologie | Warum |
|---|---|---|
| Backend | Java 21, Spring Boot 3.4 | Bewährt für Unternehmenssoftware, eigene Praxiserfahrung |
| Datenbank | PostgreSQL 16, Flyway | Relationale Daten (Aufträge, Stücklisten); Schema versioniert |
| Tests | JUnit 5, Testcontainers | Tests gegen echtes PostgreSQL statt In-Memory-DB |
| API-Doku | springdoc / Swagger UI | API im Browser testbar, auch in der Live-Demo |
| Container | Docker (multi-stage), Docker Compose | Gleiches Image lokal, in CI und in der Cloud |
| CI/CD | GitHub Actions, GHCR | Test (Backend, Frontend, Betriebsskripte) → Build → Auslieferung per Pull-Agent → Verify |
| Cloud | AWS EC2, Docker Compose, Caddy (HTTPS) | Einfach, nachvollziehbar, im Kurs gelernt (ADR #15; RDS ist nicht vorgesehen) |
| Frontend | Angular 21 + PrimeNG 21 (`frontend/`) | Tabellen und Formulare für Planung und Einkauf; liegt im Backend-Image (ADR #16–#19) |
| Anmeldung | Keycloak (OAuth2/OIDC, PKCE) | Rollen ADMIN, PLANNER, PURCHASER; das Backend prüft nur Tokens (ADR #14) |

Architekturentscheidungen: [`docs/architecture.md`](docs/architecture.md) ·
Backlog: [`docs/backlog.md`](docs/backlog.md) · Entwicklungstagebuch: [`docs/devlog.md`](docs/devlog.md)

## Lokal starten

Voraussetzung: Docker Desktop.

```bash
docker compose up --build
```

- Anwendung (Oberfläche): http://localhost:8080 – Anmeldung über Keycloak (http://localhost:8180); Demo-Benutzer `planner`, `purchaser`, `admin` mit den Passwörtern aus Ihrer `.env` (`.env.example` zeigt die Variablen)
- API-Dokumentation: http://localhost:8080/swagger-ui.html
- Health-Check: http://localhost:8080/actuator/health

Mit dem Profil `demo` (in `docker-compose.yml` aktiv) wird ein Demo-Datensatz geladen:
Rahmen MR-200 braucht 4 Schrauben je Stück, auf Lager sind 25.

### Demo-Ablauf

Alle `/api`-Aufrufe brauchen ein Bearer-Token von Keycloak (öffentliche Pfade: `/actuator/health`, `/version`, Swagger UI, `/v3/api-docs`). Einfachster Weg: die Oberfläche
oder Swagger UI (*Authorize*). Ablauf: Planer legt den Auftrag MR-200 × 10 an → Fehlmenge 15 Schrauben, **eine** Bestellanforderung → Einkäufer genehmigt und bucht den Wareneingang →
der Auftrag wird automatisch FREIGEGEBEN → Planer schließt ab. Als Skript mit echten Tokens: `scripts/demo-run.sh` (setzt den Datenbestand voraus, siehe `scripts/reset-demo-data.sh`).

## Tests

```bash
cd backend && mvn verify      # benötigt Docker für Testcontainers
cd frontend && npm run lint && npm test -- --no-watch   # Frontend (siehe frontend/README.md; Browser-Tests mit Playwright)
```

Die Tests bilden die Akzeptanzkriterien des MVP ab (siehe `ProductionWorkflowTest`).

## API-Überblick

| Methode | Pfad | Zweck |
|---|---|---|
| GET/POST | `/api/items` | Artikel (Material / Produkt) |
| GET/PUT | `/api/items/{id}` | Artikel lesen · ändern |
| POST | `/api/items/{id}/stock` | Bestandskorrektur |
| GET/POST/DELETE | `/api/items/{id}/bom` | Stückliste eines Produkts |
| GET/POST | `/api/production-orders` | Produktionsplan / Auftrag anlegen inkl. Materialprüfung |
| POST | `/api/production-orders/{id}/check-material` | Materialprüfung wiederholen |
| POST | `/api/production-orders/{id}/complete` | Auftrag abschließen |
| GET | `/api/purchase-requests` | Bestellanforderungen |
| POST | `/api/purchase-requests/{id}/approve` · `/receive` | Genehmigen · Wareneingang |

## Deployment

Jeder Push auf `main` läuft durch `.github/workflows/ci-cd.yml` (Details: [`docs/architecture.md`](docs/architecture.md#pipeline-test--build--deploy--verify-issue-18-pull-basiert)):

1. **Test** – Backend (`mvn verify`, Testcontainers), Frontend (Lint, Unit-Tests, Build), Betriebsskripte (Deploy-Agent, Caddyfile)
2. **Build** – ein Image mit Angular-Oberfläche und Backend (`backend/Dockerfile`, Build-Kontext = Repository-Wurzel), Tags `sha-<commit>`, `latest`, `prod`, Push nach GHCR
3. **Deploy** – pull-basiert: ein Agent auf dem Server zieht `prod`, startet es mit Health-Gate (inkl. Prüfung von Oberfläche, `/config.json` und API-401) und rollt bei Fehlern automatisch zurück
4. **Verify** – prüft von außen Revision, Oberfläche, Konfiguration, API-Autorisierung und Header (`scripts/verify-deployment.sh`)

**Rollback von Hand:** Agent pausieren (`touch /var/lib/prodflow/hold`), dann `deploy/deploy.sh sha-<früherer Commit>`. Einrichtung und Frontend-Rollout:
[`docs/first-deployment-runbook.md`](docs/first-deployment-runbook.md), [`docs/frontend-rollout.md`](docs/frontend-rollout.md).

## Roadmap (Stretch Goals)

1. Mehrstufige Stücklisten (Baugruppen mit Unterbaugruppen) – Datenmodell ist bereits vorbereitet
2. Eigenfertigung vs. Fremdbezug (Make-or-Buy) mit Unteraufträgen
3. Materialreservierung über mehrere Aufträge
4. Excel-Import von Stücklisten
5. Frontend: Bestandskorrektur-Dialog, Suche/Paginierung, mehrstufige Stückliste als TreeTable
