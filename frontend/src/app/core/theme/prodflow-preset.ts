import { definePreset } from '@primeuix/themes';
import Aura from '@primeuix/themes/aura';

/**
 * Visual identity: calm "workshop" look. A steel-blue primary on cool neutral surfaces; signal colors (amber/green/red)
 * are reserved for production states and are always paired with a text label and an icon.
 */
export const ProdFlowPreset = definePreset(Aura, {
  semantic: {
    primary: {
      50: '#eff6fb',
      100: '#dbeaf5',
      200: '#bcd7ec',
      300: '#8dbcde',
      400: '#5798cb',
      500: '#347bb5',
      600: '#25619a',
      700: '#1f4f7d',
      800: '#1d4367',
      900: '#1c3a57',
      950: '#12253a',
    },
    colorScheme: {
      light: {
        primary: {
          color: '{primary.700}',
          contrastColor: '#ffffff',
          hoverColor: '{primary.800}',
          activeColor: '{primary.900}',
        },
        surface: {
          0: '#ffffff',
          50: '#f5f7fa',
          100: '#edf0f5',
          200: '#dde3ea',
          300: '#c3ccd6',
          400: '#98a4b3',
          500: '#6b7a8c',
          600: '#515f70',
          700: '#3f4a58',
          800: '#2b3440',
          900: '#1b222b',
          950: '#0f141a',
        },
      },
    },
  },
});

/** German texts for PrimeNG components (date picker, tables, dialogs). */
export const GERMAN_TRANSLATION = {
  firstDayOfWeek: 1,
  dayNames: ['Sonntag', 'Montag', 'Dienstag', 'Mittwoch', 'Donnerstag', 'Freitag', 'Samstag'],
  dayNamesShort: ['So', 'Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa'],
  dayNamesMin: ['So', 'Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa'],
  monthNames: [
    'Januar',
    'Februar',
    'März',
    'April',
    'Mai',
    'Juni',
    'Juli',
    'August',
    'September',
    'Oktober',
    'November',
    'Dezember',
  ],
  monthNamesShort: [
    'Jan',
    'Feb',
    'Mär',
    'Apr',
    'Mai',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Okt',
    'Nov',
    'Dez',
  ],
  today: 'Heute',
  clear: 'Leeren',
  weekHeader: 'KW',
  dateFormat: 'dd.mm.yy',
  accept: 'Ja',
  reject: 'Nein',
  cancel: 'Abbrechen',
  apply: 'Anwenden',
  emptyMessage: 'Keine Einträge gefunden',
  emptyFilterMessage: 'Keine Ergebnisse gefunden',
};
