# Frontend-Architektur

Stand: 19.10.2026, Branch `feature/frontend-foundation` (lokal committet, nicht gepusht, nicht deployt). Die verbindlichen Entscheidungen stehen als
ADR #16–#19 in `docs/architecture.md`; dieses Dokument beschreibt Aufbau, Betrieb und Grenzen. Rollout: `docs/frontend-rollout.md`.

## Überblick
- Angular 21.2 (zoneless, standalone, Signals), PrimeNG 21.1.10 mit eigenem Preset auf Aura, Tailwind CSS 4 (Layout), keycloak-js 26.2.4,
  IBM Plex Sans lokal gebündelt (keine externen Fonts/CDNs). ESLint 9 (angular-eslint) mit Template-Barrierefreiheitsregeln, Prettier.
- Struktur: `core/` (Konfiguration, Auth, HTTP, Theme), `shared/` (Modelle, API-Services, Labels, UI-Bausteine), `layout/` (Shell),
  `features/` (dashboard, inventory, orders, purchasing, system). Jede Fachseite wird lazy geladen und per `requirePermission` geschützt.
- Routen: `/uebersicht`, `/auftraege`, `/auftraege/:id`, `/bestellanforderungen`, `/bestand`, `/bestand/:id`, `/keine-berechtigung`, sonst 404-Seite.
  Dieselbe Liste kennt das Backend (`de.prodflow.web.FrontendRoutes`) für den SPA-Fallback und den öffentlichen GET-Zugriff.

## Auslieferung (ADR #17)
- `backend/Dockerfile` ist mehrstufig: Stufe `frontend` (Node 22, `npm ci`, `ng build`), Stufe `build` (Maven; die SPA wird nach
  `src/main/resources/static` kopiert, der Build bricht ab, wenn `index.html` fehlt oder eine `config.json` mitgeliefert würde), Laufzeitstufe
  (nur JRE + Jar). Der **Build-Kontext ist das Repository-Wurzelverzeichnis** (`docker build -f backend/Dockerfile .`); `.dockerignore` ist eine
  Allowlist (nie die Wurzel-`.env`, nie `.git`, nie `node_modules`).
- Spring Boot liefert die Dateien same-origin aus. Nur die Routen aus `FrontendRoutes` werden auf `index.html` weitergeleitet; ein unbekannter
  Pfad bleibt 401/403/404. `SecurityConfig` erlaubt öffentlich nur GET/HEAD auf diese Dateien und Routen; alles Übrige bleibt „deny by default“
  (`AuthorizationMatrixTest`, `FrontendServingTest`).
- Caddy (Produktion) setzt CSP, `Permissions-Policy` und die Cache-Header (ADR #19). Der Angular-Build erzeugt keine Inline-Skripte
  (`optimization.styles.inlineCritical: false`), damit `script-src 'self'` gilt.

## Laufzeitkonfiguration und Anmeldung (ADR #18)
- `GET /config.json` beantwortet das Backend aus `OIDC_ISSUER_URI` (`https://<auth>/realms/<realm>` → `{keycloak:{url,realm,clientId}}`, nie gecacht,
  Start schlägt fehl bei unpassendem Issuer). Die kompilierten Dateien enthalten keinen umgebungsspezifischen Wert. Entwicklung: der Dev-Proxy
  leitet `/config.json` an das Backend weiter (Standard `http://localhost:8080` → `http://localhost:8180`).
- Das Frontend validiert die Konfiguration beim Start: `https` Pflicht, `http` nur für localhost; sonst Fehlerseite statt leerer Seite.
- Authorization Code + PKCE (S256) mit dem öffentlichen Client `prodflow-web`, `login-required`, `checkLoginIframe: false`, `updateToken(30)`. Tokens nur im
  Speicher (e2e: weder `localStorage`/`sessionStorage` noch Cookies). Der Bearer-Token geht nur an relative `/api/…`-URLs. Bei 401 genau ein neuer
  Login-Versuch. Abmelden: `logout({redirectUri: origin + '/'})`; Keycloak erlaubt das über `post.logout.redirect.uris` (Standard `+` = Redirect-URIs).
- Rollen in der UI spiegeln die Backend-Matrix (`permissions.ts`; die Spec ist eine wörtliche Kopie von `SecurityConfig`). Nur Komfort: das Backend erzwingt die Rechte.

## Weitere Entscheidungen
1. **PrimeNG 21.1.10 (MIT), exakt gepinnt.** 22.x steht unter der „PrimeUI License“ (Schlüssel, Erneuerung, Hinweispflicht); ein Upgrade ist eine Lizenzentscheidung.
2. **Nur echte Daten.** Das Dashboard zählt/filtert ausschließlich API-Antworten; kein Mock-Fallback.
3. **Stückliste einstufig – ehrlich dargestellt.** `BomRow` ist baumförmig (level, children), gefüllt wird heute eine Ebene; die UI sagt „Einstufige
   Stückliste“. `BomTable` ist die Austauschstelle für einen späteren TreeTable. Keine Mehrstufigkeit im Backend (siehe Roadmap unten).
4. **Fehlerbehandlung zentral:** `ApiError`/`describeError` (deutsche Meldungen, Server-`detail` bei 409/400), Lade-, Leer- und Fehlerzustände mit „Erneut versuchen“.
   Backend-Geschäftsregeltexte sind englisch und werden unverändert angezeigt.
5. **Barrierefreiheit:** Skip-Link, Landmarks, Statuschips mit Text + Icon (nie nur Farbe), Tabellen mit Beschriftung; mobiles Menü als Drawer
   (geschlossen unsichtbar und nicht per Tab erreichbar, geöffnet: Fokus im Menü, Seite dahinter `inert`, Tab wandert im Menü, Escape/Backdrop schließen
   und geben den Fokus zurück, `aria-current`, `prefers-reduced-motion`). Unit- und Tastatur-e2e-Tests; kein automatischer axe-Lauf.

## Tests (Stand 19.10.2026)
| Ebene | Umfang | Ausführung |
|---|---|---|
| Unit (Vitest) | 119 Tests in 13 Dateien | `npm test -- --no-watch` (CI) |
| Lint | ESLint inkl. Template-Barrierefreiheit, Prettier | `npm run lint` (CI) |
| Backend | 132 Tests, darunter `FrontendServingTest`, `AuthorizationMatrixTest`, `KeycloakRealmConfigTest` | `mvn verify` (CI) |
| Browser (Playwright, Einweg-Stack) | 30 Tests: Anmeldung/PKCE, Lesen, kompletter Geschäftsablauf, Fehlerfälle, mobiles Menü | `e2e/stack.sh up` + `npx playwright test` (lokal) |
| Produktionsnaher Stack | `scripts/test-prod-stack.sh`: Caddy/HTTPS, Keycloak, `verify-deployment.sh`, Browser-Test durch Caddy (CSP, Abmelden, Swagger) | lokal, Docker |
| Betrieb | `scripts/test-deploy-agent.sh` (inkl. Anwendungs-Gate), `scripts/test-caddyfile.sh` | CI (Job `ops`) |

## Bekannte Grenzen
- Keine Auftrags-Bedarfszeilen im Backend (`GET /api/production-orders/{id}`): Das Auftragsdetail rekonstruiert Material aus Stückliste und Bestellanforderungen.
- Bestandskorrektur (`POST /items/{id}/stock`, nur ADMIN) hat keine UI. Suche nach Auftragsnummer per `?q=` fehlt.
- Einheiten und Artikelnamen kommen aus der API (Demo-Daten englisch: `pcs`, „Hex screw“); Geschäftsregel-Meldungen des Backends sind englisch.
- Keine Paginierung (das Backend liefert vollständige Listen); `style-src 'unsafe-inline'` wegen PrimeNG; kein automatischer a11y-Scan.
- Die Browser-Tests laufen nicht in CI (sie brauchen den Docker-Stack); der Produktionsnahe Stack-Test ebenfalls nicht.

## Roadmap (nicht Teil des Einfrierens am 23.10.)
Mehrstufige Stückliste (Backend: Auflösung mit Zyklenerkennung über die bestehende `bom_line`-Selbstreferenz, Bedarfsberechnung je Ebene; Frontend: TreeTable
in `BomTable`), Bestandskorrektur-Dialog, Bedarfszeilen-API, Paginierung/Serversuche, deutsche Fachtexte und Einheiten, axe-Scan, PrimeNG-22-Lizenzentscheidung.
