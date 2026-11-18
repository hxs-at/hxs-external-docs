# HXS External Docs

Public integration documentation for HXS-hosted services. Customers, their
users and their developers read these pages directly on GitHub; there is no
website build behind it.

> This repository is **public**. Nothing internal goes in here: no hostnames,
> IP addresses, account IDs, customer or user names, tokens or screenshots
> showing them.

## Available docs

| Page | Audience | Language |
|---|---|---|
| [KI-Plattform (Open WebUI): Anleitung für Anwender](./openwebui/anleitung.md) | Users of the HXS AI platform | German |
| [AI platform (Open WebUI): user guide](./openwebui/guide.md) | Users of the HXS AI platform | English |
| [Pingvin Share X REST API](./pingvin-share-x/rest-api.md) | Developers automating file shares | English |
| [PowerShell workflow test script](./pingvin-share-x/scripts/Test-PingvinShareApi.ps1) | Developers, to check the documented API flows | English |

## Structure

One folder per service: the page itself, screenshots in `images/`, scripts in
`scripts/`.

```text
openwebui/          anleitung.md, guide.md (English) + images/
pingvin-share-x/    rest-api.md + scripts/Test-PingvinShareApi.ps1
```

The Open WebUI instances link to `openwebui/anleitung.md` (German) or
`openwebui/guide.md` (English) in a banner, so these paths must not change.
Keep both guides in step: a change to one goes into the other in the same pull request.

## Changing a page

1. Create a branch, edit the Markdown, add screenshots under the service's
   `images/` folder.
2. Check the result in the GitHub preview of the branch or pull request:
   links, images, the table of contents of the guide.
3. For the Pingvin Share X API: run the test script against a test instance
   and update "Tested with" and "Last verified" at the top of the page:

   ```powershell
   ./pingvin-share-x/scripts/Test-PingvinShareApi.ps1 -BaseUrl https://files.example.com -Username apiuser
   ```

4. Open a pull request. Merging to `main` publishes the change.
