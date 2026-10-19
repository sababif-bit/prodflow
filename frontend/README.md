# ProdFlow Frontend

Angular 21 + PrimeNG 21 (deutsche Oberfläche). Anmeldung über Keycloak (Authorization Code + PKCE S256, Client `prodflow-web`), Daten über die echte Spring-Boot-REST-API.

Architektur und Entscheidungen: [`docs/frontend-architecture.md`](../docs/frontend-architecture.md). Screenshots: [`docs/frontend/screenshots`](../docs/frontend/screenshots).

## Voraussetzungen
Node 22 (getestet 22.18). Hinweis: npm 11.5.2 stürzt bei `install` ab; `npx -y npm@12.2.0 ci` verwenden.

## Vorschau (Entwicklung)
```
npx -y npm@12.2.0 ci
npx ng serve            # http://localhost:4200
```
- `/api`, `/version`, `/actuator/health` werden vom Dev-Proxy (`proxy.conf.cjs`) an `API_TARGET` weitergeleitet (Standard `http://localhost:8080`). Für den Browser ist alles same-origin, daher kein CORS.
- Keycloak-Adresse: `public/config.json` (Standard `http://localhost:8180`, Realm `prodflow`). Für `https` ist keine Ausnahme nötig; `http` ist nur für localhost erlaubt.
- Der Client `prodflow-web` erlaubt aktuell nur `http://localhost:4200/*`.

## Tests
```
npx -y npm@12.2.0 test -- --no-watch   # Unit-Tests (Vitest), 112 Tests
npx -y npm@12.2.0 run build            # Produktions-Build
```
### End-to-End (Playwright, Einweg-Stack)
```
bash e2e/stack.sh up      # eigener Compose-Stack: Backend :18080, Keycloak :18180 (Projekt prodflow-fe-e2e)
npx playwright test       # 27 Tests, echte Keycloak-Anmeldung, echte API
bash e2e/stack.sh reset   # Daten zurücksetzen (nur dieser Einweg-Stack)
bash e2e/stack.sh down
```
Der Stack berührt weder den lokalen Entwicklungs-Stack (8080/8180) noch Produktion. Zufällige Passwörter liegen in `e2e/.stack.env` (git-ignoriert). Die Specs laufen der Reihe nach und teilen Daten; vor einem erneuten Lauf `reset` ausführen.
