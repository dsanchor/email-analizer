/**
 * Sample email data for tests.
 *
 * Mirrors the Python conftest.py fixtures exactly.
 */

const SAMPLE_EMAIL_WITH_ATTACHMENTS = {
  id: 'email-001',
  messageId: '<msg-001@example.com>',
  subject: 'Q4 Financial Report',
  body: '<html><body><p>Please find the Q4 report attached.</p></body></html>',
  bodyPreview: 'Please find the Q4 report attached.',
  from: 'cfo@example.com',
  toRecipients: ['team@example.com'],
  receivedDateTime: '2026-04-20T12:00:00Z',
  hasAttachments: true,
  importance: 'normal',
  conversationId: 'conv-001',
  attachments: [
    {
      name: 'report.pdf',
      contentType: 'application/pdf',
      size: 125000,
      blobPath: 'email-attachments/email-001/report.pdf',
    },
    {
      name: 'summary.docx',
      contentType: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      size: 45000,
      blobPath: 'email-attachments/email-001/summary.docx',
    },
  ],
  processedAt: '2026-04-20T12:01:00Z',
};

const SAMPLE_EMAIL_NO_ATTACHMENTS = {
  id: 'email-002',
  messageId: '<msg-002@example.com>',
  subject: 'Team standup notes',
  body: '<html><body><p>Today\'s standup went well.</p></body></html>',
  bodyPreview: "Today's standup went well.",
  from: 'pm@example.com',
  toRecipients: ['team@example.com'],
  receivedDateTime: '2026-04-21T09:00:00Z',
  hasAttachments: false,
  importance: 'normal',
  conversationId: 'conv-002',
  attachments: [],
  processedAt: '2026-04-21T09:01:00Z',
};

const SAMPLE_EMAIL_MULTIPLE_ATTACHMENTS = {
  id: 'email-003',
  messageId: '<msg-003@example.com>',
  subject: 'Design assets',
  body: '<html><body><p>Assets for the new campaign.</p></body></html>',
  bodyPreview: 'Assets for the new campaign.',
  from: 'designer@example.com',
  toRecipients: ['marketing@example.com'],
  receivedDateTime: '2026-04-22T14:30:00Z',
  hasAttachments: true,
  importance: 'high',
  conversationId: 'conv-003',
  attachments: [
    {
      name: 'logo.png',
      contentType: 'image/png',
      size: 250000,
      blobPath: 'email-attachments/email-003/logo.png',
    },
    {
      name: 'banner.jpg',
      contentType: 'image/jpeg',
      size: 500000,
      blobPath: 'email-attachments/email-003/banner.jpg',
    },
    {
      name: 'assets.zip',
      contentType: 'application/zip',
      size: 2000000,
      blobPath: 'email-attachments/email-003/assets.zip',
    },
    {
      name: 'budget.xlsx',
      contentType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      size: 75000,
      blobPath: 'email-attachments/email-003/budget.xlsx',
    },
  ],
  processedAt: '2026-04-22T14:31:00Z',
};

const SAMPLE_EMAIL_SPECIAL_CHARS = {
  id: 'email-004',
  messageId: '<msg-004@example.com>',
  subject: 'Résumé update 📄 — año 2026 «important»',
  body: '<html><body><p>Héllo wörld — special chars: &amp; &lt; &gt;</p></body></html>',
  bodyPreview: 'Héllo wörld — special chars: & < >',
  from: 'josé@example.com',
  toRecipients: ['hr@example.com'],
  receivedDateTime: '2026-04-23T10:00:00Z',
  hasAttachments: false,
  importance: 'normal',
  conversationId: 'conv-004',
  attachments: [],
  processedAt: '2026-04-23T10:01:00Z',
};

const SAMPLE_EMAIL_MINIMAL = {
  id: 'email-005',
  subject: 'Minimal',
  from: 'someone@example.com',
  receivedDateTime: '2026-04-24T08:00:00Z',
  processedAt: '2026-04-24T08:01:00Z',
};

const ALL_SAMPLE_EMAILS = [
  SAMPLE_EMAIL_WITH_ATTACHMENTS,
  SAMPLE_EMAIL_NO_ATTACHMENTS,
  SAMPLE_EMAIL_MULTIPLE_ATTACHMENTS,
];

const ALL_EMAILS_INCLUDING_EDGE_CASES = [
  ...ALL_SAMPLE_EMAILS,
  SAMPLE_EMAIL_SPECIAL_CHARS,
  SAMPLE_EMAIL_MINIMAL,
];

const SAMPLE_ATTACHMENT_BYTES = Buffer.from('%PDF-1.4 fake pdf content for testing purposes');

module.exports = {
  SAMPLE_EMAIL_WITH_ATTACHMENTS,
  SAMPLE_EMAIL_NO_ATTACHMENTS,
  SAMPLE_EMAIL_MULTIPLE_ATTACHMENTS,
  SAMPLE_EMAIL_SPECIAL_CHARS,
  SAMPLE_EMAIL_MINIMAL,
  ALL_SAMPLE_EMAILS,
  ALL_EMAILS_INCLUDING_EDGE_CASES,
  SAMPLE_ATTACHMENT_BYTES,
};
