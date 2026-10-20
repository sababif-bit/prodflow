# Debugging-Fall: Das Stylesheet, das die Sicherheitsrichtlinie nicht laden durfte

Stand: 20.10.2026 · Material für GitHub Issue #11 und die Folie „Debugging-Fall“ (ca. 2 Minuten) · Zeigedauer der Folie: 1 Folie Ablauf, 1 Folie Beleg.

## Kurzfassung
Der Angular-Produktionsbuild erzeugt standardmäßig `<link rel="stylesheet" … media="print" onload="this.media='all'">`: das Stylesheet wird zunächst „für den Druck“ geladen und per **Inline-Event-Handler** auf „alle“ umgeschaltet.
Unsere Content-Security-Policy erlaubt Skripte nur aus der eigenen Herkunft (`script-src 'self'`) und blockiert genau solche Inline-Handler. Folge: Der Browser lädt die Datei, wendet sie aber **nie** an – große Teile der Gestaltung fehlen.
Gefunden wurde das **beim Lesen der erzeugten `index.html`**, bevor die Anwendung ausgeliefert wurde. Behoben mit einer Zeile Build-Konfiguration (`inlineCritical: false`).

## Wie sicher sind die Belege? (Prüfung am 20.10.2026)
| Aussage | Beleg | Status |
|---|---|---|
| Die Konfiguration steht im Repository | `frontend/angular.json`, Abschnitt `optimization.styles.inlineCritical: false`, eingeführt in Commit `653e13b` (19.10.2026) | **belegt** |
| Der Befund wurde damals dokumentiert | `docs/agents/FRONTEND_LOG.md`, Phase 2, Befund (1) | **belegt** |
| Der Standardbuild erzeugt den Inline-`onload` | Am 20.10. neu gebaut mit `ng build --configuration production --optimization=true` in ein Wegwerf-Verzeichnis: `index.html` enthält `<link … media="print" onload="this.media='all'">` plus `<noscript>`-Ersatz | **belegt (Nachstellung)** |
| Die CSP blockiert ihn und das Stylesheet bleibt wirkungslos | Gleiche Chromium-Version, gleiche CSP wie in Caddy, zwei Builds derselben Anwendung (Messwerte unten) | **belegt (Nachstellung)** |
| Der Fehler trat in Produktion auf | **Nein.** Er wurde vor der ersten Auslieferung gefunden; es gab nie eine ausgelieferte Version mit dem Fehler | belegt (nichts passiert) |
| Es gab einen fehlschlagenden Test, der den Fehler zuerst zeigte | **Nein.** Entdeckt durch Lesen der Build-Ausgabe; der Browser-Test durch Caddy entstand danach | belegt (ehrlich so erzählen) |

## Symptom
- Mit strenger CSP lädt die Seite, aber die Oberfläche wirkt „halb gestylt“: Abstände, Breiten und Layout-Klassen (Tailwind/PrimeNG-Hilfsklassen) fehlen.
- In der Browser-Konsole: `Executing inline event handler violates the following Content Security Policy directive 'script-src 'self''.`
- Ohne CSP (Entwicklungsserver, `ng serve`) ist **nichts** zu sehen – der Fehler zeigt sich nur mit der Produktions-Richtlinie. Deshalb muss man mit dem echten Header testen.

Messwerte der Nachstellung (Chromium, Start-Fehlerseite der Anwendung als Messobjekt):

| | Standardbuild (`inlineCritical` an) | Unser Build (`inlineCritical: false`) |
|---|---|---|
| Stylesheet-Link `media` | **`print`** (bleibt hängen) | `all` |
| Überschrift (`text-2xl` = 24 px) | **30 px** (Klasse wirkt nicht) | 24 px |
| `main` (`flex`, `max-w-lg`) | `display: block`, keine Maximalbreite | `display: flex`, 512 px |
| Konsole | **CSP-Verstoß** | keine Meldung |

Ein Teil der Gestaltung (Schriften, Farbvariablen) steckt als „kritisches CSS“ inline im Dokument und wird mit `style-src 'unsafe-inline'` zugelassen – deshalb wirkt die Seite nicht völlig ungestylt.

## Ursache
Der Build-Schritt „Critical CSS inlinen“ (Beasties) macht das große Stylesheet nicht-blockierend: `media="print"` + `onload="this.media='all'"`. Das ist eine bewährte Technik für schnelle erste Darstellung,
setzt aber **Inline-JavaScript** voraus. Unsere Richtlinie (`script-src 'self'`, ADR #23) verbietet Inline-Skripte bewusst; ein Entschärfen mit `'unsafe-inline'` für Skripte hätte die wichtigste Schutzwirkung der CSP aufgegeben.

## Diagnose (so wurde es gefunden)
1. CSP für die Anwendung entworfen (`deploy/Caddyfile`) und dazu gefragt: Welche Stellen im Build brauchen Inline-Skripte oder Inline-Styles?
2. Erzeugte `dist/…/browser/index.html` gelesen (nicht nur den Quelltext): ein `onload`-Attribut am Stylesheet-Link und ein `<style>`-Block (kritisches CSS).
3. Folgerung: `style-src` braucht wegen PrimeNG (setzt Themes zur Laufzeit als `<style>`) ohnehin `'unsafe-inline'`; `script-src 'self'` verträgt den `onload`-Handler aber nicht → Konfigurationsoption `optimization.styles.inlineCritical` auf `false`.
4. Wiederholbar nachgestellt (20.10.): Build mit Standardoptimierung in ein Wegwerf-Verzeichnis, kleiner statischer Server mit derselben CSP, Chromium, Messung von `link.media`, Konsole und berechneten Stilen.

## Behebung
`frontend/angular.json` (Produktionskonfiguration):
```json
"optimization": { "scripts": true, "fonts": { "inline": false }, "styles": { "minify": true, "inlineCritical": false } }
```
Das Stylesheet ist jetzt ein normales `<link rel="stylesheet">` (kein Handler, keine Inline-Skripte in `index.html`). Kosten: das Stylesheet blockiert das erste Rendern kurz (eine Datei, gleiche Herkunft, 167 kB komprimiert insgesamt für alle Bundles).
(`fonts.inline: false` wurde im selben Commit gesetzt; die Option betrifft das Einbetten externer Schriften beim Build und ist **nicht** Teil dieses Fehlers. Unsere Schriften sind lokal gebündelt.)

## Verifikation
- Browser-Test durch Caddy mit HTTPS und echter CSP (`scripts/test-prod-stack.sh`, `frontend/e2e-prodstack/`): fängt jede Konsolenmeldung mit „Content Security Policy“ und schlägt dann fehl. **Das ist die tragende Absicherung.**
  Die zusätzlichen Prüfungen „Schrift IBM Plex Sans“ und „Seitenleiste hat Hintergrundfarbe“ würden den Fehler **nicht** allein entdecken, weil beides aus dem kritischen CSS bzw. einem Inline-`style`-Attribut stammt.
- Browser-Smoke-Test gegen die Produktion (20.10.): keine CSP-Verstöße bei Planer und Einkäufer.
- `scripts/verify-deployment.sh` prüft von außen, dass die CSP gesendet wird (`script-src 'self'` ohne `'unsafe-inline'`).

## Gelernte Lektionen
1. **Sicherheitsrichtlinien am echten Artefakt testen**, nicht am Entwicklungsserver: Der Fehler existiert nur im Produktionsbuild unter der Produktionsrichtlinie.
2. **Framework-Standards sind keine Neutralität:** Performance-Optimierungen können Inline-Skripte voraussetzen.
3. **Tests brauchen die richtige Aussagekraft:** Eine Prüfung, die „die Seite sieht gestylt aus“ misst, kann durch teilweise Gestaltung bestanden werden. Die Konsolenmeldung der Richtlinie ist das präzisere Signal.
4. **Ehrlich erzählen:** Gefunden durch Lesen, nicht durch einen Ausfall; die Nachstellung wurde später gemacht, um es belegen zu können.

## Offene Punkte und Unsicherheit
- Nachgestellt nur in **Chromium**; Firefox/Safari melden den Verstoß ähnlich, wurden aber nicht geprüft.
- Das Nachstell-Skript lag nur im Arbeitsverzeichnis der Sitzung und ist **nicht** im Repository; das Rezept steht oben (Schritt 4) und lässt sich in einen CI-Test überführen.
- Ein billiger Schutz für die CI wäre: nach dem Build prüfen, dass `dist/…/index.html` kein `onload=` enthält (nicht umgesetzt, würde den Workflow ändern).
- `style-src 'unsafe-inline'` bleibt nötig (PrimeNG); eine Nonce-Lösung wäre der nächste Härtungsschritt.
