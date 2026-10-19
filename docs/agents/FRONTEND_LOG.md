# Frontend-Log (autonome Phase, 19.10.2026)

- Branch `feature/frontend-foundation`, nichts committet/gepusht/deployt, Produktion nicht angefasst, Live-Keycloak und AWS unverändert, Dev-Stack (8080/8180) nicht berührt.
- Gerüst: Angular 21.2 zoneless, PrimeNG 21.1.10 (MIT; 22.x wegen Lizenz vermieden), Tailwind 4, keycloak-js 26.2.4. `npm audit --omit=dev`: 0 Schwachstellen.
- Umgesetzt: Shell, Anmeldung (PKCE), Übersicht, Bestand + Artikeldetail + einstufige Stückliste, Fertigungsaufträge (Anlegen, Materialprüfung, Neuprüfung, Abschließen), Bestellanforderungen (Genehmigen, Wareneingang), Rollen, Fehlerzustände.
- Einweg-Stack `prodflow-fe-e2e` (Backend :18080, Keycloak :18180) mit `frontend/e2e/stack.sh`.
- Ergebnisse (19.10., nach Formatierung): Unit 112/112, Playwright 27/27 gegen frisch zurückgesetzten Stack, Produktions-Build OK (initial 734 kB roh / 167 kB komprimiert), Prettier sauber.
- Mutationsprobe: Rechte-Matrix und Datumslogik absichtlich verändert → 6 Tests schlugen fehl, Wiederherstellung → grün.
- Screenshots: `docs/frontend/screenshots` (13 Dateien).
- Offen: ESLint, Verpackung (Dockerfile/CI/Spring-Static-Routing), Keycloak-Client-URIs für Produktion, Produktions-Lesetest, Logout-Redirect gegen Realm mit `post.logout.redirect.uris`.
