// Development proxy: the browser talks to ONE origin (http://localhost:4200); /api, /version and /config.json are forwarded to the
// Spring Boot backend. No CORS needed, and the very same relative URLs work in production where the backend serves the SPA itself.
// /config.json (runtime configuration: where to sign in) is answered by the backend from its OIDC issuer, so the compiled assets
// and this repository contain no environment-specific value.
// Target: API_TARGET (default: the local development stack on http://localhost:8080). Never point this at production for mutations.
const target = process.env.API_TARGET || 'http://localhost:8080';
const forward = { target, secure: false, changeOrigin: true, logLevel: 'warn' };
module.exports = {
  '/api': forward,
  '/version': forward,
  '/config.json': forward,
  '/actuator/health': forward,
};
