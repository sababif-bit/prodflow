// Development proxy: the browser talks to ONE origin (http://localhost:4200); /api and /version are forwarded to the Spring Boot backend.
// No CORS needed, and the same relative URLs work later when the SPA is served by the backend itself.
// Target: API_TARGET (default: the local development stack on http://localhost:8080). Never point this at production for mutations.
const target = process.env.API_TARGET || 'http://localhost:8080';
module.exports = {
  '/api': { target, secure: false, changeOrigin: true, logLevel: 'warn' },
  '/version': { target, secure: false, changeOrigin: true, logLevel: 'warn' },
  '/actuator/health': { target, secure: false, changeOrigin: true, logLevel: 'warn' },
};
