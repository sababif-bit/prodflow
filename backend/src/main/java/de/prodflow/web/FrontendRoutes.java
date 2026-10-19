package de.prodflow.web;

/**
 * What the backend serves for the Angular single-page application (compiled into the image, see backend/Dockerfile).
 * One list for both consumers - the SPA fallback (WebConfig) and the narrow public GET access (SecurityConfig) - so they cannot drift.
 * Everything not listed here stays denied by default.
 */
public final class FrontendRoutes {

    /** Client-side routes of the SPA (frontend/src/app/app.routes.ts). A browser reload on one of them must return index.html. */
    public static final String[] SPA_ROUTES = {
            "/uebersicht",
            "/auftraege", "/auftraege/*",
            "/bestellanforderungen",
            "/bestand", "/bestand/*",
            "/keine-berechtigung"
    };

    /** Files of the Angular production build (hashed bundles in the root, fonts in /media) plus the runtime configuration. */
    public static final String[] STATIC_FILES = {
            "/", "/index.html", "/favicon.svg", "/config.json", "/3rdpartylicenses.txt",
            "/*.js", "/*.css", "/media/*"
    };

    private FrontendRoutes() {
    }
}
