import { registerLocaleData } from '@angular/common';
import { provideHttpClient, withFetch, withInterceptors } from '@angular/common/http';
import localeDe from '@angular/common/locales/de';
import {
  ApplicationConfig,
  inject,
  LOCALE_ID,
  provideAppInitializer,
  provideBrowserGlobalErrorListeners,
} from '@angular/core';
import {
  provideRouter,
  TitleStrategy,
  withComponentInputBinding,
  withInMemoryScrolling,
} from '@angular/router';
import { ConfirmationService, MessageService } from 'primeng/api';
import { providePrimeNG } from 'primeng/config';
import { AuthService } from './core/auth/auth.service';
import { loadAppConfig } from './core/config/app-config';
import { authInterceptor, errorInterceptor } from './core/http/http-interceptors';
import { StartupState } from './core/startup-state';
import { GERMAN_TRANSLATION, ProdFlowPreset } from './core/theme/prodflow-preset';
import { AppTitleStrategy } from './app.title-strategy';
import { routes } from './app.routes';

registerLocaleData(localeDe);

/**
 * Start-up: load the runtime configuration, then sign in (Authorization Code + PKCE). When either fails the application
 * still starts and shows a clear message instead of a blank page.
 */
async function initializeApplication(): Promise<void> {
  const auth = inject(AuthService);
  const startup = inject(StartupState);
  try {
    const config = await loadAppConfig();
    await auth.init(config.keycloak);
  } catch (error) {
    console.error('Start fehlgeschlagen', error);
    startup.fail(error instanceof Error ? error.message : 'Unbekannter Fehler');
  }
}

export const appConfig: ApplicationConfig = {
  providers: [
    provideBrowserGlobalErrorListeners(),
    provideRouter(
      routes,
      withComponentInputBinding(),
      withInMemoryScrolling({ scrollPositionRestoration: 'enabled' }),
    ),
    provideHttpClient(withFetch(), withInterceptors([authInterceptor, errorInterceptor])),
    { provide: LOCALE_ID, useValue: 'de-DE' },
    { provide: TitleStrategy, useClass: AppTitleStrategy },
    providePrimeNG({
      theme: { preset: ProdFlowPreset, options: { darkModeSelector: false } },
      translation: GERMAN_TRANSLATION,
      ripple: false,
    }),
    MessageService,
    ConfirmationService,
    provideAppInitializer(initializeApplication),
  ],
};
