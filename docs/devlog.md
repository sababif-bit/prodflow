# Entwicklungstagebuch

Zwei Zeilen pro Tag. Grundlage für das tägliche Projekt-Update im Classroom und für
die Folien „Technische Herausforderungen", „Debugging-Fall" und „Lessons Learned".

## Tag 4 – 12.10.
- **Erreicht:** Projektidee ProdFlow festgelegt, MVP-Umfang bewusst klein gehalten (einstufige Stückliste).
- **Herausforderung:** Verspäteter Start – Umfang priorisiert: erst lauffähiges, getestetes, deploytes MVP, dann Erweiterungen.

## Tag 5 – 13.10.
- **Erreicht:** Backend-Gerüst, Datenmodell (Flyway), kompletter Workflow Auftrag → Materialprüfung → Bestellanforderung → Wareneingang → Abschluss, Tests je Akzeptanzkriterium, Dockerfile, Compose, CI/CD-Pipeline.
- **Herausforderung:** Doppelte Bestellanforderungen bei wiederholter Prüfung → bereits angeforderte Menge wird abgezogen.
- **Morgen:** Erster Push, Pipeline grün bekommen, EC2 einrichten, erstes Deployment.

## Update – 15.10.2026
- **Erreicht (seit 13.10.):** Erster Push auf `main`; API als OAuth2 Resource Server abgesichert
  (Keycloak-JWT, Rollen ADMIN/PLANNER/PURCHASER, Funktionstrennung Planung/Einkauf – GitHub Issue #1,
  PR #2, gemergt 13.10.); lokales Keycloak mit eigener PostgreSQL in Docker Compose und PKCE-Client
  fürs Frontend (GitHub Issue #3, PR #4, gemergt 15.10.). CI geprüft: alle 5 Läufe grün, Images
  `sha-1f5d9f8`, `sha-0ca4bc2`, `sha-c1eca31` und `latest` in GHCR.
- **Herausforderung / Blocker:** AWS-EC2-Deployment noch **nicht** erfolgt – der Deploy-Job überspringt
  seine Schritte, solange `EC2_HOST` nicht gesetzt ist. Der Plan von Tag 5 (EC2 einrichten, erstes
  Deployment) ist damit noch offen.

## Update – 16. und 17.10.2026
- **Erreicht:** Runner auf `ubuntu-24.04` festgelegt (GitHub Issue #7), Swagger-Anmeldung mit Keycloak (PKCE, Demo-Benutzer; Issue #8, PR #26), Produktionsstapel mit Caddy,
  HTTPS und Keycloak (Issues #14/#16, PR #27), öffentlicher Endpunkt `GET /version` mit der Build-Revision (Issue #10, PR #28), pull-basierte Pipeline mit Agent, Health-Gate und
  Rollback (Issue #18, PR #29), Bootstrap-Skript mit Vorabprüfungen (PR #31) und Härtung für den ersten Serverstart inklusive Trockenlauf auf einem sauberen Ubuntu (PR #32).
  Außerdem der gesicherte Demo-Reset samt Skript für den Demoablauf (Issues #9/#19).
- **Herausforderung:** Eine zu knappe Speichergrenze auf der 2-GiB-Instanz: Keycloak-Heap und Container-Limits wurden gemeinsam so gesetzt, dass die Summe aller Limits unter dem Hauptspeicher bleibt.
  Ein dokumentierter Rehearsal-Schalter für Let's-Encrypt-Staging war ungültige Caddyfile-Syntax und wurde durch eine Variable ersetzt (Test `scripts/test-caddyfile.sh`).

## Update – 18. und 19.10.2026
- **Erreicht:** Erstes Deployment auf AWS am 18.10. (Container seit 17:50 UTC, Zertifikate für beide Namen seit 16:52 UTC); die Prüfungen der Produktion wurden am 20.10. wiederholt (siehe unten).
  Am 19.10. PR #30 (Demo-Reset) gemergt; die Revision `fb08e68` lief in Produktion. Parallel entstand das Angular-Frontend (Dashboard, Bestand mit einstufiger Stückliste, Fertigungsaufträge,
  Bestellanforderungen, Rollen) (Stand 20.10.: 119 Unit-Tests und 30 Browser-Tests gegen einen Einweg-Stack).
- **Herausforderung:** Die Oberfläche sollte vom Backend-Image ausgeliefert werden, ohne Umgebungswerte in die Build-Dateien zu schreiben, und unter einer strengen Content-Security-Policy laufen.
  Der Angular-Standardbuild setzt einen Inline-`onload` an das Stylesheet; er wird von der CSP blockiert (siehe `docs/presentation/debugging-fall-csp-de.md`). Lösung: `inlineCritical: false`.

## Update – 20.10.2026
- **Erreicht:** PR #34 (Frontend im Backend-Image, CSP und Cache-Header in Caddy, Anwendungs-Gate im Deployment, Rollback-Schalter) gemergt; kontrollierte manuelle Auslieferung von `sha-b509944`
  mit pausiertem Agenten, anschließend Verifikation (`verify-deployment.sh` 41/41, `smoke-auth.sh` 38/38, Browser-Test mit Planer und Einkäufer, Verify-Job grün), 30 Minuten Beobachtung
  und Wiederaufnahme der automatischen Auslieferung. Sichtbare Unterbrechung bei der Auslieferung: etwa 27 Sekunden.
- **Herausforderung:** Der neue Anwendungs-Check im Deployment-Skript verweigert absichtlich ein Release ohne Oberfläche – dadurch hätte auch ein Rollback auf das alte Backend-Release das neue wiederhergestellt.
  Gelöst mit einem expliziten, eng begrenzten Schalter (`DEPLOY_ROLLBACK_TO_BACKEND_ONLY=1`) und einem Test mit echten Containern (`scripts/test-deploy-gate.sh`).
- **Morgen:** Präsentation vorbereiten (Demo-Skript, Folien, Proben), Demo-Daten vor den Proben auf den Ausgangszustand zurücksetzen (separate Freigabe nötig).

<!-- Vorlage
## Tag X – TT.MM.
- **Erreicht:**
- **Herausforderung / Blocker:**
- **Morgen:**
-->
