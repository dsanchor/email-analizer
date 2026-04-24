/**
 * Mock builders for Azure Cosmos DB and Blob Storage SDKs.
 *
 * These mirror the Python conftest.py _build_mock_cosmos_container()
 * and _build_mock_blob_service() helpers.
 */

const { SAMPLE_ATTACHMENT_BYTES } = require('./sampleEmails');

/**
 * Build a mock Cosmos container whose query_items returns the given emails.
 * The mock simulates Cosmos SDK v4 fetchAll() semantics.
 */
function buildMockCosmosContainer(emails) {
  return {
    items: {
      query: jest.fn().mockImplementation((querySpec) => {
        let results = emails;

        if (querySpec.parameters && querySpec.parameters.length > 0) {
          for (const param of querySpec.parameters) {
            if (param.name === '@id') {
              results = emails.filter((e) => e.id === param.value);
            } else if (param.name === '@q') {
              const q = param.value.toLowerCase();
              results = emails.filter(
                (e) =>
                  (e.subject || '').toLowerCase().includes(q) ||
                  (e.from || '').toLowerCase().includes(q)
              );
            }
          }
        }

        return {
          fetchAll: jest.fn().mockResolvedValue({ resources: results }),
        };
      }),
    },
  };
}

/**
 * Build a mock BlobServiceClient.
 * When shouldFail is true, download() rejects with an error.
 */
function buildMockBlobService(shouldFail = false) {
  const blobClient = {};

  if (shouldFail) {
    blobClient.download = jest.fn().mockRejectedValue(new Error('BlobNotFound'));
  } else {
    blobClient.download = jest.fn().mockResolvedValue({
      readableStreamBody: createReadableStream(SAMPLE_ATTACHMENT_BYTES),
      contentType: 'application/pdf',
      contentLength: SAMPLE_ATTACHMENT_BYTES.length,
    });
  }

  const containerClient = {
    getBlockBlobClient: jest.fn().mockReturnValue(blobClient),
    getBlobClient: jest.fn().mockReturnValue(blobClient),
  };

  return {
    getContainerClient: jest.fn().mockReturnValue(containerClient),
    _containerClient: containerClient,
    _blobClient: blobClient,
  };
}

/**
 * Create a simple readable stream from a Buffer for blob download mocking.
 */
function createReadableStream(buffer) {
  const { Readable } = require('stream');
  return new Readable({
    read() {
      this.push(buffer);
      this.push(null);
    },
  });
}

module.exports = {
  buildMockCosmosContainer,
  buildMockBlobService,
  createReadableStream,
};
