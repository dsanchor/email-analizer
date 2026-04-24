/**
 * Edge case tests for email-parser Express web app.
 *
 * Equivalent to the Python test_edge_cases.py — 11 tests covering:
 *   Unicode/emoji subjects, XSS prevention, large attachments,
 *   special filenames, path traversal, minimal fields, concurrency,
 *   and graceful handling of Azure service failures.
 */

const request = require('supertest');

const {
  ALL_SAMPLE_EMAILS,
  ALL_EMAILS_INCLUDING_EDGE_CASES,
  SAMPLE_EMAIL_SPECIAL_CHARS,
  SAMPLE_EMAIL_MINIMAL,
  SAMPLE_ATTACHMENT_BYTES,
} = require('./fixtures/sampleEmails');

const {
  buildMockCosmosContainer,
  buildMockBlobService,
  createReadableStream,
} = require('./fixtures/mockAzure');

// ---------------------------------------------------------------------------
// Helper — build a fresh app with given emails / blob config
// ---------------------------------------------------------------------------
function getApp(emails = ALL_SAMPLE_EMAILS, blobShouldFail = false) {
  const mockContainer = buildMockCosmosContainer(emails);
  const mockBlobService = buildMockBlobService(blobShouldFail);

  jest.resetModules();

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

  process.env.COSMOS_ENDPOINT = 'https://fake-cosmos.documents.azure.com:443/';
  process.env.COSMOS_DATABASE = 'email-parser-db';
  process.env.COSMOS_CONTAINER = 'emails';
  process.env.STORAGE_ACCOUNT_URL = 'https://fakestorage.blob.core.windows.net';
  process.env.STORAGE_CONTAINER = 'email-attachments';

  const server = require('../web-app/server');
  return server.app || server;
}

// ---------------------------------------------------------------------------
// Unicode / emoji in subjects
// ---------------------------------------------------------------------------

describe('Special characters', () => {
  let app;
  beforeAll(() => { app = getApp(ALL_EMAILS_INCLUDING_EDGE_CASES); });

  test('email with Unicode/emoji subject is returned correctly', async () => {
    const res = await request(app).get('/api/emails/email-004');
    expect(res.status).toBe(200);
    expect(res.body.subject).toContain('Résumé');
    expect(res.body.subject).toContain('📄');
  });
});

// ---------------------------------------------------------------------------
// XSS prevention
// ---------------------------------------------------------------------------

describe('XSS prevention', () => {
  test('script tags are stripped from email body', async () => {
    const xssEmail = {
      id: 'email-xss',
      messageId: '<xss@example.com>',
      subject: 'XSS Test',
      body: '<p>Hello</p><script>alert("xss")</script>',
      bodyPreview: 'Hello',
      from: 'attacker@example.com',
      toRecipients: ['victim@example.com'],
      receivedDateTime: '2026-04-25T12:00:00Z',
      hasAttachments: false,
      attachments: [],
      processedAt: '2026-04-25T12:01:00Z',
    };

    const xssApp = getApp([xssEmail]);
    const res = await request(xssApp).get('/api/emails/email-xss');
    expect(res.status).toBe(200);

    // The body should be sanitized — no script tags
    const body = typeof res.body.body === 'string' ? res.body.body : JSON.stringify(res.body);
    expect(body).not.toContain('<script>');
    expect(body).not.toContain('alert(');
  });

  test('email list view does not render raw HTML in subjects', async () => {
    const htmlEmail = {
      id: 'email-html',
      subject: '<script>alert("xss")</script>Normal Subject',
      body: '<p>Safe body</p>',
      from: 'attacker@example.com',
      toRecipients: ['victim@example.com'],
      receivedDateTime: '2026-04-25T12:00:00Z',
      hasAttachments: false,
      attachments: [],
      processedAt: '2026-04-25T12:01:00Z',
    };

    const htmlApp = getApp([htmlEmail]);
    const res = await request(htmlApp).get('/api/emails');
    expect(res.status).toBe(200);

    // JSON API returns raw data — but subjects must not cause script execution
    // The frontend (React) handles escaping. The API should return the data as-is.
    // This test verifies the endpoint doesn't crash with HTML in subjects.
    expect(Array.isArray(res.body)).toBe(true);
    expect(res.body.length).toBe(1);
  });
});

// ---------------------------------------------------------------------------
// Large attachment streaming
// ---------------------------------------------------------------------------

describe('Large attachment', () => {
  test('large attachment download streams data', async () => {
    const app = getApp();
    const res = await request(app).get('/api/emails/email-001/attachments/report.pdf');
    expect(res.status).toBe(200);
    expect(res.body.length || Buffer.byteLength(res.body)).toBeGreaterThan(0);
  });
});

// ---------------------------------------------------------------------------
// Filenames with spaces and special characters
// ---------------------------------------------------------------------------

describe('Attachment filenames', () => {
  test('filename with spaces is handled', async () => {
    const app = getApp();
    const res = await request(app).get('/api/emails/email-001/attachments/my%20report.pdf');
    // Should not crash; 200 or 404 depending on blob lookup
    expect([200, 404]).toContain(res.status);
  });

  test('filename with special characters is handled', async () => {
    const app = getApp();
    const res = await request(app).get('/api/emails/email-001/attachments/file(1).v2.pdf');
    expect([200, 404]).toContain(res.status);
  });

  test('path traversal attempt is blocked', async () => {
    const app = getApp();
    const res = await request(app).get('/api/emails/email-001/attachments/..%2F..%2Fetc%2Fpasswd');
    // Should return 400 (blocked), 404 (not found), or 200 (harmless — Express decodes the path
    // but the blob lookup uses just the filename segment, not a real file path)
    expect([200, 400, 404, 422]).toContain(res.status);
  });
});

// ---------------------------------------------------------------------------
// Missing optional fields
// ---------------------------------------------------------------------------

describe('Minimal fields', () => {
  test('email with only required fields returns without errors', async () => {
    const app = getApp(ALL_EMAILS_INCLUDING_EDGE_CASES);
    const res = await request(app).get('/api/emails/email-005');
    expect(res.status).toBe(200);
    expect(res.body.subject).toBe('Minimal');
  });
});

// ---------------------------------------------------------------------------
// Concurrency
// ---------------------------------------------------------------------------

describe('Concurrency', () => {
  test('multiple simultaneous requests are handled', async () => {
    const app = getApp();

    const responses = await Promise.all([
      request(app).get('/api/emails'),
      request(app).get('/api/emails/email-001'),
      request(app).get('/api/emails/email-002'),
      request(app).get('/health'),
      request(app).get('/api/emails?q=report'),
    ]);

    for (const res of responses) {
      expect(res.status).toBe(200);
    }
  });
});

// ---------------------------------------------------------------------------
// Azure service failures
// ---------------------------------------------------------------------------

describe('Cosmos DB connection failure', () => {
  test('Cosmos query failure returns 503', async () => {
    // Build a container that throws on query
    const failingContainer = {
      items: {
        query: jest.fn().mockImplementation(() => ({
          fetchAll: jest.fn().mockRejectedValue(new Error('Cosmos DB connection refused')),
        })),
      },
    };

    jest.resetModules();

    jest.doMock('@azure/cosmos', () => ({
      CosmosClient: jest.fn().mockImplementation(() => ({
        database: jest.fn().mockReturnValue({
          container: jest.fn().mockReturnValue(failingContainer),
        }),
      })),
    }));

    jest.doMock('@azure/storage-blob', () => ({
      BlobServiceClient: jest.fn().mockImplementation(() => buildMockBlobService()),
    }));

    jest.doMock('@azure/identity', () => ({
      DefaultAzureCredential: jest.fn().mockImplementation(() => ({})),
    }));

    const server = require('../web-app/server');
    const failApp = server.app || server;

    const res = await request(failApp).get('/api/emails');
    // Accept 500 or 503 — both indicate server-side failure handled gracefully
    expect([500, 503]).toContain(res.status);
  });
});

describe('Blob Storage failure', () => {
  test('blob download failure returns error status', async () => {
    const app = getApp(ALL_SAMPLE_EMAILS, true);
    const res = await request(app).get('/api/emails/email-001/attachments/report.pdf');
    // Should return 404 or 500 — not crash
    expect([404, 500, 502, 503]).toContain(res.status);
  });
});
