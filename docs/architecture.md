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
| 11 | **AWS EC2**, Datenbank ab Tag 7 auf **RDS** | EC2 ist transparent und gut erklärbar; RDS übernimmt Backups. | ECS/Fargate (mehr Konfiguration) |
| 12 | **Kein Login im MVP** | Spring Security + JWT kostet ~1 Tag; nur wenn Zeit bleibt. | — |
| 13 | **Fehlerformat RFC 7807** (`ProblemDetail`) über `@RestControllerAdvice` | Ein einheitliches Fehlerformat für das Frontend. | — |

## Bewusste Grenzen des MVP

- **Keine Reservierung:** Zwei freigegebene Aufträge können denselben Bestand „sehen".
  Beim Abschließen wird der Bestand erneut geprüft, er kann also nie negativ werden
  (Test `competingOrdersCannotDriveStockNegative`). Saubere Lösung: Reservierungstabelle (Stretch Goal).
- **Eine Stücklistenebene.**
- **`open-in-view: true`** für einfaches DTO-Mapping im Controller – technische Schuld, die vor Projektende entfernt werden kann.

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

## Deployment-Einrichtung

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
