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

### Demo-Benutzer, Swagger-Client und Token-Laufzeiten (Issue #8)

Umgesetzt im Realm-Import `keycloak/prodflow-realm.json`; geprüft gegen ein Wegwerf-Keycloak 26.4.0
(`scripts/test-realm-import.ps1`, siehe unten).

- **Demo-Benutzer:** `planner` (PLANNER), `purchaser` (PURCHASER) und `admin` (ADMIN), jeweils nur mit ihrer
  Anwendungsrolle. Die Passwörter stehen im Import nur als Platzhalter (`${DEMO_PLANNER_PASSWORD}`,
  `${DEMO_PURCHASER_PASSWORD}`, `${DEMO_ADMIN_PASSWORD}`). Die echten Werte kommen aus der Umgebung des
  Keycloak-Containers (lokal `.env`, auf dem Server die geschützte `.env`) und gehören nie in Git, Logs oder Chat.
  Keycloak 26.4 ersetzt die Platzhalter beim Import (Passwörter und URLs): echte Logins gelingen, die URL-Felder sind aufgelöst.
- **Fehlende Variablen (geprüft, Keycloak 26.4) – wichtig für das Deployment:** Fehlt `PRODFLOW_APP_URL`, bricht Keycloak den Start
  ab („A redirect URI is not a valid URI"); das ist sicher. Fehlt dagegen eine `DEMO_*_PASSWORD`-Variable, importiert Keycloak den
  Realm **ohne Fehler** und speichert den Platzhaltertext (z. B. `${DEMO_PLANNER_PASSWORD}`) als Passwort; ein Login damit gelingt.
  Eine **leere** Variable ist ebenfalls nicht sicher abgesichert: Keycloak startet, legt den Benutzer aber mit einem defekten
  Passwort-Credential an (keine Hash-Daten); kein Login ist möglich (Serverfehler), das ist unbrauchbar, aber kein Fail-Closed.
  Deshalb verlässt sich das Projekt nicht auf Keycloaks Verhalten, sondern prüft die Werte **vor** dem Import (nächster Punkt).
  Zusätzlich prüft `smoke-auth.ps1` pro Benutzer, dass der Platzhaltertext als Passwort **abgelehnt** wird; `test-realm-import.ps1`
  enthält Negativkontrollen für beide Fehlkonfigurationen (nicht gesetzt, leer).
- **Import-Guard (`keycloak/import-guard.sh`):** Ein einmaliger Container (`postgres:16-alpine`, Compose-Dienst
  `keycloak-import-guard`) läuft vor Keycloak und fragt die Keycloak-Datenbank, ob der Realm `prodflow` schon existiert.
  - Realm vorhanden: Keycloak überspringt den Import, der Guard prüft nichts. Routinemäßige Neustarts brauchen die Demo-Passwörter
    nicht, ein bestehender Realm wird nie angefasst.
  - Realm fehlt (leere Datenbank): alle drei `DEMO_*_PASSWORD` müssen gesetzt, nicht leer, ohne `${…}`-Platzhalter, ohne
    Steuerzeichen oder Leerzeichen am Rand, kein Platzhalter-/Offensichtlich-Passwort (`CHANGE_ME`, „password" …), mindestens
    12 Zeichen mit mindestens 6 verschiedenen Zeichen, ohne den Benutzernamen und **paarweise verschieden** sein. Sonst Exit 1,
    Keycloak startet nicht (`depends_on … service_completed_successfully`) und es wird nichts importiert.
  - Unsicherer Zustand (Datenbank nicht erreichbar, Abfrage schlägt fehl): Exit 2, ebenfalls kein Start (Fail-Closed).
  - Ausgaben nennen nur Variablennamen und Gründe, nie Werte. `PRODFLOW_APP_URL` ist kein Geheimnis und hat in Compose den
    Standard `http://localhost:8080`. Auf AWS (Issue #16) gilt für alle vier Variablen zusätzlich `${VAR:?}`.
  - **Grenzen (bewusst dokumentiert):** `docker compose up --no-deps keycloak`, `docker compose restart keycloak` und
    Docker-Neustartrichtlinien starten Keycloak ohne den Guard; auf leerer Datenbank entstünden dann unbrauchbare (nicht
    funktionierende) Credentials, nie ein Platzhalter-Passwort, weil Compose leere statt fehlender Variablen übergibt. Für die
    Produktion (Issue #16) deshalb `${VAR:?}` statt Standardwerten und den Guard als Entrypoint-Vorstufe prüfen. Die Demo-Passwörter
    sind bis zum Entfernen aus `.env` per `docker inspect` sichtbar (wie `KC_BOOTSTRAP_ADMIN_PASSWORD`); sie werden nur beim ersten
    Import gebraucht und können danach aus `.env` gelöscht werden. Der Guard wiederholt die erste Datenbankabfrage bis zu 30 s,
    weil PostgreSQL beim ersten Start kurz nur über den Unix-Socket erreichbar ist; ein Healthcheck mit `-h 127.0.0.1` wäre die
    zusätzliche Compose-seitige Härtung. Längen- und Zeichenprüfung zählen Bytes (ASCII-Passwörter empfohlen). Bei jedem
    Keycloak-Upgrade das Importverhalten mit `test-realm-import.ps1` neu prüfen.
- **Clients:**
  - `prodflow-swagger`: öffentlicher Client für Swagger UI (Authorization Code + PKCE S256; Password Grant, Implicit Flow und
    Service Accounts aus). Redirect-URI `${PRODFLOW_APP_URL}/swagger-ui/oauth2-redirect.html`, Web-Origin `${PRODFLOW_APP_URL}`.
  - `prodflow-web`: unverändert, für das spätere Angular-Frontend reserviert (nur `http://localhost:4200`).
  - Beide Clients liefern im Access Token die Audience `prodflow-api`. `PRODFLOW_APP_URL` ist die öffentliche Basis-URL der
    Anwendung (lokal `http://localhost:8080`, auf AWS die HTTPS-Adresse).
- **Token-Laufzeit:** Realm-Standard 300 s; nur `prodflow-swagger` erhält über das Client-Attribut `access.token.lifespan`
  1800 s (Demo). Gemessen: `exp − iat` = 1800 s bzw. 300 s. Obergrenze bleibt die SSO-Sitzung des Realms.
- **Benutzerwechsel in Swagger UI:** Swagger sendet `prompt=login`. Verifiziert (Keycloak 26.4): Bei aktiver Keycloak-Sitzung
  fragt `prompt=login` nur erneut das Passwort des bisherigen Benutzers ab; der Benutzername ist gesperrt. Ein Wechsel auf
  eine andere Rolle ist so **nicht** möglich. Zwei geprüfte Wege:
  1. **Zweites Browserfenster (privat):** `planner` im normalen, `purchaser` im privaten Fenster; beide Sitzungen laufen unabhängig
     (empfohlen für die Präsentation).
  2. **Bei Keycloak abmelden:** `<Keycloak-URL>/realms/prodflow/protocol/openid-connect/logout?client_id=prodflow-swagger`
     aufrufen, die Abmeldung bestätigen und in Swagger erneut „Authorize" wählen.
  „Logout" in Swagger UI verwirft nur das Token, nicht die Keycloak-Sitzung.
- **Passwort ändern ohne Neuaufbau:** Der Import legt Benutzer nur beim Anlegen des Realms an. Spätere Änderungen am laufenden
  Server mit `kcadm.sh`; Passwörter nie als Argument übergeben, sondern über die Umgebungsvariable `KC_CLI_PASSWORD`
  (Eingabe nicht in Skripte oder Git schreiben, PowerShell-Verlauf nicht speichern):
  ```powershell
  $env:KC_CLI_PASSWORD = '<Admin-Passwort>'
  docker compose exec -e KC_CLI_PASSWORD keycloak /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080 --realm master --user <Admin-Benutzer>
  $env:KC_CLI_PASSWORD = '<neues Passwort>'
  docker compose exec -e KC_CLI_PASSWORD keycloak /opt/keycloak/bin/kcadm.sh set-password -r prodflow --username planner
  Remove-Item env:KC_CLI_PASSWORD
  ```
  Dieser Ablauf (mit `docker exec`) ist im Wegwerf-Keycloak getestet: danach gelingt der Login mit dem neuen Passwort.
- **Automatische Prüfung:**
  - `scripts/test-realm-import.ps1` startet ein Wegwerf-Keycloak (Port 8181, ohne Volume, nur lokal), importiert den Realm mit
    zufällig erzeugten Testpasswörtern, prüft die importierte Konfiguration über die Admin-API und räumt in jedem Fall auf.
  - `scripts/test-import-guard.ps1` prüft den Guard isoliert (Wegwerf-PostgreSQL, kein Keycloak): nicht gesetzt, leer, Platzhalter,
    zu kurz, zu wenige verschiedene Zeichen, doppelte Passwörter, Steuerzeichen, vorhandener/fehlender Realm, unsicherer Zustand;
    außerdem, dass kein Passwortwert ausgegeben wird.
  - `scripts/test-compose-guard.ps1` prüft die Compose-Verdrahtung Ende-zu-Ende in einem eigenen, wegwerfbaren Compose-Projekt
    (Port 8182, eigene Volumes, nie das echte Projekt): ohne/mit schlechten Passwörtern startet Keycloak nicht und importiert
    nichts; mit gültigen Passwörtern gelingt der Import samt echter PKCE-Logins; Neustart und `--force-recreate` ohne Passwörter
    funktionieren, die Passwörter bleiben unverändert.
  - `scripts/smoke-auth.ps1` führt echte Logins aus (Authorization Code + PKCE S256, kein Password Grant) und prüft pro Benutzer
    Rolle, Issuer, Audience, Token-Laufzeit, die CORS-Freigabe des Token-Endpunkts für die App-Origin (Swagger UI holt das Token im
    Browser), die beiden Wege des Benutzerwechsels, die PKCE-Pflicht und die Ablehnung des Platzhaltertexts. Es ist gegen jede
    Umgebung nutzbar (`-KeycloakUrl`, `-RedirectUri`, Passwörter als Umgebungsvariablen), z. B. später gegen AWS (Issue #19).
  - Tokens, Codes, Cookies und Passwörter werden nie ausgegeben.
- **Abnahme lokal (Stand Issue #8):** Authorization Code + PKCE für alle drei Benutzer ist automatisiert gegen ein Wegwerf-Keycloak
  26.4.0 geprüft (Claims, Rollen, Audience, Laufzeiten 1800 s/300 s, CORS, PKCE-Pflicht, Benutzerwechsel über Abmeldung und zweites
  Fenster). Die Rollenregeln (RBAC) sind mit gemockten JWTs getestet (`AuthorizationMatrixTest`, `PurchaseApprovalAuthorizationTest`,
  vollständige Backend-Suite grün). Der lokale Keycloak wurde mit `scripts/provision-demo-realm.ps1` (idempotent, nur
  hinzufügend; getestet mit `scripts/test-realm-catchup.ps1`) nachgezogen und die Swagger-Anmeldung im Browser manuell abgenommen.
  Einschränkung: Swagger-`prompt=login` wechselt den Benutzer **nicht** (siehe oben); der Wechsel gelingt nur über Abmeldung bei
  Keycloak oder ein zweites Fenster.
- **Noch offen:**
  - Der laufende lokale Stack nutzt den Guard erst nach dem nächsten `docker compose up -d` (dabei wird nur `keycloak` neu
    erstellt, weil sich seine Umgebung ändert; der Guard findet den vorhandenen Realm und lässt ihn unberührt). Die Verdrahtung in
    `docker-compose.yml` ist umgesetzt und isoliert getestet (`scripts/test-compose-guard.ps1`, 24/24).
  - Produktion (Issue #16): `${VAR:?}` statt `:-`-Standardwerten, Deployment nur über `compose up -d`, Verify-Stufe mit echten
    Logins für alle drei Benutzer, Healthcheck `pg_isready -h 127.0.0.1` für `keycloak-db`.
  - Echte Token-Aufrufe gegen die Backend-API (401/403/2xx) sind Teil der End-to-End-Abnahme (Issue #19).
  - Hinweis: `provision-demo-realm.ps1` stuft einen Benutzer mit defektem Passwort-Credential (leere Variable bei einem früheren
    Import) als „vorhanden" ein; Folgeaufgabe, kein Teil von Issue #8.

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
- Der Produktionsstapel ist **lokal umgesetzt und getestet** (nächster Abschnitt); ein AWS-Deployment hat noch nicht stattgefunden.

### Produktionsstapel (Issues #14/#16, lokal verifiziert, nicht auf AWS)

`deploy/docker-compose.prod.yml` (ersetzt die frühere Datei mit nur dem Backend), `deploy/Caddyfile`, `deploy/.env.example`,
`deploy/deploy.sh`, `deploy/bootstrap-server.sh`, `scripts/duckdns-update.sh`.

- **Dienste:** `caddy` (einziger Dienst mit öffentlichen Ports 80/443), `backend` (Image aus GHCR, Tag aus `IMAGE_TAG`), `keycloak`
  (`start`, Produktionsmodus), `db`, `keycloak-db`, `keycloak-import-guard`. Speichergrenzen je Container (Caddy 96 MB, Backend 512 MB,
  Keycloak 900 MB, je 256 MB für die Datenbanken).
- **Zwei Hostnamen:** `APP_HOST` (Swagger UI und API) und `AUTH_HOST` (Keycloak), je mit eigenem Zertifikat (Caddy, Let's Encrypt).
  `APP_URL`/`AUTH_URL` sind die vollständigen https-Adressen. Keycloak: `KC_HOSTNAME=<AUTH_URL>`, `KC_PROXY_HEADERS=xforwarded`; der
  Issuer in den Tokens ist damit immer die öffentliche Adresse. Das Backend prüft den Issuer gegen diese Adresse, holt die Schlüssel aber
  intern über `http://keycloak:8080/...`.
- **Pfad-Allowlist für Keycloak (Caddy):** öffentlich nur `/realms/prodflow/*`, `/resources/*`, `/robots.txt`. Admin-Konsole,
  Admin-REST-API, Master-Realm, `/metrics`, `/health` und Umgehungsversuche (`..`, `%2e%2e`, `..%2f`) liefern 404. Die Verwaltung läuft
  über einen SSH-Tunnel auf `127.0.0.1:8180` des Servers (`KC_HOSTNAME_ADMIN=http://localhost:8180`).
- **Backend-Pfade:** `/actuator/health` öffentlich; alle anderen `/actuator/*`-Pfade (auch `/actuator/info`) routet Caddy nicht.
  Swagger UI und `/v3/api-docs` sind als dokumentierte Demo-Ausnahme öffentlich (Entscheidung D-8); die API selbst verlangt Tokens.
- **Pflichtvariablen:** alle Geheimnisse und Adressen mit `${VAR:?}`: Fehlt eine, startet nichts. Der Import-Guard läuft hier mit den
  `:?`-Werten, es gibt keine Standardwerte.
- **Server-`.env`:** wird auf dem Server von `bootstrap-server.sh` mit zufälligen Geheimnissen erzeugt (Rechte 600, nie in Git/Chat/user-data).
- **Deployment-Einheit:** `deploy/deploy.sh sha-<commit>` stellt das Repository auf den Commit, setzt `IMAGE_TAG`, startet den Stapel
  und wartet auf `healthy`; sonst Rückkehr zum vorherigen Tag. Dasselbe Skript nutzt später der Pull-Agent (Issue #18).
- **Speicher (gemessen, lokaler Lauf nach Login-, API- und Neustarttests):** Keycloak ≈ 490 MB, Backend ≈ 305 MB, Datenbanken ≈ 85 MB,
  Caddy ≈ 16 MB, zusammen ≈ 0,9 GB. Eine `t3.small` (2 GB) reicht für den Demolauf voraussichtlich; endgültig nach Messung auf der
  Instanz (`docs/aws-deployment.md`).
- **Automatische Prüfung:** `scripts/test-prod-stack.sh` startet den Stapel als eigenes Compose-Projekt (Port 18443/18181, zufällige Geheimnisse,
  interne CA, Hostnamen `app.prodflow.test`/`auth.prodflow.test` im Docker-Netz) und prüft Pflichtvariablen, Import-Guard, HTTPS, echte
  Logins mit PKCE, Token-Refresh, API 401/200/403, die Pfad-Allowlist, veröffentlichte Ports, Neustart und Geheimnisse in Logs
  (`scripts/smoke-auth.sh`, Bash, auch für die Verify-Stufe auf Linux).
- **Offen/Risiken:** Zertifikate (Let's Encrypt) und DuckDNS sind erst auf AWS prüfbar; Swagger öffentlich; die Demo-Passwörter stehen
  in `docker inspect` (wie das Admin-Passwort); der alte SSH-Deploy-Job im Workflow nutzt die neue Compose-Datei nicht und wird in #18 ersetzt.

## Pipeline: Test → Build → Deploy → Verify (Issue #18, pull-basiert)

Umgesetzt in `.github/workflows/ci-cd.yml`, `deploy/agent.sh`, `deploy/deploy.sh`; lokal getestet, **noch nicht auf AWS**.

1. **Test** (jeder Push/PR): `mvn verify` mit Testcontainers.
2. **Build** (nur `main`, nur bei grünem Test): Image mit dem Commit (`--build-arg GIT_SHA`, Label `org.opencontainers.image.revision`,
   `GET /version`) nach GHCR als `sha-<commit>`, `latest` und dem Zeiger **`prod`**. `concurrency` bricht ältere Läufe ab, damit nur der
   neueste `main`-Stand ausgerollt wird.
3. **Deploy (pull-basiert, ohne eingehendes SSH):** Ein systemd-Timer auf dem Server startet jede Minute `deploy/agent.sh`. Der Agent
   zieht `prod`, liest die Revision aus dem Label und ruft bei einer Abweichung `deploy/deploy.sh sha-<commit>` auf: Repository auf den
   Commit stellen, `IMAGE_TAG` setzen, Stapel starten, auf `healthy` warten (Standard 240 s), sonst **automatische Rückkehr** zum
   vorherigen Tag. Ein fehlgeschlagener Tag wird gemerkt und nicht erneut versucht, bis ein neueres Image erscheint. Beide Skripte
   laufen vollständig in `main()`, weil der Checkout sie während der Ausführung ersetzt.
4. **Verify** (`verify`-Job): fragt die öffentliche Adresse (Repository-Variable `PROD_APP_URL`, kein Geheimnis) bis zu 15 Minuten nach
   `/version`, bis die Revision **dieser** Commit ist, und prüft `/actuator/health`. Sonst ist die Pipeline rot. Ist die Variable nicht
   gesetzt, meldet der Job „nicht ausgeführt" (Warnung), er besteht nicht stillschweigend.
- **Sicherheit:** Der Server nimmt keine eingehenden Verwaltungsverbindungen für Deployments an (kein SSH-Deploy); der Agent zieht nur aus dem eigenen GHCR-Paket. Vertrauensanker ist
  das Repository (`main`) und die CI; der Agent läuft als root (Docker) auf einer wegwerfbaren Demo-Instanz.
- **Rollback von Hand:** `touch /var/lib/prodflow/hold` (pausiert den Agenten), dann `deploy/deploy.sh sha-<früherer Commit>`; fortsetzen mit
  `rm /var/lib/prodflow/hold`. Ohne Pause würde der Agent innerhalb einer Minute wieder das Image des Zeigers `prod` ausrollen.
- **Test:** `scripts/test-deploy-agent.sh` (20 Fälle mit Attrappen für `docker`/`git`: keine Änderung, Deploy, Rollback, Fehlermerker,
  Registry-Fehler, ungültige Eingaben, Pausendatei, Ersetzen der Skripte während des Laufs).
- **Offen:** Ein echter Lauf auf GitHub (Push nötig, Freigabe) und auf AWS; `PROD_APP_URL` setzen; GHCR-Zeiger-Tagging mit `GITHUB_TOKEN`
  ist in `docker/build-push-action` üblich, aber hier noch nicht gelaufen.

## Deployment-Einrichtung

> **Hinweis:** Diese Anleitung ist der ursprüngliche Plan (ADR #11) und **überholt** durch die Abschnitte „Produktionsstapel" und
> „Pipeline" sowie `docs/aws-deployment.md` (kein SSH-Deploy mehr, kein RDS vorgesehen); sie wurde nie ausgeführt. Mit ADR #15 sind Teile überholt: zusätzlich Port 443 für Caddy, Keycloak und
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
