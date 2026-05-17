
## Known issues
- Gemini free tier quota returning limit:0 on Aditya's API key (Google project provisioning issue, not a code bug). The GoogleProvider implementation is correct and verified via build. To resolve: either enable billing on the Google Cloud project or wait for free-tier auto-provisioning (~24 hours after API enable).
