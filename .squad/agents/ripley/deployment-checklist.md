# Content Understanding Integration — Deployment Checklist

## Pre-Deployment

- [ ] Azure Content Understanding resource provisioned
- [ ] Analyzer/classifier created and trained
- [ ] Analyzer ID obtained (e.g., `demoIbercaja`)
- [ ] Content Understanding endpoint URL ready (e.g., `https://my-cu.services.ai.azure.com`)
- [ ] Content Understanding resource ID ready (full ARM path)

## Environment Variables to Set

```bash
export CONTENT_UNDERSTANDING_ENDPOINT="https://<your-endpoint>.services.ai.azure.com"
export CONTENT_UNDERSTANDING_ANALYZER_ID="<your-analyzer-id>"
export CONTENT_UNDERSTANDING_RESOURCE_ID="/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<account-name>"
```

## Deploy

```bash
./infrastructure/deploy.sh
```

## Post-Deployment Verification

- [ ] Logic App created successfully
- [ ] Logic App has system-assigned managed identity
- [ ] Logic App MI has "Cognitive Services User" role on Content Understanding resource
- [ ] Workflow definition contains Content Understanding endpoint (check in Portal)
- [ ] Test with a PDF email attachment
- [ ] Verify `contentUnderstanding` field appears in Cosmos DB attachment object

## Testing

1. Send test email with PDF attachment to monitored inbox
2. Wait for Logic App to process
3. Check Logic App run history (should show successful run)
4. Query Cosmos DB for the email document
5. Verify attachment array contains PDF with `contentUnderstanding` field

## Troubleshooting

**If Content Understanding API call fails:**
- Check Logic App MI has Cognitive Services User role
- Verify endpoint URL is correct (no trailing slash)
- Verify analyzer ID exists
- Check Logic App run history for detailed error

**If placeholders not replaced:**
- Verify environment variables were set before running deploy.sh
- Check sed substitution in deploy script executed correctly
- Re-run deployment with correct env vars

**If role assignment fails:**
- Verify CONTENT_UNDERSTANDING_RESOURCE_ID is correct full ARM path
- Check you have Owner/User Access Administrator permissions on the resource
- Manually assign role via Azure Portal if needed

## Rollback

If integration causes issues, redeploy without Content Understanding:

```bash
unset CONTENT_UNDERSTANDING_ENDPOINT
unset CONTENT_UNDERSTANDING_ANALYZER_ID
unset CONTENT_UNDERSTANDING_RESOURCE_ID
./infrastructure/redeploy-logic-app.sh
```

This will restore original behavior (PDFs processed but not analyzed).

---

**Integration Status:** ✅ Ready for deployment  
**Backward Compatible:** Yes (optional integration)  
**Breaking Changes:** None
