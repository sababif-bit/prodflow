# ProdFlow Frontend

Angular 21 + PrimeNG 21 (deutsche Oberfläche). Anmeldung über Keycloak (Authorization Code + PKCE S256, Client `prodflow-web`), Daten über die echte Spring-Boot-REST-API.
Im Betrieb liegt die kompilierte Anwendung im Backend-Image (`backend/Dockerfile`, Build-Kontext = Repository-Wurzel).

Architektur und Entscheidungen: [`docs/frontend-architecture.md`](../docs/frontend-architecture.md) und ADR #20–#23 in `docs/architecture.md`.
Rollout: [`docs/frontend-rollout.md`](../docs/frontend-rollout.md). Screenshots: [`docs/frontend/screenshots`](../docs/frontend/screenshots).

## Voraussetzungen
Node 22 (getestet 22.18). Hinweis: npm 11.5.2 stürzt bei `install` ab; `npx -y npm@12.2.0 ci` verwenden (das Node-22-Image und CI nutzen ihr eigenes npm).

## Vorschau (Entwicklung)
Mit dem lokalen Entwicklungs-Stack (`docker compose up`, Backend :8080, Keycloak :8180):
```
npx -y npm@12.2.0 ci
npx ng serve            # http://localhost:4200
```
- `/api`, `/version`, `/config.json` und `/actuator/health` leitet der Dev-Proxy (`proxy.conf.cjs`) an `API_TARGET` weiter (Standard `http://localhost:8080`). Für den Browser ist alles same-origin, daher kein CORS.
- Der Anmeldeserver kommt aus `GET /config.json` des Backends (aus dessen `OIDC_ISSUER_URI`); im Repository liegt keine Konfigurationsdatei mit Adressen.
- Der Client `prodflow-web` erlaubt `http://localhost:4200/*` und die Anwendungs-Adresse der Umgebung (`PRODFLOW_APP_URL`).

## Qualität
```
npm run lint                           # ESLint (TypeScript, Angular, Template-Barrierefreiheit)
npm test -- --no-watch                 # Unit-Tests (Vitest), 119 Tests
npm run build                          # Produktions-Build (dist/prodflow-frontend/browser)
```
### End-to-End (Playwright, Einweg-Stack)
```
bash e2e/stack.sh build   # Backend-Image neu bauen (enthält die SPA; nach Änderungen an Backend/Frontend)
bash e2e/stack.sh up      # eigener Compose-Stack: Backend :18080, Keycloak :18180 (Projekt prodflow-fe-e2e)
npx playwright test       # 30 Tests, echte Keycloak-Anmeldung, echte API; startet ng serve selbst
bash e2e/stack.sh reset   # Daten zurücksetzen (nur dieser Einweg-Stack)
bash e2e/stack.sh down
```
Der Stack berührt weder den Entwicklungs-Stack (8080/8180) noch Produktion. Zufällige Passwörter liegen in `e2e/.stack.env` (git-ignoriert). Die Specs laufen der Reihe nach und teilen Daten; vor einem erneuten Lauf `reset` ausführen. `05-screenshots` schreibt nach `docs/frontend/screenshots`.

### Produktionsnaher Test (Caddy, HTTPS, CSP)
`scripts/test-prod-stack.sh` (Docker nötig; Image vorher mit `docker build -f backend/Dockerfile --build-arg GIT_SHA=<40 hex> -t prodflow-backend:prodcheck .` bauen, dann `TEST_IMAGE_TAG=prodcheck`) startet den Produktionsstapel und führt u. a. `playwright.prodstack.config.ts` aus.
