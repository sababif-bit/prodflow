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
| CI/CD | GitHub Actions, GHCR | Test → Build → Deploy bei jedem Push auf `main` |
| Cloud | AWS EC2 (+ RDS ab Tag 7) | Einfach, nachvollziehbar, im Kurs gelernt |
| Frontend | Angular + PrimeNG *(folgt)* | Tabellen und Formulare für Planung und Einkauf |

Architekturentscheidungen: [`docs/architecture.md`](docs/architecture.md) ·
Backlog: [`docs/backlog.md`](docs/backlog.md) · Entwicklungstagebuch: [`docs/devlog.md`](docs/devlog.md)

## Lokal starten

Voraussetzung: Docker Desktop.

```bash
docker compose up --build
```

- API-Dokumentation: http://localhost:8080/swagger-ui.html
- Health-Check: http://localhost:8080/actuator/health

Mit dem Profil `demo` (in `docker-compose.yml` aktiv) wird ein Demo-Datensatz geladen:
Rahmen MR-200 braucht 4 Schrauben je Stück, auf Lager sind 25.

### Demo in 4 Requests

```bash
# 1. Fertigungsauftrag über 10 Stück -> wartet, Bestellanforderung über 15 Schrauben
curl -X POST localhost:8080/api/production-orders -H 'Content-Type: application/json' \
     -d '{"productId":1,"quantity":10,"dueDate":"2026-12-01"}'

# 2. Bestellanforderungen ansehen
curl localhost:8080/api/purchase-requests

# 3. Genehmigen und Wareneingang buchen -> Auftrag wird automatisch FREIGEGEBEN
curl -X POST localhost:8080/api/purchase-requests/1/approve
curl -X POST localhost:8080/api/purchase-requests/1/receive

# 4. Produktionsplan
curl localhost:8080/api/production-orders
```

## Tests

```bash
cd backend && mvn verify      # benötigt Docker für Testcontainers
```

Die Tests bilden die Akzeptanzkriterien des MVP ab (siehe `ProductionWorkflowTest`).

## API-Überblick

| Methode | Pfad | Zweck |
|---|---|---|
| GET/POST | `/api/items` | Artikel (Material / Produkt) |
| POST | `/api/items/{id}/stock` | Bestandskorrektur |
| GET/POST/DELETE | `/api/items/{id}/bom` | Stückliste eines Produkts |
| GET/POST | `/api/production-orders` | Produktionsplan / Auftrag anlegen inkl. Materialprüfung |
| POST | `/api/production-orders/{id}/check-material` | Materialprüfung wiederholen |
| POST | `/api/production-orders/{id}/complete` | Auftrag abschließen |
| GET | `/api/purchase-requests` | Bestellanforderungen |
| POST | `/api/purchase-requests/{id}/approve` · `/receive` | Genehmigen · Wareneingang |

## Deployment

Jeder Push auf `main` läuft durch die Pipeline in `.github/workflows/ci-cd.yml`:

1. **Test** – `mvn verify` mit PostgreSQL in Testcontainers
2. **Build** – Docker-Image, Tag `sha-<commit>` und `latest`, Push nach GHCR
3. **Deploy** – per SSH auf EC2: neues Image ziehen, Container neu starten, Health-Check

**Rollback:** In `/opt/prodflow/.env` auf dem Server `IMAGE_TAG` auf den vorherigen
`sha-…`-Tag setzen und `docker compose -f docker-compose.prod.yml up -d` ausführen.

Einrichtung des Servers: siehe [`docs/architecture.md`](docs/architecture.md#deployment-einrichtung).

## Roadmap (Stretch Goals)

1. Mehrstufige Stücklisten (Baugruppen mit Unterbaugruppen) – Datenmodell ist bereits vorbereitet
2. Eigenfertigung vs. Fremdbezug (Make-or-Buy) mit Unteraufträgen
3. Materialreservierung über mehrere Aufträge
4. Excel-Import von Stücklisten
5. HTTPS über Nginx-Reverse-Proxy
