/** @type {import('jest').Config} */
module.exports = {
  testEnvironment: 'node',
  testMatch: ['**/*.test.js'],
  setupFiles: ['./setup.js'],
  verbose: true,
  collectCoverageFrom: ['../web-app/server.js'],
};
