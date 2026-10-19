# Frontend-Log (autonome Phase, 19.10.2026)

- Branch `feature/frontend-foundation`, nichts committet/gepusht/deployt, Produktion nicht angefasst, Live-Keycloak und AWS unverändert, Dev-Stack (8080/8180) nicht berührt.
- Gerüst: Angular 21.2 zoneless, PrimeNG 21.1.10 (MIT; 22.x wegen Lizenz vermieden), Tailwind 4, keycloak-js 26.2.4. `npm audit --omit=dev`: 0 Schwachstellen.
- Umgesetzt: Shell, Anmeldung (PKCE), Übersicht, Bestand + Artikeldetail + einstufige Stückliste, Fertigungsaufträge (Anlegen, Materialprüfung, Neuprüfung, Abschließen), Bestellanforderungen (Genehmigen, Wareneingang), Rollen, Fehlerzustände.
- Einweg-Stack `prodflow-fe-e2e` (Backend :18080, Keycloak :18180) mit `frontend/e2e/stack.sh`.
- Ergebnisse (19.10., nach Formatierung): Unit 112/112, Playwright 27/27 gegen frisch zurückgesetzten Stack, Produktions-Build OK (initial 734 kB roh / 167 kB komprimiert), Prettier sauber.
- Mutationsprobe: Rechte-Matrix und Datumslogik absichtlich verändert → 6 Tests schlugen fehl, Wiederherstellung → grün.
- Screenshots: `docs/frontend/screenshots` (13 Dateien).
- Offen: ESLint, Verpackung (Dockerfile/CI/Spring-Static-Routing), Keycloak-Client-URIs für Produktion, Produktions-Lesetest, Logout-Redirect gegen Realm mit `post.logout.redirect.uris`.

## Phase 2: Verpackung und Betriebsreife (19.10.2026, lokal, nichts gepusht/deployt)
Auftrag: SPA im Spring-Boot-Image, Laufzeitkonfiguration, CSP/Cache in Caddy, Logout, Verify-Gate, ESLint, Barrierefreiheit, Doku. Commits auf `feature/frontend-foundation`:
- `265f6a8` (Etikett irreführend: enthält nur das Entfernen von `backend/.dockerignore` und `frontend/public/config.json`; wegen einer fehlgeschlagenen Teil-Staging-Anweisung) und `653e13b` (die eigentliche Umsetzung der SPA-Integration). Kein History-Rewrite.
- `2ea19cd` Keycloak-Client `prodflow-web` (Realm-Datei, `scripts/provision-web-client.ps1`), `1f8eba5` Caddy-CSP/Cache, `deploy.sh`-Gate, `verify-deployment.sh`, CI, Prod-Stack-Test, `bed28d8` ESLint und Drawer.
- Befunde: (1) Angular-Standardbuild setzt ein Inline-`onload` an das Stylesheet → unter `script-src 'self'` bliebe die Seite ungestylt; behoben mit `inlineCritical: false`. (2) Logout war lokal nicht kaputt: der Realm hat `post.logout.redirect.uris = "+"` (folgt den Redirect-URIs); das Produktionsproblem sind allein die fehlenden Redirect-URIs. (3) `git checkout` ersetzt die Caddyfile (Bind-Mount einer Einzeldatei behält die alte Inode) → Caddy bekommt `RELEASE_TAG` und wird je Release neu erzeugt. (4) Der erste Rollout läuft mit dem alten `deploy.sh` des Servers (kein Anwendungs-Gate) → in `docs/frontend-rollout.md` dokumentiert. (5) Ein `visibility`-Übergang am Drawer verhinderte das Fokussieren beim Öffnen (Browser-Test deckte es auf; Unit-Tests in jsdom nicht).
- Ergebnisse: Backend `mvn verify` 132 Tests grün; Frontend 119 Unit-Tests, ESLint sauber (Negativprobe: 9 absichtliche Verstöße gefunden), Build ok; Playwright 30 Tests; `scripts/test-prod-stack.sh` 59 PASS / 0 FAIL im ersten Lauf (Browser-Test durch Caddy dort noch ohne Zählprüfung; Zählprüfung danach ergänzt); `test-deploy-agent.sh` 26/26; `test-caddyfile.sh` 9/9; actionlint ohne Befund.
- Offen/Risiken: siehe `docs/frontend-rollout.md` (Keycloak-Ergänzung, erster Rollout, echte Zertifikate, Browser außerhalb Chromium).
