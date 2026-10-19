# Frontend-Architektur

Stand: 19.10.2026, Branch `feature/frontend-foundation` (nicht committet, nicht gepusht, nicht deployt).

## Überblick
- Angular 21.2 (zoneless, standalone, Signals), PrimeNG 21.1.10 mit eigenem Preset auf Aura, Tailwind CSS 4 (Layout), keycloak-js 26.2.4, IBM Plex Sans lokal gebündelt (keine externen Fonts/CDNs).
- Struktur: `core/` (Konfiguration, Auth, HTTP, Theme), `shared/` (Modelle, API-Services, Labels, UI-Bausteine), `layout/` (Shell), `features/` (dashboard, inventory, orders, purchasing, system). Jede Fachseite wird lazy geladen und per `requirePermission` geschützt.
- Routen: `/uebersicht`, `/auftraege`, `/auftraege/:id`, `/bestellanforderungen`, `/bestand`, `/bestand/:id`, `/keine-berechtigung`, sonst 404-Seite.

## Entscheidungen
1. **PrimeNG 21.1.10 (MIT), exakt gepinnt.** PrimeNG 22 steht unter der „PrimeUI License“ (Schlüssel, Erneuerung, Hinweispflicht); 20.x/21.x sind MIT. Ein Upgrade ist eine bewusste Lizenzentscheidung.
2. **Same-Origin-API, keine CORS-Konfiguration.** Das Backend hat kein CORS. Entwicklung: Dev-Proxy; Produktion: gleiche Herkunft (Spring Boot oder Caddy) – noch nicht umgesetzt.
3. **Laufzeit-Konfiguration** über `config.json` (Keycloak-URL, Realm, Client). Validierung beim Start: `https` Pflicht, `http` nur für localhost. Keine Geheimnisse in Assets (öffentlicher PKCE-Client).
4. **Tokens nur im Speicher.** `onLoad: 'login-required'`, PKCE S256, `checkLoginIframe: false`, `updateToken(30)`. Der Bearer-Token wird nur an relative `/api/…`-URLs gehängt (e2e-geprüft). Bei 401 genau ein neuer Login-Versuch.
5. **Rollen in der UI spiegeln die Backend-Matrix** (`permissions.ts`, Spec als wörtliche Kopie von `SecurityConfig`). Nur Komfort: Das Backend erzwingt die Rechte; 403 wird verständlich angezeigt.
6. **Nur echte Daten.** Das Dashboard zählt/filtert ausschließlich API-Antworten; keine erfundenen Kennzahlen, kein Mock-Fallback.
7. **Stückliste einstufig – ehrlich dargestellt.** `BomRow` ist baumförmig (level, children), gefüllt wird heute nur eine Ebene; die UI sagt „Einstufige Stückliste“. `BomTable` ist die Austauschstelle für einen späteren TreeTable. Keine Mehrstufigkeit im Backend umgesetzt.
8. **Fehlerbehandlung zentral:** `ApiError`/`describeError` (deutsche Meldungen, Server-`detail` bei 409/400), Lade-, Leer- und Fehlerzustände mit „Erneut versuchen“. Backend-Geschäftsregeltexte sind englisch und werden unverändert angezeigt.

## Bekannte Grenzen
- Keine Auftrags-Bedarfszeilen im Backend (`GET /api/production-orders/{id}`): Das Auftragsdetail rekonstruiert Material aus Stückliste und Bestellanforderungen.
- Bestandskorrektur (`POST /items/{id}/stock`, nur ADMIN) hat noch keine UI.
- Suche nach Auftragsnummer per `?q=` fehlt; Bestellanforderungen verlinken auf den Statusfilter.
- Kein ESLint (nicht im Scaffold); Prettier ist angewandt und geprüft.
- `checkLoginIframe: false`: kein stilles Session-Polling; Ablauf wird beim nächsten Token-Refresh/401 erkannt.

## Verpackung / Betrieb (Plan, NICHT umgesetzt, braucht Freigabe)
- Multi-Stage-Image: Node-Build, Auslieferung als statische Dateien durch Spring Boot (gleiche Herkunft) inkl. SPA-Fallback und eng gefasstem `permitAll` für statische GETs (`AuthorizationMatrixTest` muss grün bleiben) – oder Caddy als Static-Server mit Reverse-Proxy auf `/api`.
- Keycloak-Client `prodflow-web` braucht für Produktion zusätzlich Redirect-/Web-Origin-URIs und `post.logout.redirect.uris` für die Produktions-Domain (additive Änderung am Live-Keycloak → vorher Freigabe).
- `config.json` der Produktion mit `https`-Keycloak-URL; CSP-Header im Caddy; CI: Node-Setup, Unit-Tests, Build (optional e2e mit Einweg-Stack).
- Produktionsintegration wurde nicht geprüft (kein Zugriff auf Produktion in dieser Phase).
