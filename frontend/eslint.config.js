// ESLint (flat config): TypeScript + Angular rules, and the Angular template accessibility rules for the (inline) templates.
const { defineConfig, globalIgnores } = require('eslint/config');
const tseslint = require('typescript-eslint');
const angular = require('angular-eslint');

module.exports = defineConfig([
  globalIgnores([
    'dist/**',
    '.angular/**',
    'node_modules/**',
    'playwright-report/**',
    'test-results/**',
  ]),
  {
    files: ['**/*.ts'],
    extends: [
      tseslint.configs.recommended,
      tseslint.configs.stylistic,
      angular.configs.tsRecommended,
    ],
    processor: angular.processInlineTemplates,
    rules: {
      '@angular-eslint/directive-selector': [
        'error',
        { type: 'attribute', prefix: 'app', style: 'camelCase' },
      ],
      '@angular-eslint/component-selector': [
        'error',
        { type: 'element', prefix: 'app', style: 'kebab-case' },
      ],
      '@typescript-eslint/no-explicit-any': 'error',
      '@typescript-eslint/consistent-type-definitions': ['error', 'interface'],
      'no-console': ['error', { allow: ['error'] }],
    },
  },
  {
    files: ['**/*.html'],
    extends: [angular.configs.templateRecommended, angular.configs.templateAccessibility],
    rules: {},
  },
  {
    // specs and browser tests: fakes legitimately use looser typing and the tests print nothing
    files: ['**/*.spec.ts', 'e2e/**/*.ts', 'e2e-prodstack/**/*.ts', 'playwright*.ts'],
    rules: {
      '@typescript-eslint/no-explicit-any': 'off',
      '@typescript-eslint/no-non-null-assertion': 'off',
    },
  },
]);
