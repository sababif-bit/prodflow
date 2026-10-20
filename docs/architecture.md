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
| 10 | **GitHub Actions**: Test → Build → Deploy, Deploy nur von `main` nach grünen Tests *(Deploy-Stufe abgelöst durch #18)* | Ein Werkzeug für Code, Issues und Pipeline. | Jenkins |
| 11 | **AWS EC2**, Datenbank ab Tag 7 auf **RDS** *(teilweise abgelöst durch #15/#17 – EC2 bleibt, RDS ist nicht vorgesehen)* | EC2 ist transparent und gut erklärbar; RDS übernimmt Backups. | ECS/Fargate (mehr Konfiguration) |
| 12 | **Kein Login im MVP** *(abgelöst durch #14)* | Spring Security + JWT kostet ~1 Tag; nur wenn Zeit bleibt. | — |
| 13 | **Fehlerformat RFC 7807** (`ProblemDetail`) über `@RestControllerAdvice` | Ein einheitliches Fehlerformat für das Frontend. | — |
| 14 | **Keycloak + OAuth2/JWT**: Backend ist reiner OAuth2 Resource Server, Rollen ADMIN, PLANNER, PURCHASER als Keycloak-Realm-Rollen *(umgesetzt, PR #2 und #4)* | Login, Passwörter und Tokens übernimmt ein Standardprodukt; das Backend prüft nur Signatur, Ablauf, Issuer und Audience. Rollen setzen die Funktionstrennung Planung/Einkauf durch. | Eigene Benutzerverwaltung, Basic Auth, Session-Login im Backend |
| 15 | **Geplantes AWS-Deployment: eine EC2-Instanz mit Docker Compose** (PostgreSQL, Keycloak, Backend, Caddy für HTTPS) *(umgesetzt und verfeinert als #17)* | Gleiches Compose-Modell wie lokal, ein Server, wenig Kosten; Caddy holt TLS-Zertifikate automatisch. | RDS und Nginx *(nicht entschieden, kein Bestandteil des aktuellen Vorschlags)* |
| 16 | **Swagger UI als erster Demo-Client; Angular zunächst zurückgestellt** *(umgesetzt, Issue #8, PR #26; der Angular-Teil ist überholt durch #20–#23)* | Swagger UI meldet sich per Authorization Code + PKCE bei Keycloak an (öffentlicher Client `prodflow-swagger`, Demo-Benutzer `planner`, `purchaser`, `admin`) und macht die Rollen ohne Frontend vorführbar. Swagger UI und `/v3/api-docs` bleiben **bewusst öffentlich** (sie zeigen nur die API-Beschreibung, keine Daten; temporäre Demo-Ausnahme, Entscheidung D-8); die API selbst verlangt Tokens. | Eigenes Login-Formular, Passwort-Grant (abgeschaltet), Swagger ohne Anmeldung |
| 17 | **Endgültiges AWS-Deployment: eine EC2-Instanz (Ubuntu 24.04, `t3.small`, laut Planung eu-central-1) mit Docker Compose** – Caddy (HTTPS, Let's Encrypt, zwei DuckDNS-Namen), Backend, Keycloak, zwei PostgreSQL-Container *(umgesetzt, seit 18.10.2026 in Betrieb und verifiziert; ersetzt den Vorschlag #15)* | Ein Server, geringe Kosten (Budget 15 $/Monat), dasselbe Compose-Modell wie lokal, Zertifikate automatisch. Gemessen: im lokalen Test des Produktionsstapels 952 MiB Spitze aller Container (Limits zusammen 1760 MiB); auf der Instanz nach 30 Minuten Betrieb rund 1,3 GB belegt, 560 MB verfügbar, 111 MB Swap von 2 GiB. Öffentlich nur 80/443, SSH nur von der eigenen IP, Keycloak-Admin nur über einen SSH-Tunnel. | RDS (Kosten, kein Lerngewinn), Nginx (Caddy ist kürzer), ECS/EKS (Betriebsaufwand) |
| 18 | **Pull-basiertes Deployment**: GitHub Actions testet, baut und veröffentlicht das Image (`sha-<7>`, `latest`, Zeiger `prod`); ein systemd-Agent auf dem Server prüft jede Minute den Zeiger, deployt mit Gesundheits- **und** Anwendungs-Gate, rollt bei Fehlern zurück und merkt sich den gescheiterten Tag; der `verify`-Job prüft von außen *(umgesetzt, Issue #18, PR #29; Anwendungs-Gate und Rollback-Schalter seit 20.10.2026)* | Kein eingehender SSH-Zugang für die CI und kein Server-Schlüssel in GitHub; der Server bestimmt den Zeitpunkt; Pause per Hold-Datei; Rollback gegen echte Container getestet (`scripts/test-deploy-gate.sh`). Grenzen: kein Zero-Downtime (beobachtet etwa 27 s), Caddy wird vom Gate nicht geprüft (nur extern). | SSH-Deploy aus der Pipeline, Watchtower o. Ä. |
| 19 | **Geheimnisse-Strategie**: Alle Geheimnisse entstehen zufällig **auf dem Server** (`deploy/.env`, Rechte 600), nie in Git, Chat, `user-data` oder Logs; Compose verlangt jede Variable mit `${VAR:?}`; GitHub kennt nur die nicht geheime Variable `PROD_APP_URL`; die öffentlichen Clients (PKCE) brauchen kein Client-Geheimnis *(umgesetzt, Issues #14/#16/#17)* | Begrenzt den Schaden bei Fehlern; die Skripte geben nie Werte aus (getestet: kein Geheimnis in den Container-Logs). Bekannte Grenzen: Passwörter erscheinen in `docker inspect` der Container (nur für root lesbar); die Demo-Passwörter bleiben auf dem Server lesbar; das DuckDNS-Token liegt in der `.env`. | AWS Secrets Manager/SSM (Kosten, Aufwand für die Demo), Geheimnisse als GitHub Secrets |
| 20 | **Frontend: Angular 21 + PrimeNG 21 (MIT, exakt gepinnt)**, eigenständig unter `frontend/` *(umgesetzt; seit 20.10.2026 in Produktion, Details `docs/frontend-architecture.md`)* | Standalone-Komponenten, Signals und zoneless; PrimeNG 20/21 sind MIT-lizenziert, 22.x steht unter der PrimeUI-Lizenz (Schlüssel, Erneuerung, Hinweispflicht). Das Frontend bleibt unabhängig wartbar (eigene Abhängigkeiten, Tests, Lint). | PrimeNG 22 (Lizenz), React/Vue (Kenntnisse, Vorgabe des Moduls) |
| 21 | **Die kompilierte SPA liegt im Backend-Image** (Spring Boot liefert sie same-origin aus; ein Image, ein Tag) *(umgesetzt; seit 20.10.2026 in Produktion)* | Atomares Deployment und Rollback über den bestehenden Pull-Agenten, kein CORS, kein zweites Artefakt, kein Versionsversatz zwischen Oberfläche und API. Der Build-Kontext ist das Repository-Wurzelverzeichnis (`backend/Dockerfile`, Stufe `frontend` → `build` → Laufzeit). | Caddy liefert die Dateien (zweites Image/Volume, Agent und CI müssten zwei Artefakte kennen), eigener Webserver-Container |
| 22 | **Laufzeitkonfiguration über `GET /config.json`, vom Backend aus dem Issuer abgeleitet; Tokens nur im Speicher; Authorization Code + PKCE (S256)** *(umgesetzt; seit 20.10.2026 in Produktion)* | Die kompilierten Dateien enthalten keinen umgebungsspezifischen Wert (kein `localhost` in Produktion), und das Frontend kann nie auf einen anderen Identity Provider zeigen als der, dem das Backend vertraut. Der öffentliche Client `prodflow-web` braucht kein Geheimnis. | Konfiguration im Build (pro Umgebung ein Build), Tokens in `localStorage` (XSS), Implicit Flow |
| 23 | **Content-Security-Policy und Cache-Header im Caddy**; schmaler öffentlicher GET-Zugriff nur für die Dateien und Routen der SPA (Deny-by-default bleibt) *(umgesetzt; im Browser gegen Caddy getestet, seit 20.10.2026 in Produktion verifiziert)* | Die SPA darf nur eigene Dateien laden und nur den Anmeldeserver kontaktieren; gehashte Bundles werden ein Jahr gecacht, `index.html` und `config.json` nie. `style-src` braucht `'unsafe-inline'` (PrimeNG setzt Styles zur Laufzeit), Skripte bleiben strikt `'self'`. Swagger UI erhält als Demo-Ausnahme eine eigene Policy. | CSP nur im Backend (Spring), Nonce-basierte Styles (PrimeNG-Anpassung nötig) |

> **Nummerierung:** #16–#19 sind laut GitHub Issue #23 für Swagger/Demo-Client, AWS-Deployment, pull-basiertes Deployment und Geheimnisse reserviert. Die Frontend-Entscheidungen stehen deshalb als **#20–#23**.
> GitHub Issue #33 und PR #34 nennen sie noch „ADR #16–#19“ (Stand der Veröffentlichung); maßgeblich ist diese Tabelle.

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
- CI/CD: Lokal wird nichts ausgeliefert. Die Pipeline (Abschnitt „Pipeline“) testet, baut das Image und veröffentlicht es in GHCR; der Server holt es sich selbst.

### AWS-Deployment (ADR #15, umgesetzt als ADR #17)

```
Internet ──443──► Caddy (HTTPS, Let's-Encrypt-Zertifikate)
                    ├──► backend ──► PostgreSQL (Container)
                    └──► keycloak ──► PostgreSQL (Container)
        alles auf einer EC2-Instanz mit Docker Compose
```

- Entschieden (ADR #17): PostgreSQL als Container und Caddy als Reverse Proxy; RDS und Nginx sind nicht vorgesehen.
- Der Produktionsstapel (nächster Abschnitt) läuft seit dem 18.10.2026 auf AWS; Stand 20.10.2026: Revision `b509944` (Image `sha-b509944`), automatische Auslieferung aktiv.

### Produktionsstapel (Issues #14/#16/#17, lokal verifiziert und auf AWS in Betrieb)

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
- **Anwendung (SPA, ADR #20–#23):** `APP_HOST` liefert auch die Angular-Oberfläche (aus dem Backend-Image). Caddy setzt dort die CSP (`script-src 'self'`, `connect-src` nur `'self'` und der Anmeldeserver, `frame-ancestors 'none'`), `Permissions-Policy` und für gehashte Bundles `Cache-Control: public, max-age=31536000, immutable`; `index.html` und `config.json` bleiben nicht cachebar (Spring Security). Der Angular-Build erzeugt dafür keine Inline-Skripte (`optimization.styles.inlineCritical: false`). Da die Caddyfile eine einzelne Bind-Mount-Datei ist und `git checkout` sie ersetzt, trägt der Caddy-Dienst `RELEASE_TAG=${IMAGE_TAG}`: Jede Version erzeugt den Container neu und lädt so die Caddyfile des Releases.
- **Backend-Pfade:** `/actuator/health` öffentlich; alle anderen `/actuator/*`-Pfade (auch `/actuator/info`) routet Caddy nicht.
  Swagger UI und `/v3/api-docs` sind als dokumentierte Demo-Ausnahme öffentlich (Entscheidung D-8); die API selbst verlangt Tokens.
- **Pflichtvariablen:** alle Geheimnisse und Adressen mit `${VAR:?}`: Fehlt eine, startet nichts. Der Import-Guard läuft hier mit den
  `:?`-Werten, es gibt keine Standardwerte.
- **Server-`.env`:** wird auf dem Server von `bootstrap-server.sh` mit zufälligen Geheimnissen erzeugt (Rechte 600, nie in Git/Chat/user-data).
- **Deployment-Einheit:** `deploy/deploy.sh sha-<commit>` stellt das Repository auf den Commit, setzt `IMAGE_TAG`, startet den Stapel
  und wartet auf `healthy`; sonst Rückkehr zum vorherigen Tag. Dasselbe Skript nutzt der Pull-Agent (Issue #18).
- **Speicher (gemessen, lokaler Lauf nach Login-, API- und Neustarttests):** Keycloak ≈ 490 MB, Backend ≈ 305 MB, Datenbanken ≈ 85 MB,
  Caddy ≈ 16 MB, zusammen ≈ 0,9 GB (Lauf mit SPA-Image: Keycloak 508 MB, Backend 314 MB, Datenbanken 77 MB, Caddy 53 MB, Summe der Einzelspitzen 952 MB). Eine `t3.small` (2 GB) reicht für den Demolauf voraussichtlich; endgültig nach Messung auf der
  Instanz (`docs/aws-deployment.md`).
- **Automatische Prüfung:** `scripts/test-prod-stack.sh` startet den Stapel als eigenes Compose-Projekt (Port 18443/18181, zufällige Geheimnisse,
  interne CA, Hostnamen `app.prodflow.test`/`auth.prodflow.test` im Docker-Netz) und prüft Pflichtvariablen, Import-Guard, HTTPS, echte
  Logins mit PKCE, Token-Refresh, API 401/200/403, die Pfad-Allowlist, veröffentlichte Ports, Neustart und Geheimnisse in Logs
  (`scripts/smoke-auth.sh`, Bash, auch für die Verify-Stufe auf Linux), außerdem `scripts/verify-deployment.sh` (Oberfläche, Laufzeitkonfiguration, API ohne Token, Header) und einen Browsertest durch Caddy (Playwright: Anmeldung, alle Seiten, Neuladen einer Unterseite, Abmelden, Swagger, keine CSP-Verstöße).
- **Auf AWS verifiziert (20.10.2026):** echte Let's-Encrypt-Zertifikate für beide Namen (gültig bis 16.01.2027, TLS 1.3, HTTP leitet mit 308 auf HTTPS), `verify-deployment.sh` 41/41, `smoke-auth.sh` 38/38, 30-minütige Beobachtung ohne Neustart, OOM oder Fehler im Backend.
- **Risiken/Grenzen:** Swagger bleibt öffentlich (Demo-Ausnahme, ADR #16); die Demo-Passwörter stehen in `docker inspect` (wie das Admin-Passwort); keine Backups (Issue #20), kein Infrastruktur-Code (die Instanz wurde von Hand angelegt, `bootstrap-server.sh` richtet sie ein), kein Alarmsystem; der Wiederaufbau wurde nicht geübt (Issue #22).

## Pipeline: Test → Build → Deploy → Verify (Issue #18, pull-basiert)

Umgesetzt in `.github/workflows/ci-cd.yml`, `deploy/agent.sh`, `deploy/deploy.sh` (ADR #18); lokal getestet und auf AWS in Betrieb. Die Auslieferung von `b509944` am 20.10.2026 lief kontrolliert von Hand (Agent pausiert), danach war der `verify`-Job grün.

1. **Test** (jeder Push/PR): `mvn verify` mit Testcontainers; **Frontend** (`npm ci`, ESLint, Unit-Tests, Produktions-Build); **Ops** (`scripts/test-deploy-agent.sh`, `scripts/test-caddyfile.sh`).
2. **Build** (nur `main`, nur wenn Test, Frontend und Ops grün sind; Kontext = Repository-Wurzel, `backend/Dockerfile` baut Angular und Backend in ein Image): Image mit dem Commit (`--build-arg GIT_SHA`, Label `org.opencontainers.image.revision`,
   `GET /version`) nach GHCR als `sha-<commit>`, `latest` und dem Zeiger **`prod`**. `concurrency` bricht ältere Läufe ab, damit nur der
   neueste `main`-Stand ausgerollt wird.
3. **Deploy (pull-basiert, ohne eingehendes SSH):** Ein systemd-Timer auf dem Server startet jede Minute `deploy/agent.sh`. Der Agent
   zieht `prod`, liest die Revision aus dem Label und ruft bei einer Abweichung `deploy/deploy.sh sha-<commit>` auf: Repository auf den
   Commit stellen, `IMAGE_TAG` setzen, Stapel starten, auf `healthy` warten (Standard 240 s), sonst **automatische Rückkehr** zum
   vorherigen Tag. Gesund allein genügt nicht: `deploy.sh` prüft im Backend-Container (`verify_app`), dass `GET /` die Oberfläche liefert, `/config.json` auf einen https-Anmeldeserver zeigt und `/api/items` ohne Token 401 liefert – sonst ebenfalls Rückkehr. (Die erste Auslieferung dieser Prüfung läuft noch mit dem alten `deploy.sh` des Servers; danach gilt sie.) Ein fehlgeschlagener Tag wird gemerkt und nicht erneut versucht, bis ein neueres Image erscheint. Beide Skripte
   laufen vollständig in `main()`, weil der Checkout sie während der Ausführung ersetzt.
4. **Verify** (`verify`-Job): fragt die öffentliche Adresse (Repository-Variable `PROD_APP_URL`, kein Geheimnis) bis zu 15 Minuten nach
   `/version`, bis die Revision **dieser** Commit ist, und prüft `/actuator/health`. Danach ruft der Job `scripts/verify-deployment.sh` auf (Oberfläche, Deep Links, `/config.json`, API ohne Token 401, Actuator, CSP/Cache/HSTS-Header). Sonst ist die Pipeline rot. Ist die Variable nicht
   gesetzt, meldet der Job „nicht ausgeführt" (Warnung), er besteht nicht stillschweigend.
- **Sicherheit:** Der Server nimmt keine eingehenden Verwaltungsverbindungen für Deployments an (kein SSH-Deploy); der Agent zieht nur aus dem eigenen GHCR-Paket. Vertrauensanker ist
  das Repository (`main`) und die CI; der Agent läuft als root (Docker) auf einer wegwerfbaren Demo-Instanz.
- **Pausieren (`hold`):** Nur `agent.sh` prüft `/var/lib/prodflow/hold`, und zwar einmal beim Start eines Laufs (ein bereits laufender Lauf wird nicht unterbrochen); `deploy.sh` ignoriert sie. Ein Handlauf von `deploy.sh` nimmt die Sperre des Agenten nicht
  selbst, deshalb: `sudo flock -n -E 99 /var/lib/prodflow/agent.lock bash deploy.sh sha-<commit>` (99 = Agent läuft).
- **Rollback von Hand:** `touch /var/lib/prodflow/hold`, dann wie oben `deploy.sh sha-<früherer Commit>`; fortsetzen mit `rm /var/lib/prodflow/hold`. Ohne Pause würde der Agent innerhalb einer Minute wieder das Image des Zeigers `prod` ausrollen.
  Führt das frühere Release **keine Oberfläche** (z. B. `sha-fb08e68`), lehnt das Anwendungs-Gate es ab und stellt das neue wieder her; dann `DEPLOY_ROLLBACK_TO_BACKEND_ONLY=1` setzen (überspringt nur die Prüfung von `/` und `/config.json`, mit Warnung; Health und API-401 bleiben).
  Alternative ohne Schalter: erst `git checkout --detach <früherer Commit>` auf dem Server, dann dessen `deploy.sh`.
- **Test:** `scripts/test-deploy-gate.sh` führt das echte `deploy.sh` gegen echte Container aus (Gate, Override, Rollback mit neuem und altem Skript, Caddy-Neuerzeugung); `scripts/test-deploy-agent.sh` (42 Fälle mit Attrappen für `docker`/`git`: keine Änderung, Deploy, Rollback, Fehlermerker,
  Registry-Fehler, ungültige Eingaben, Pausendatei, Ersetzen der Skripte während des Laufs).
- **Offen:** Branch-Schutz für `main` (Issue #15), Rückspielübung und Backups (Issues #20/#22). `PROD_APP_URL` ist als Repository-Variable gesetzt; das Tagging des Zeigers `prod` mit `GITHUB_TOKEN` läuft (Image `sha-b509944`, `latest`, `prod` mit demselben Digest).

## Demo-Daten zurücksetzen und Workflow-Prüfung (Issues #9/#19)

`scripts/reset-demo-data.sh` setzt **nur die Anwendungsdatenbank** auf den bekannten Ausgangszustand zurück (lokal und auf dem Server, Bash + Docker):
in **einer** Transaktion werden `item`, `bom_line`, `production_order` und `purchase_request` geleert (Identitäten beginnen wieder bei 1) und
`backend/src/main/resources/db/demo/V100__demo_data.sql` (dieselbe Datei, die Flyway im Profil `demo` lädt = einzige Quelle) geladen; danach prüft das Skript
in der Transaktion den Ausgangszustand (MR-200 0, SC-M8 25, PL-ST3 30, PR-40 50, BR-L60 100, 4 Stücklistenzeilen, keine Aufträge/Bestellanforderungen) und
bricht bei Abweichung ab. Der nächste Auftrag heißt wieder `FA-00001`.

- **Sicherungen vor jeder Änderung (Abbruch mit Exit 2):** Marker `PRODFLOW_DEMO_RESET=allowed` in der angegebenen Umgebungsdatei (ein Spring-Profil reicht nicht);
  Compose-Projekt ausdrücklich angegeben; Dienst genau `db` (`keycloak-db` wird abgelehnt); Datenbankname genau `prodflow` (Kommandozeile, Container, `current_database()`);
  genau ein laufender Container; Schema-Fingerabdruck (Anwendungstabellen vorhanden, **keine** Keycloak-Tabellen, Flyway-Versionen 1 und 100).
- **Bedienung:** `--dry-run` zeigt Ziel und Plan ohne Änderung; ohne `--yes` wird nichts ausgeführt (Exit 3). Keine Geheimnisse werden gelesen oder ausgegeben (SQL läuft im Container über den lokalen Socket); Keycloak wird nie angefasst.
- **Lokal:** `PRODFLOW_DEMO_RESET=allowed` in die lokale `.env` eintragen (nur der Name), dann `scripts/reset-demo-data.sh --project prodflow --env-file .env --dry-run`.
- **`scripts/demo-run.sh`** führt den bindenden Demoablauf mit echten Logins und echten Tokens aus (Auftrag MR-200 × 10 → eine Bestellanforderung SC-M8 × 15 → Freigabe als Planer 403 →
  Freigabe und Wareneingang als Einkäufer → Auftrag freigegeben → Abschluss; Endbestand MR-200 10, SC-M8 0, PL-ST3 10, PR-40 15, BR-L60 20). Der Lauf **verbraucht** den Ausgangszustand und
  startet deshalb nur bei intaktem Ausgangszustand (sonst Exit 3: erst zurücksetzen). Gemeinsame Anmeldefunktionen: `scripts/lib/oidc.sh` (auch von `smoke-auth.sh` genutzt).
- **Prüfung:** `scripts/test-reset-demo.sh` (38 Fälle mit Wegwerf-PostgreSQL: Ablehnungen, Keycloak-Attrappe, doppelte Container, fehlerhafter Seed → Rollback, Wiederholbarkeit mit
  identischem Fingerabdruck von Daten, Versionen und Sequenzen) und `scripts/test-prod-stack.sh` (55 Fälle; enthält Demo-Lauf 1, abgelehnten Lauf 2, Reset, Demo-Lauf 2, Reset).

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
