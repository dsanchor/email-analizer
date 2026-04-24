/**
 * Route tests for email-parser Express web app.
 *
 * Equivalent to the Python test_app.py — 19 tests covering:
 *   GET /health           → health check
 *   GET /                 → redirect or serve SPA
 *   GET /api/emails       → email list JSON
 *   GET /api/emails/:id   → email detail JSON
 *   GET /api/emails/:id/attachments/:filename → attachment download
 */

const request = require('supertest');

const {
  ALL_SAMPLE_EMAILS,
  SAMPLE_EMAIL_WITH_ATTACHMENTS,
  SAMPLE_EMAIL_NO_ATTACHMENTS,
  SAMPLE_EMAIL_MULTIPLE_ATTACHMENTS,
  SAMPLE_ATTACHMENT_BYTES,
} = require('./fixtures/sampleEmails');

const {
  buildMockCosmosContainer,
  buildMockBlobService,
} = require('./fixtures/mockAzure');

// ---------------------------------------------------------------------------
// Mock Azure SDKs before requiring the server
// ---------------------------------------------------------------------------
let mockContainer;
let mockBlobService;

jest.mock('@azure/cosmos', () => ({
  CosmosClient: jest.fn().mockImplementation(() => ({
    database: jest.fn().mockReturnValue({
      container: jest.fn().mockReturnValue(null), // replaced per-test
    }),
  })),
}));

jest.mock('@azure/storage-blob', () => ({
  BlobServiceClient: jest.fn().mockImplementation(() => null), // replaced per-test
}));

jest.mock('@azure/identity', () => ({
  DefaultAzureCredential: jest.fn().mockImplementation(() => ({})),
}));

// ---------------------------------------------------------------------------
// App import helper — re-requires server.js with fresh mocks
// ---------------------------------------------------------------------------
let app;

/**
 * Build a test Express app with the given mock data.
 *
 * Because the server.js module likely caches Azure clients at import time,
 * we reset modules and inject fresh mocks for each test group.
 */
function getApp(emails = ALL_SAMPLE_EMAILS, blobShouldFail = false) {
  mockContainer = buildMockCosmosContainer(emails);
  mockBlobService = buildMockBlobService(blobShouldFail);

  // Override the mocked constructors to return our configured mocks
  const { CosmosClient } = require('@azure/cosmos');
  CosmosClient.mockImplementation(() => ({
    database: jest.fn().mockReturnValue({
      container: jest.fn().mockReturnValue(mockContainer),
    }),
  }));

  const { BlobServiceClient } = require('@azure/storage-blob');
  BlobServiceClient.mockImplementation(() => mockBlobService);

  // Clear cached server module so it picks up fresh mocks
  jest.resetModules();

  // Re-mock after resetModules
  jest.doMock('@azure/cosmos', () => ({
    CosmosClient: jest.fn().mockImplementation(() => ({
      database: jest.fn().mockReturnValue({
        container: jest.fn().mockReturnValue(mockContainer),
      }),
    })),
  }));

  jest.doMock('@azure/storage-blob', () => ({
    BlobServiceClient: jest.fn().mockImplementation(() => mockBlobService),
  }));

  jest.doMock('@azure/identity', () => ({
    DefaultAzureCredential: jest.fn().mockImplementation(() => ({})),
  }));

  // Set env vars for server.js
  process.env.COSMOS_ENDPOINT = 'https://fake-cosmos.documents.azure.com:443/';
  process.env.COSMOS_DATABASE = 'email-parser-db';
  process.env.COSMOS_CONTAINER = 'emails';
  process.env.STORAGE_ACCOUNT_URL = 'https://fakestorage.blob.core.windows.net';
  process.env.STORAGE_CONTAINER = 'email-attachments';

  const server = require('../web-app/server');
  return server.app || server;
}

// ---------------------------------------------------------------------------
// Health endpoint
// ---------------------------------------------------------------------------

describe('Health endpoint', () => {
  let app;
  beforeAll(() => { app = getApp(); });

  test('GET /health returns 200 with status healthy', async () => {
    const res = await request(app).get('/health');
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ status: 'healthy' });
  });
});

// ---------------------------------------------------------------------------
// Root redirect
// ---------------------------------------------------------------------------

describe('Root redirect', () => {
  let app;
  beforeAll(() => { app = getApp(); });

  test('GET / redirects or serves SPA', async () => {
    const res = await request(app).get('/');
    // Accept redirect (301/302/307/308) to /emails, or 200 serving SPA
    if (res.status >= 300 && res.status < 400) {
      expect(res.headers.location).toMatch(/\/emails|\/api\/emails|\//);
    } else {
      expect(res.status).toBe(200);
    }
  });
});

// ---------------------------------------------------------------------------
// Email list
// ---------------------------------------------------------------------------

describe('Email list', () => {
  let app;
  beforeAll(() => { app = getApp(); });

  test('GET /api/emails returns 200 with email list JSON', async () => {
    const res = await request(app).get('/api/emails');
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body)).toBe(true);
    expect(res.body.length).toBe(3);

    const subjects = res.body.map((e) => e.subject);
    expect(subjects).toContain('Q4 Financial Report');
    expect(subjects).toContain('Team standup notes');
    expect(subjects).toContain('Design assets');
  });

  test('GET /api/emails?q=report returns filtered results', async () => {
    const res = await request(app).get('/api/emails?q=report');
    expect(res.status).toBe(200);
    expect(Array.isArray(res.body)).toBe(true);
    // Should match "Q4 Financial Report"
    expect(res.body.length).toBeGreaterThanOrEqual(1);
    expect(res.body.some((e) => e.subject.includes('Report'))).toBe(true);
  });

  test('GET /api/emails?page=2 handles pagination parameter', async () => {
    const res = await request(app).get('/api/emails?page=2');
    expect(res.status).toBe(200);
  });

  test('GET /api/emails with empty DB returns 200 and empty array', async () => {
    const emptyApp = getApp([]);
    const res = await request(emptyApp).get('/api/emails');
    expect(res.status).toBe(200);
    expect(res.body).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// Email detail
// ---------------------------------------------------------------------------

describe('Email detail', () => {
  let app;
  beforeAll(() => { app = getApp(); });

  test('GET /api/emails/:id returns 200 with email JSON', async () => {
    const res = await request(app).get('/api/emails/email-001');
    expect(res.status).toBe(200);
    expect(res.body.id).toBe('email-001');
    expect(res.body.subject).toBe('Q4 Financial Report');
    expect(res.body.from).toBe('cfo@example.com');
    expect(res.body.attachments).toBeDefined();
    expect(res.body.attachments.length).toBe(2);
  });

  test('GET /api/emails/nonexistent returns 404', async () => {
    const res = await request(app).get('/api/emails/nonexistent-id');
    expect(res.status).toBe(404);
  });

  test('GET /api/emails/:id returns email without attachments', async () => {
    const res = await request(app).get('/api/emails/email-002');
    expect(res.status).toBe(200);
    expect(res.body.id).toBe('email-002');
    expect(res.body.subject).toBe('Team standup notes');
    expect(res.body.attachments).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// Attachment download
// ---------------------------------------------------------------------------

describe('Attachment download', () => {
  let app;
  beforeAll(() => { app = getApp(); });

  test('GET /api/emails/:id/attachments/:filename returns 200 with binary data', async () => {
    const res = await request(app).get('/api/emails/email-001/attachments/report.pdf');
    expect(res.status).toBe(200);
    expect(res.body.length || Buffer.byteLength(res.body)).toBeGreaterThan(0);
  });

  test('attachment download returns 404 when blob fails', async () => {
    const failApp = getApp(ALL_SAMPLE_EMAILS, true);
    const res = await request(failApp).get('/api/emails/email-001/attachments/nonexistent.pdf');
    expect(res.status).toBe(404);
  });

  test('attachment download returns 404 when email does not exist', async () => {
    const failApp = getApp(ALL_SAMPLE_EMAILS, true);
    const res = await request(failApp).get('/api/emails/nonexistent/attachments/file.pdf');
    expect(res.status).toBe(404);
  });

  test('attachment Content-Disposition header is set', async () => {
    const res = await request(app).get('/api/emails/email-001/attachments/report.pdf');
    expect(res.status).toBe(200);
    const cd = res.headers['content-disposition'] || '';
    expect(cd).toContain('report.pdf');
  });

  // Various file type downloads
  test('PDF attachment download works', async () => {
    const res = await request(app).get('/api/emails/email-001/attachments/report.pdf');
    expect(res.status).toBe(200);
  });

  test('DOCX attachment download works', async () => {
    const res = await request(app).get('/api/emails/email-001/attachments/summary.docx');
    expect(res.status).toBe(200);
  });

  test('PNG attachment download works', async () => {
    const res = await request(app).get('/api/emails/email-003/attachments/logo.png');
    expect(res.status).toBe(200);
  });

  test('JPG attachment download works', async () => {
    const res = await request(app).get('/api/emails/email-003/attachments/banner.jpg');
    expect(res.status).toBe(200);
  });

  test('ZIP attachment download works', async () => {
    const res = await request(app).get('/api/emails/email-003/attachments/assets.zip');
    expect(res.status).toBe(200);
  });

  test('XLSX attachment download works', async () => {
    const res = await request(app).get('/api/emails/email-003/attachments/budget.xlsx');
    expect(res.status).toBe(200);
  });
});
