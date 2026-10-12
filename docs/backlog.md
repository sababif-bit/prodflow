# Backlog – GitHub Issues

Jede Überschrift = ein GitHub Issue (Titel kopieren, Inhalt als Beschreibung).
Ein Issue → ein Branch `feature/<nr>-<name>` → ein Pull Request.

Labels: `backend` `frontend` `devops` `docs` `stretch`

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

### #5 CI-Pipeline Test → Build `devops` ✅ (im Repo, beim ersten Push prüfen)
- [ ] Pipeline läuft bei Push und Pull Request grün
- [ ] Image erscheint in GHCR mit Tag `sha-…`
- [ ] Branch-Schutz für `main` aktiv

### #6 Erstes Deployment auf EC2 `devops`
- [ ] Budget Alert 5 € aktiv
- [ ] EC2 eingerichtet (siehe `docs/architecture.md`)
- [ ] Secrets in GitHub hinterlegt
- [ ] Push auf `main` → Health-Check unter `http://<EC2-IP>/actuator/health` liefert `UP`

---

## Sprint 2 – Frontend & Cloud (Tag 5–9)

### #7 Angular-Projekt + Nginx-Container `frontend` `devops`
- [ ] Angular + PrimeNG, Nginx liefert das Frontend aus und leitet `/api` ans Backend (kein CORS)
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
- [ ] PostgreSQL auf RDS, nur aus der EC2-Security-Group erreichbar
- [ ] Zugangsdaten nur in `.env` auf dem Server / GitHub Secrets
- [ ] Backup-Aufbewahrung in RDS aktiviert

---

## Sprint 3 – Stabilisierung & Präsentation (Tag 10–12)

### #12 Dokumentation und Architekturdiagramm `docs`
- [ ] README aktuell, Architekturdiagramm (Browser → Nginx → Backend → RDS, Pipeline)
- [ ] Debugging-Fall im Devlog ausgearbeitet

### #13 Demo vorbereiten `docs`
- [ ] Demo-Skript (5 Klicks durch den kompletten Workflow)
- [ ] Backup-Video der Demo

---

## Stretch Goals

- #14 Mehrstufige Stückliste (rekursive Auflösung, Zyklenprüfung, kein doppeltes Zählen von Bestand) `stretch`
- #15 Make-or-Buy mit Unteraufträgen `stretch`
- #16 Materialreservierung `stretch`
- #17 Excel-Import von Stücklisten (Apache POI) `stretch`
- #18 HTTPS mit Nginx + Let's Encrypt `stretch`
