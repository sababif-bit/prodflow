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

<!-- Vorlage
## Tag X – TT.MM.
- **Erreicht:**
- **Herausforderung / Blocker:**
- **Morgen:**
-->
