# Backlog – GitHub Issues

Jede Überschrift = ein GitHub Issue (Titel kopieren, Inhalt als Beschreibung).
Ein Issue → ein Branch `feature/<nr>-<name>` → ein Pull Request.

Labels: `backend` `frontend` `devops` `docs` `stretch`

> **Hinweis zur Nummerierung (Stand 15.10.):** Die Nummern #1–#18 in diesem Dokument sind
> **Backlog-Nummern**, keine GitHub-Nummern. Bisher wurden nur die Sicherheitsthemen als
> GitHub Issues angelegt (siehe „Zusätzlich umgesetzt"). GitHub Issues und Pull Requests teilen
> sich einen Nummernkreis, daher werden sie hier immer als „GitHub Issue #…" bzw. „PR #…"
> bezeichnet. Die oben genannten Labels sind auf GitHub noch nicht angelegt.

---

## Sprint 1 – MVP (Tag 1–4)

### #1 Projektgerüst Backend `backend` ✅
Spring Boot 3.4, PostgreSQL, Flyway, Docker Compose.
- [x] `docker compose up --build` startet DB und Backend
- [x] `/actuator/health` liefert `UP`
- [x] Swagger UI erreichbar

### #2 Datenmodell Artikel, Stückliste, Aufträge, Bestellanforderungen `backend` ✅
- [x] Flyway-Migration V1 mit allen vier Tabellen und Constraints
- [x] Stückliste als selbstreferenzierende Tabelle (vorbereitet für mehrere Ebenen)
- [x] Demo-Daten über Profil `demo`

### #3 Materialprüfung und Bestellanforderungen `backend` ✅
- [x] AC1: 10 × A (4 Schrauben je Stück), Bestand 25 → Auftrag `WAITING_MATERIAL`, Anforderung über 15
- [x] AC2: Erneute Prüfung erzeugt keine zweite Anforderung
- [x] Ausreichender Bestand → Auftrag direkt `RELEASED`

### #4 Wareneingang und Auftragsabschluss `backend` ✅
- [x] AC3: Wareneingang erhöht Bestand und gibt wartende Aufträge automatisch frei
- [x] AC4: Abschluss verbraucht Material, bucht Fertigprodukt ein
- [x] Wareneingang nur nach Genehmigung

### #5 CI-Pipeline Test → Build `devops` ⏳ (teilweise – Branch-Schutz noch nicht verifiziert)
- [x] Pipeline läuft bei Push und Pull Request grün *(geprüft 15.10.: alle 5 Läufe erfolgreich, 3 × Push auf `main`, 2 × Pull Request)*
- [x] Image erscheint in GHCR mit Tag `sha-…` *(geprüft 15.10.: `sha-1f5d9f8`, `sha-0ca4bc2`, `sha-c1eca31`, `latest`)*
- [ ] Branch-Schutz für `main` aktiv *(noch nicht verifiziert)*

### #6 Erstes Deployment auf EC2 `devops`
**Status: nicht umgesetzt (Stand 15.10.).** Der Deploy-Job der Pipeline überspringt seine
Schritte, solange `EC2_HOST` nicht gesetzt ist. Zielarchitektur siehe ADR #15 in
`docs/architecture.md` (Vorschlag, noch nicht entschieden).
- [ ] Budget Alert 5 € aktiv
- [ ] EC2 eingerichtet (siehe `docs/architecture.md`)
- [ ] Secrets in GitHub hinterlegt
- [ ] Push auf `main` → Health-Check unter `http://<EC2-IP>/actuator/health` liefert `UP`

---

## Sprint 2 – Frontend & Cloud (Tag 5–9)

### #7 Angular-Projekt + Nginx-Container `frontend` `devops`
> **Historische Planungsannahme:** Nginx stammt aus der ursprünglichen Planung und ist nicht
> entschieden. Der aktuelle Vorschlag (ADR #15 in `docs/architecture.md`) sieht Caddy als
> Reverse Proxy vor. Die Nginx-Kriterien vor der Umsetzung mit ADR #15 abgleichen.
- [ ] Angular + PrimeNG, Nginx liefert das Frontend aus und leitet `/api` ans Backend (kein CORS) *(historische Annahme – Abgleich mit ADR #15)*
- [ ] API-URL über Environment, nicht hartkodiert
- [ ] Frontend-Image in Pipeline und Compose

### #8 Artikel- und Stücklistenpflege `frontend`
- [ ] Artikelliste mit Bestand, Anlegen/Bearbeiten
- [ ] Stückliste eines Produkts anzeigen, Positionen hinzufügen/entfernen
- [ ] Fehlermeldungen aus `ProblemDetail` werden angezeigt

### #9 Produktionsplan und Auftragsanlage `frontend`
- [ ] Aufträge nach Liefertermin, Status als farbiges Badge
- [ ] Auftrag anlegen zeigt das Ergebnis der Materialprüfung (Bedarf / Bestand / Fehlmenge)
- [ ] Button „Abschließen" für freigegebene Aufträge

### #10 Einkaufsansicht `frontend`
- [ ] Liste der Bestellanforderungen mit auslösendem Auftrag
- [ ] Buttons „Genehmigen" und „Wareneingang"

### #11 RDS und Secrets `devops`
> **Historische Planungsannahme:** RDS stammt aus der ursprünglichen Planung (ADR #11) und ist
> nicht entschieden. Der aktuelle Vorschlag (ADR #15) sieht PostgreSQL als Container auf der
> EC2-Instanz vor. Die RDS-Kriterien vor der Umsetzung mit ADR #15 abgleichen; die Anforderung
> an Zugangsdaten gilt unabhängig davon.
- [ ] PostgreSQL auf RDS, nur aus der EC2-Security-Group erreichbar *(historische Annahme – Abgleich mit ADR #15)*
- [ ] Zugangsdaten nur in `.env` auf dem Server / GitHub Secrets
- [ ] Backup-Aufbewahrung in RDS aktiviert *(historische Annahme – Abgleich mit ADR #15)*

---

## Sprint 3 – Stabilisierung & Präsentation (Tag 10–12)

### #12 Dokumentation und Architekturdiagramm `docs`
- [ ] README aktuell, Architekturdiagramm (Browser → Nginx → Backend → RDS, Pipeline)
- [ ] Debugging-Fall im Devlog ausgearbeitet

### #13 Demo vorbereiten `docs`
- [ ] Demo-Skript (5 Klicks durch den kompletten Workflow)
- [ ] Backup-Video der Demo

---

## Zusätzlich umgesetzt (außerhalb des ursprünglichen Backlogs)

Ersetzt den ursprünglichen Plan „Kein Login im MVP" (ADR #12 → ADR #14).

### Keycloak OIDC Resource Server und rollenbasierte Zugriffe `backend` ✅
GitHub Issue #1 · PR #2 (gemergt)
- [x] Backend validiert Keycloak-JWTs (Signatur, Ablauf, Issuer, Audience `prodflow-api`)
- [x] Rollen ADMIN, PLANNER, PURCHASER; Zugriffe nach Berechtigungsmatrix, deny by default
- [x] Funktionstrennung: PLANNER kann Bestellanforderungen nicht genehmigen oder vereinnahmen
- [x] Tests: `AuthorizationMatrixTest`, `JwtValidationTest`, `KeycloakRoleConverterTest`

### Lokales Keycloak-Setup `devops` ✅
GitHub Issue #3 · PR #4 (gemergt)
- [x] Keycloak mit eigener PostgreSQL in `docker-compose.yml`, Realm-Import aus `keycloak/prodflow-realm.json`
- [x] Client `prodflow-web` mit PKCE (S256) für das spätere Frontend
- [x] Zugangsdaten nur über `.env` (Vorlage `.env.example`)

---

## Stretch Goals

- #14 Mehrstufige Stückliste (rekursive Auflösung, Zyklenprüfung, kein doppeltes Zählen von Bestand) `stretch`
- #15 Make-or-Buy mit Unteraufträgen `stretch`
- #16 Materialreservierung `stretch`
- #17 Excel-Import von Stücklisten (Apache POI) `stretch`
- #18 HTTPS mit Nginx + Let's Encrypt `stretch` *(historische Planungsannahme: Nginx ist nicht entschieden; im Vorschlag ADR #15 übernimmt Caddy HTTPS – vor der Umsetzung abgleichen)*
