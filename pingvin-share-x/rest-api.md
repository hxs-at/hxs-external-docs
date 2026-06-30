# HXS Pingvin Share X REST API

Tested with Pingvin Share version: 1.13.0

Last verified: 2026-06-30

## Purpose

This page explains how to use Pingvin Share X as an **automation target**.

It focuses on the main API flows needed to:

- sign in
- create shares
- upload files
- complete shares and generate links
- inspect and manage existing shares

This is not a full upstream API reference. This document describes the API behavior verified on the HXS-hosted Pingvin Share instance. It may differ from future upstream versions.

## Base URL and authentication

Most write operations require an authenticated session. Pingvin Share X uses **cookie-based authentication**:

1. `POST /api/auth/signIn`
2. Store the response cookies
3. Reuse those cookies for the following API calls

For automation scripts, keep the same cookie jar/session across all requests.

This API is intended for server-side automation. Browser-based integrations from third-party domains may require additional CORS and cookie configuration.

## Important behavior

### Share lifecycle

A share is not usable immediately after `POST /api/shares`.

The normal flow is:

1. Create share metadata
2. Upload one or more files
3. Call `POST /api/shares/<shareId>/complete`
4. Use the final share link

Before the `complete` step:

- uploads are still open
- recipients may not yet have received notification emails
- the public share should be treated as incomplete

### Expiration format

Use one of these relative formats:

- `7-days`
- `1-day`
- `12-hours`
- `30-minutes`
- `never`

The format is `<number>-<unit>`, for example `14-days`. Common units are `minutes`, `hours`, `days`, `weeks`, `months`, and `years`.

Do not use human-readable strings such as `7 days`.

## Common automation flow

### 1. Sign in

Endpoint:

```text
POST /api/auth/signIn
```

Request body:

```json
{
  "username": "user",
  "password": "your-password"
}
```

Result:

- Pingvin sets `access_token` and `refresh_token` cookies
- later requests must include those cookies

Example:

```bash
curl -c cookies.txt -X POST "https://files.example.com/api/auth/signIn" \
  -H "Content-Type: application/json" \
  -d '{"username":"user","password":"your-password"}'
```

### 2. Create a share

Endpoint:

```text
POST /api/shares
```

Typical request body with password protection:

```json
{
  "id": "auto123abc",
  "name": "Automated Upload",
  "expiration": "7-days",
  "description": "Created by script",
  "recipients": [
    "recipient@example.com"
  ],
  "security": {
    "password": "share-password"
  }
}
```

Important fields:

| Field | Meaning |
| --- | --- |
| `id` | Share ID used in the final URL, 3 to 50 characters |
| `name` | Display name shown in Pingvin, 3 to 30 characters |
| `expiration` | Relative time such as `7-days`, or `never` |
| `description` | Optional text shown with the share, max. 512 characters |
| `recipients` | Optional recipient email list |
| `security` | Optional password/max-views settings |

`security` details:

| Field | Meaning |
| --- | --- |
| `password` | Optional share password, 3 to 30 characters |
| `maxViews` | Optional maximum number of share token requests/view unlock events |

Notes:

- `id` must be 3 to 50 characters, unique, and may only contain letters, numbers, underscores, and hyphens
- `name` must be between 3 and 30 characters
- `expiration` must be API format like `7-days`
- `security` can be `{}` when no protection is needed
- `recipients` can be an empty array if you do not want Pingvin to send recipient emails

Example without password protection:

```bash
curl -b cookies.txt -X POST "https://files.example.com/api/shares" \
  -H "Content-Type: application/json" \
  -d '{
    "id":"auto123abc",
    "name":"Automated Upload",
    "expiration":"7-days",
    "description":"Created by script",
    "recipients":["recipient@example.com"],
    "security":{}
  }'
```

### 3. Upload files

Endpoint:

```text
POST /api/shares/<shareId>/files?id=<fileId>&name=<fileName>&chunkIndex=<n>&totalChunks=<m>
```

Pingvin uploads files in **chunks**.

Required query parameters:

| Parameter | Meaning |
| --- | --- |
| `id` | Internal file identifier for this upload |
| `name` | Original file name. Must be URL-encoded when it contains spaces, umlauts, or special characters. |
| `chunkIndex` | Zero-based index of the current chunk |
| `totalChunks` | Total number of chunks for this file |

Behavior:

- single small file: `chunkIndex=0`, `totalChunks=1`
- large file: send multiple requests with the same `id` and `name`
- use `Content-Type: application/octet-stream`
- send the file chunk using your HTTP client's binary upload mode
- do not wrap the file content in JSON or `multipart/form-data`
- chunks must be uploaded sequentially, starting with `chunkIndex=0`
- do not upload chunks in parallel unless this has been explicitly verified for the deployed Pingvin version and storage backend
- for S3-backed Pingvin Share instances, every non-final chunk should be at least 5 MiB because S3 multipart uploads require all parts except the last one to be at least 5 MiB

Example for a one-chunk upload:

```bash
curl -b cookies.txt -X POST \
  "https://files.example.com/api/shares/auto123abc/files?id=file1&name=test.txt&chunkIndex=0&totalChunks=1" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @test.txt
```

### 4. Complete the share

Endpoint:

```text
POST /api/shares/<shareId>/complete
```

This step:

- locks the upload
- finalizes the share
- sends recipient emails when configured
- triggers background ZIP creation when the share contains multiple files

Example:

```bash
curl -b cookies.txt -X POST "https://files.example.com/api/shares/auto123abc/complete"
```

Successful completion returns HTTP `202`.

When recipients are configured, Pingvin triggers notification emails during the complete step. A successful HTTP `202` confirms that the share was completed and the notification flow was triggered, but final mailbox delivery should be verified separately if required.

### 5. Use the resulting link

Typical public share link:

```text
https://files.example.com/s/auto123abc
```

Public share metadata and file downloads require a share token cookie. For password-protected shares, the token endpoint requires the password. For unprotected shares, call the same token endpoint without a password or with an empty JSON body.

## Share tokens for public access

Public share metadata and file downloads require a share token cookie.

Endpoint:

```text
POST /api/shares/<shareId>/token
```

For an unprotected share, use an empty JSON body:

```json
{}
```

For a password-protected share, include the share password:

```json
{
  "password": "share-password"
}
```

Result:

- returns a token
- sets a `share_<shareId>_token` cookie
- this cookie must be reused for public share metadata and file download requests

The token endpoint also increments the share view counter. If `maxViews` is configured, requesting tokens counts against that limit.

## Reading and managing shares

### List my shares

Endpoint:

```text
GET /api/shares
```

Returns completed shares belonging to the authenticated user.

Example:

```bash
curl -b cookies.txt "https://files.example.com/api/shares"
```

### Get one share

Endpoint:

```text
GET /api/shares/<shareId>
```

This endpoint returns public share data after the share is complete and accessible.

Programmatic access requires a valid `share_<shareId>_token` cookie. Obtain it first via:

```text
POST /api/shares/<shareId>/token
```

Example:

```bash
curl -c share-cookies.txt -X POST "https://files.example.com/api/shares/auto123abc/token" \
  -H "Content-Type: application/json" \
  -d '{}'

curl -b share-cookies.txt \
  "https://files.example.com/api/shares/auto123abc"
```

For authenticated owner-side automation, prefer `GET /api/shares/<shareId>/from-owner`.

### Get owner view of one share

Endpoint:

```text
GET /api/shares/<shareId>/from-owner
```

Use this when the authenticated owner needs a direct owner-only view of the share.

### Update a share

Endpoint:

```text
PATCH /api/shares/<shareId>
```

Typical use cases:

- rename share
- update description
- change expiration
- adjust security settings

Security updates support more than create-time security:

```json
{
  "security": {
    "password": "new-password",
    "removePassword": false,
    "maxViews": 25
  }
}
```

Update-time security fields:

| Field | Meaning |
| --- | --- |
| `password` | Set or replace the share password |
| `removePassword` | Remove the password entirely |
| `maxViews` | Set, replace, or clear the max view limit |

Example:

```bash
curl -b cookies.txt -X PATCH "https://files.example.com/api/shares/auto123abc" \
  -H "Content-Type: application/json" \
  -d '{
    "name":"Updated name",
    "description":"Updated by script",
    "expiration":"14-days",
    "security":{
      "maxViews":25
    }
  }'
```

### Expire a share immediately

Endpoint:

```text
POST /api/shares/<shareId>/expire
```

Use this to end access early without deleting the underlying record immediately.

### Delete a share

Endpoint:

```text
DELETE /api/shares/<shareId>
```

This removes the share and its files.

### Reopen a completed share

Endpoint:

```text
DELETE /api/shares/<shareId>/complete
```

This reverts the completion state and unlocks the share for further upload changes.

Use carefully in automation because recipients may already have received the original share link.


## Download endpoints

Public downloads use these endpoints:

- `GET /api/shares/<shareId>/files/zip`
- `GET /api/shares/<shareId>/files/<fileId>`

Before calling these endpoints programmatically, obtain a share token:

```text
POST /api/shares/<shareId>/token
```

Then reuse the returned `share_<shareId>_token` cookie for the download request.

Example for an unprotected share:

```bash
curl -c share-cookies.txt -X POST "https://files.example.com/api/shares/auto123abc/token" \
  -H "Content-Type: application/json" \
  -d '{}'

curl -b share-cookies.txt \
  "https://files.example.com/api/shares/auto123abc/files/file1" \
  -o test.txt
```

Example for a password-protected share:

```bash
curl -c share-cookies.txt -X POST "https://files.example.com/api/shares/auto123abc/token" \
  -H "Content-Type: application/json" \
  -d '{"password":"share-password"}'
```

## Share ID checks

Endpoint:

```text
GET /api/shares/isShareIdAvailable/<shareId>
```

Use this before creating a share if your automation wants predictable IDs and a clean retry strategy.

## Practical recommendations for automation

### Generate unique share IDs

Use a stable prefix plus random suffix, for example:

```text
auto-20260630-8f3c2a
```

This reduces collisions and makes support/debugging easier.

### Keep uploads idempotent where possible

A safe automation pattern is:

1. generate share ID
2. check availability
3. create share
4. upload files
5. complete share
6. store final URL in your external system

If a run fails after share creation, either:

- retry the upload to the same share, or
- delete the incomplete share and start again

## Troubleshooting

### `Invalid expiration date`

Cause:

- API payload used `7 days` instead of `7-days`

Fix:

- use API-style relative durations such as `7-days`

### Login works in browser but not in script

Check:

- password login is still enabled
- the script stores and reuses cookies
- the account is not waiting for TOTP flow

### Share exists but public link or API/download access does not work as expected

Check:

- files were actually uploaded
- `POST /complete` was called
- the share was not immediately expired
- for API/download access, a valid `share_<shareId>_token` cookie was obtained via `POST /api/shares/<shareId>/token`
- password protection is not blocking access
