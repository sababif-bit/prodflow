# Architekturentscheidungen

Kurz und begründet – jede Entscheidung muss in der Präsentation erklärbar sein.

| # | Entscheidung | Begründung | Verworfen |
|---|---|---|---|
| 1 | **Monolith**: ein Spring-Boot-Backend, ein Angular-Frontend | Ein Entwickler, 12 Tage. Microservices würden nur Betriebsaufwand erzeugen. | Microservices |
| 2 | **Java 21 / Spring Boot** | Eigene Berufserfahrung → Zeit fließt in Docker, CI/CD und Cloud statt ins Framework-Lernen. | FastAPI |
| 3 | **PostgreSQL + Flyway** | Aufträge, Stücklisten und Bestände sind relational. Flyway versioniert das Schema; Hibernate prüft es nur (`ddl-auto: validate`). | MongoDB, `ddl-auto: update` |
| 4 | **Einheitliche Tabelle `item`**, Stückliste als selbstreferenzierende Tabelle `bom_line` (Eltern-Artikel → Kind-Artikel) | MVP löst eine Ebene auf, mehrstufige Stücklisten brauchen später nur Rekursion im Service, keine Migration. | Getrennte Tabellen `product`/`material` |
| 5 | **Keine Doppel-Bestellanforderungen**: neue Anforderung nur für die Fehlmenge, die nicht schon durch offene/genehmigte Anforderungen desselben Auftrags gedeckt ist | Materialprüfung kann beliebig oft laufen (idempotent). | — |
| 6 | **Optimistic Locking** (`@Version`) auf `item` | Zwei gleichzeitige Bestandsbuchungen überschreiben sich nicht still. | Pessimistische Sperren |
| 7 | **Tests mit Testcontainers** | Echtes PostgreSQL wie in Produktion; keine H2-Dialekt-Überraschungen. | H2 |
| 8 | **Single-Tenant-Deployment**: ein Image, je Kunde eine eigene Installation mit eigener DB und `.env` | Einfach, sichere Datentrennung, Kunden können verschiedene Versionen fahren. | Multi-Tenant in einer DB, Kubernetes |
| 9 | **Images mit Commit-Tag** (`sha-xxxxxxx`) in GHCR | Jede Version reproduzierbar, Rollback = vorherigen Tag starten. | Nur `latest` |
| 10 | **GitHub Actions**: Test → Build → Deploy, Deploy nur von `main` nach grünen Tests | Ein Werkzeug für Code, Issues und Pipeline. | Jenkins |
| 11 | **AWS EC2**, Datenbank ab Tag 7 auf **RDS** *(teilweise abgelöst durch #15 – EC2 bleibt, RDS ist nicht entschieden)* | EC2 ist transparent und gut erklärbar; RDS übernimmt Backups. | ECS/Fargate (mehr Konfiguration) |
| 12 | **Kein Login im MVP** *(abgelöst durch #14)* | Spring Security + JWT kostet ~1 Tag; nur wenn Zeit bleibt. | — |
| 13 | **Fehlerformat RFC 7807** (`ProblemDetail`) über `@RestControllerAdvice` | Ein einheitliches Fehlerformat für das Frontend. | — |
| 14 | **Keycloak + OAuth2/JWT**: Backend ist reiner OAuth2 Resource Server, Rollen ADMIN, PLANNER, PURCHASER als Keycloak-Realm-Rollen *(umgesetzt, PR #2 und #4)* | Login, Passwörter und Tokens übernimmt ein Standardprodukt; das Backend prüft nur Signatur, Ablauf, Issuer und Audience. Rollen setzen die Funktionstrennung Planung/Einkauf durch. | Eigene Benutzerverwaltung, Basic Auth, Session-Login im Backend |
| 15 | **Geplantes AWS-Deployment: eine EC2-Instanz mit Docker Compose** (PostgreSQL, Keycloak, Backend, Caddy für HTTPS) *(Vorschlag, noch nicht umgesetzt)* | Gleiches Compose-Modell wie lokal, ein Server, wenig Kosten; Caddy holt TLS-Zertifikate automatisch. | RDS und Nginx *(nicht entschieden, kein Bestandteil des aktuellen Vorschlags)* |

## Bewusste Grenzen des MVP

- **Keine Reservierung:** Zwei freigegebene Aufträge können denselben Bestand „sehen".
  Beim Abschließen wird der Bestand erneut geprüft, er kann also nie negativ werden
  (Test `competingOrdersCannotDriveStockNegative`). Saubere Lösung: Reservierungstabelle (Stretch Goal).
- **Eine Stücklistenebene.**
- **`open-in-view: true`** für einfaches DTO-Mapping im Controller – technische Schuld, die vor Projektende entfernt werden kann.
- **Swagger UI ist ohne Login erreichbar** – für die Demo gewollt, vor einem öffentlichen Deployment abschalten.

## Datenmodell

```
item (id, code, name, unit, type MATERIAL|PRODUCT, qty_on_hand, version)
  ▲  ▲
  │  └── bom_line (parent_item_id, child_item_id, qty_per)
  │
  ├── production_order (order_no, item_id, quantity, due_date, status)
  │        CREATED → WAITING_MATERIAL → RELEASED → DONE
  │
  └── purchase_request (item_id, production_order_id, quantity, status)
           OPEN → APPROVED → RECEIVED
```

## Sicherheit und Berechtigungen

Umgesetzt (ADR #14). Das Backend meldet niemanden an, es prüft nur Access Tokens von Keycloak:

- **Token-Prüfung:** Signatur über die JWK-Set-URL des Realms `prodflow`, Ablauf/`nbf`,
  exakter Issuer, Audience muss `prodflow-api` enthalten. Falsche Konfiguration → jeder
  Aufruf wird mit 401 abgelehnt (fail closed).
- **Rollen:** aus dem Claim `realm_access.roles`; nur die exakten Namen `ADMIN`, `PLANNER`,
  `PURCHASER` zählen, alle anderen Rollen werden ignoriert.
- **Zustandslos:** keine Session, keine Cookies; Tokens kommen ausschließlich als Bearer-Token
  im `Authorization`-Header. Für diese zustandslose Bearer-Token-API ist der CSRF-Schutz
  von Spring Security deaktiviert.
- **Keycloak-Clients:** `prodflow-api` (Audience der API) und `prodflow-web`
  (öffentlicher Client mit PKCE S256, vorbereitet für das Frontend).

Berechtigungsmatrix (Quelle: `backend/src/main/java/de/prodflow/security/SecurityConfig.java`):

| Endpunkt | Öffentlich | ADMIN | PLANNER | PURCHASER |
|---|:-:|:-:|:-:|:-:|
| `GET /actuator/health`, Swagger UI, `/v3/api-docs` | ✓ | ✓ | ✓ | ✓ |
| `GET /actuator/info` | | ✓ | | |
| `POST /api/items/{id}/stock` (Bestandskorrektur) | | ✓ | | |
| `GET /api/items`, `/api/items/{id}`, `/api/items/{id}/bom` | | ✓ | ✓ | ✓ |
| `POST /api/items`, `PUT /api/items/{id}`, `POST`/`DELETE` Stückliste | | ✓ | ✓ | |
| `GET /api/production-orders`, `/api/production-orders/{id}` | | ✓ | ✓ | ✓ |
| `POST` Auftrag anlegen, `check-material`, `complete` | | ✓ | ✓ | |
| `GET /api/purchase-requests` | | ✓ | ✓ | ✓ |
| `POST /api/purchase-requests/{id}/approve`, `/receive` | | ✓ | | ✓ |

Alle Anfragen, die keiner dieser Regeln entsprechen, werden standardmäßig verweigert
(deny by default) – unabhängig von der Rolle.

**Funktionstrennung:** Wer Aufträge plant (PLANNER), kann keine Bestellanforderungen
genehmigen oder Wareneingänge buchen – das darf nur der Einkauf (PURCHASER) oder ADMIN.
Bestandskorrekturen sind ADMIN vorbehalten.

Offen: Swagger UI und API-Doku in Produktion abschalten.

## Laufzeitarchitektur

### Aktuell umgesetzt: lokal mit Docker Compose (`docker-compose.yml`)

```
Client (Bearer Token) ──► backend :8080 ──► db (PostgreSQL 16)
                              │
                              └─ JWKs intern über http://keycloak:8080
Browser / Token-Abruf ──► keycloak :8180 ──► keycloak-db (PostgreSQL 16)
```

- Ports nur auf `127.0.0.1` gebunden; Realm wird aus `keycloak/prodflow-realm.json` importiert.
- Issuer ist die öffentliche URL `http://localhost:8180/realms/prodflow`, die Schlüssel
  holt das Backend intern über den Container-Namen.
- CI/CD: Tests und Image-Build nach GHCR laufen; der Deploy-Job überspringt seine
  Schritte, solange `EC2_HOST` nicht gesetzt ist.

### Vorschlag: AWS-Deployment (ADR #15, noch nicht umgesetzt)

```
Internet ──443──► Caddy (HTTPS, Let's-Encrypt-Zertifikate)
                    ├──► backend ──► PostgreSQL (Container)
                    └──► keycloak ──► PostgreSQL (Container)
        alles auf einer EC2-Instanz mit Docker Compose
```

- Nicht entschieden: RDS statt PostgreSQL-Container, Nginx statt Caddy.
- `deploy/docker-compose.prod.yml` enthält derzeit nur das Backend auf Port 80 und
  muss für diesen Vorschlag erweitert werden.
- Offen: Keycloak-Produktionsmodus, öffentliche Issuer-URL, Domain/DNS, Backups der
  Datenbank-Volumes.

## Deployment-Einrichtung

> **Hinweis:** Diese Anleitung ist der ursprüngliche Plan (ADR #11) und wurde noch nicht
> ausgeführt. Mit ADR #15 sind Teile überholt: zusätzlich Port 443 für Caddy, Keycloak und
> PostgreSQL als Container auf der EC2-Instanz; der Wechsel auf RDS (Schritt 4) ist nicht
> entschieden.

Einmalig, ca. 1 Stunde (Tag 2):

1. **AWS Budget Alert** auf 5 € anlegen (Billing → Budgets).
2. **EC2** `t3.micro` (Ubuntu 24.04, eu-central-1) starten. Security Group: Port 22 nur von der eigenen IP, Port 80 offen.
3. Auf dem Server Docker installieren und `/opt/prodflow` anlegen:
   ```bash
   curl -fsSL https://get.docker.com | sh
   sudo usermod -aG docker ubuntu
   sudo mkdir -p /opt/prodflow && sudo chown ubuntu /opt/prodflow
   ```
4. `deploy/.env.example` als `/opt/prodflow/.env` anlegen und ausfüllen
   (`GITHUB_REPOSITORY` in Kleinbuchstaben). Bis Tag 7 kann die DB als zweiter
   Container auf EC2 laufen, danach RDS.
5. GHCR-Paket nach dem ersten Build auf **public** stellen – oder auf dem Server
   `docker login ghcr.io` mit einem Token (`read:packages`).
6. GitHub → Settings → Secrets → Actions: `EC2_HOST`, `EC2_USER` (`ubuntu`), `EC2_SSH_KEY` (privater Schlüssel).
7. Branch-Schutz für `main`: Merge nur mit grünem `test`-Job.
