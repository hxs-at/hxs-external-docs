<#
.SYNOPSIS
  Tests the documented HXS Pingvin Share X REST API workflows.

.DESCRIPTION
  This script tests the documented Pingvin Share API flows:

  - sign in
  - check share ID availability
  - create shares
  - upload files as one chunk
  - upload files as multiple chunks
  - complete shares
  - list shares
  - get public share data
  - get owner share data
  - update share metadata/security
  - reopen completed shares
  - download files
  - download ZIP files
  - create password-protected shares
  - request share tokens
  - remove share passwords
  - expire shares
  - delete shares
  - optionally trigger recipient email delivery

.PARAMETER BaseUrl
  Base URL of the Pingvin Share instance, e.g. https://files.example.com

.PARAMETER Username
  Pingvin Share username.

.PARAMETER Password
  Pingvin Share password. If omitted, the script asks interactively.

.PARAMETER RecipientEmail
  Optional email recipient used to test the documented recipients workflow.
  If omitted, the recipient email workflow is skipped.

.PARAMETER RequireManualEmailConfirmation
  If set together with RecipientEmail, the script asks you to manually confirm
  that the recipient email arrived and contains the expected share link.

.PARAMETER TestPrefix
  Prefix used for generated share IDs.

.PARAMETER WorkDir
  Local working directory for temporary test files and downloads.

.EXAMPLE
  .\Test-PingvinShareApi.ps1 -BaseUrl "https://files.example.com" -Username "apiuser"

.EXAMPLE
  .\Test-PingvinShareApi.ps1 -BaseUrl "https://files.example.com" -Username "apiuser" -Password "secret"

.EXAMPLE
  .\Test-PingvinShareApi.ps1 `
    -BaseUrl "https://files.example.com" `
    -Username "apiuser" `
    -RecipientEmail "pingvin-api-test@example.com" `
    -RequireManualEmailConfirmation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl,

    [Parameter(Mandatory = $true)]
    [string]$Username,

    [Parameter(Mandatory = $false)]
    [string]$Password,

    [Parameter(Mandatory = $false)]
    [string]$RecipientEmail,

    [Parameter(Mandatory = $false)]
    [switch]$RequireManualEmailConfirmation,

    [Parameter(Mandatory = $false)]
    [string]$TestPrefix = "api-test",

    [Parameter(Mandatory = $false)]
    [string]$WorkDir = (Join-Path $PWD "pingvin-api-test-output"),

    [Parameter(Mandatory = $false)]
    [int]$MultiChunkSplitBytes = 5242880
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -----------------------------
# Helper functions
# -----------------------------

function New-ShareTokenSession {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShareId,

        [Parameter(Mandatory = $false)]
        [string]$Password
    )

    $session = New-PingvinWebSession
    $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$ShareId/token"

    $body = @{}

    if ($Password) {
        $body.password = $Password
    }

    [void](Invoke-PingvinRequest `
        -Method POST `
        -Url $url `
        -Session $session `
        -BodyObject $body `
        -ExpectedStatus @(200, 201, 202))

    $cookies = $session.Cookies.GetCookies([uri]$script:BaseUrl)

    $expectedCookieName = "share_${ShareId}_token"
    $tokenCookie = $cookies | Where-Object { $_.Name -eq $expectedCookieName }

    if (-not $tokenCookie) {
        throw "Share token endpoint succeeded, but expected cookie '$expectedCookieName' was not stored."
    }

    return $session
}

function New-PingvinWebSession {
    try {
        return New-Object Microsoft.PowerShell.Commands.WebRequestSession
    }
    catch {
        throw "Could not create PowerShell WebRequestSession. Please use Windows PowerShell 5.1 or PowerShell 7+. Current version: $($PSVersionTable.PSVersion)"
    }
}

function ConvertFrom-SecureStringToPlainText {
    param(
        [Parameter(Mandatory = $true)]
        [securestring]$SecureString
    )

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Join-ApiUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Base,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return $Base.TrimEnd("/") + "/" + $Path.TrimStart("/")
}

function New-TestShareId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prefix,

        [Parameter(Mandatory = $true)]
        [string]$Purpose
    )

    $timestamp = Get-Date -Format "yyyyMMddHHmmss"
    $random = (New-Guid).ToString("N").Substring(0, 8)

    return "$Prefix-$Purpose-$timestamp-$random".ToLowerInvariant()
}

function New-UploadUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShareId,

        [Parameter(Mandatory = $true)]
        [string]$FileId,

        [Parameter(Mandatory = $true)]
        [string]$FileName,

        [Parameter(Mandatory = $true)]
        [int]$ChunkIndex,

        [Parameter(Mandatory = $true)]
        [int]$TotalChunks
    )

    $encodedFileId = [uri]::EscapeDataString($FileId)
    $encodedFileName = [uri]::EscapeDataString($FileName)

    return Join-ApiUrl `
        -Base $script:BaseUrl `
        -Path "/api/shares/$ShareId/files?id=$encodedFileId&name=$encodedFileName&chunkIndex=$ChunkIndex&totalChunks=$TotalChunks"
}

function Invoke-PingvinRequest {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("GET", "POST", "PATCH", "DELETE")]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $false)]
        $Session,

        [Parameter(Mandatory = $false)]
        [object]$BodyObject,

        [Parameter(Mandatory = $false)]
        [byte[]]$BodyBytes,

        [Parameter(Mandatory = $false)]
        [string]$ContentType,

        [Parameter(Mandatory = $false)]
        [int[]]$ExpectedStatus = @(200, 201, 202, 204),

        [Parameter(Mandatory = $false)]
        [string]$OutFile
    )

    $params = @{
        Uri         = $Url
        Method      = $Method
        ErrorAction = "Stop"
    }

    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $params.UseBasicParsing = $true
    }

    if ($Session) {
        $params.WebSession = $Session
    }

    if ($PSBoundParameters.ContainsKey("BodyObject")) {
        $json = $BodyObject | ConvertTo-Json -Depth 20 -Compress
        $params.Body = $json
        $params.ContentType = if ($ContentType) { $ContentType } else { "application/json" }
    }

    if ($PSBoundParameters.ContainsKey("BodyBytes")) {
        $params.Body = $BodyBytes
        $params.ContentType = if ($ContentType) { $ContentType } else { "application/octet-stream" }
    }

    if ($OutFile) {
        $params.OutFile = $OutFile
    }

    try {
        $response = Invoke-WebRequest @params

        # Important:
        # Some PowerShell versions return $null when -OutFile is used successfully.
        # In that case, consider the request successful if the output file exists.
        if ($null -eq $response) {
            if ($OutFile -and (Test-Path $OutFile)) {
                return [pscustomobject]@{
                    StatusCode = 200
                    Content    = $null
                    Headers    = $null
                    OutFile    = $OutFile
                }
            }

            throw "Invoke-WebRequest returned no response object for $Method $Url and no output file was created."
        }

        $statusCode = [int]$response.StatusCode

        if ($ExpectedStatus -notcontains $statusCode) {
            throw "Unexpected HTTP status $statusCode for $Method $Url. Expected: $($ExpectedStatus -join ', ')"
        }

        return $response
    }
    catch {
        $statusCode = $null
        $responseBody = $null

        $exception = $_.Exception

        # In StrictMode, directly accessing a missing .Response property can fail.
        # Therefore check via PSObject.Properties first.
        $responseProperty = $exception.PSObject.Properties["Response"]

        if ($responseProperty -and $responseProperty.Value) {
            $errorResponse = $responseProperty.Value

            try {
                if ($errorResponse.StatusCode) {
                    $statusCode = [int]$errorResponse.StatusCode
                }
            }
            catch {
                # Ignore status extraction errors.
            }

            try {
                $stream = $errorResponse.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $responseBody = $reader.ReadToEnd()
                    $reader.Close()
                }
            }
            catch {
                # Ignore response body extraction errors.
            }
        }

        if ($statusCode -and ($ExpectedStatus -contains $statusCode)) {
            return [pscustomobject]@{
                StatusCode = $statusCode
                Content    = $responseBody
                Headers    = $null
            }
        }

        if ($statusCode) {
            if ($responseBody) {
                throw "HTTP $statusCode for $Method $Url. Response body: $responseBody"
            }

            throw "HTTP $statusCode for $Method $Url."
        }

        throw
    }
}

function Invoke-TestStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    Write-Host ""
    Write-Host "[RUN ] $Name" -ForegroundColor Cyan

    try {
        $result = & $Action

        $script:TestResults += [pscustomobject]@{
            Name   = $Name
            Status = "PASS"
            Error  = $null
        }

        Write-Host "[PASS] $Name" -ForegroundColor Green
        return $result
    }
    catch {
        $script:TestResults += [pscustomobject]@{
            Name   = $Name
            Status = "FAIL"
            Error  = $_.Exception.Message
        }

        Write-Host "[FAIL] $Name" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        throw
    }
}

function Invoke-DownloadWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$OutFile,

        [Parameter(Mandatory = $false)]
        $Session,

        [Parameter(Mandatory = $false)]
        [int]$Retries = 10,

        [Parameter(Mandatory = $false)]
        [int]$DelaySeconds = 2
    )

    if (Test-Path $OutFile) {
        Remove-Item $OutFile -Force
    }

    for ($i = 1; $i -le $Retries; $i++) {
        try {
            [void](Invoke-PingvinRequest `
                -Method GET `
                -Url $Url `
                -Session $Session `
                -OutFile $OutFile `
                -ExpectedStatus @(200))

            if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 0)) {
                Write-Host "Downloaded file size: $((Get-Item $OutFile).Length) bytes"
                return
            }

            if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -eq 0)) {
                throw "Downloaded file exists but is empty: $OutFile"
            }

            throw "Download did not create output file: $OutFile"
        }
        catch {
            $message = $_.Exception.Message

            # These are not temporary ZIP/background-processing errors.
            # Fail immediately.
            if ($message -like "*403*" -or $message -like "*Forbidden*" -or $message -like "*share_token_required*") {
                throw "Download failed with access error. URL: $Url. Details: $message"
            }

            if ($message -like "*401*" -or $message -like "*Unauthorized*") {
                throw "Download failed with authentication error. URL: $Url. Details: $message"
            }

            if ($message -like "*404*" -or $message -like "*Not Found*") {
                throw "Download failed because the file/share was not found. URL: $Url. Details: $message"
            }

            if ($i -eq $Retries) {
                throw
            }

            Write-Host "Download not ready yet, retry $i/$Retries..." -ForegroundColor DarkYellow
            Write-Host "Last error: $message" -ForegroundColor DarkGray
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Remove-TestShare {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShareId
    )

    try {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$ShareId"

        [void](Invoke-PingvinRequest `
            -Method DELETE `
            -Url $url `
            -Session $script:AuthSession `
            -ExpectedStatus @(200, 202, 204, 404))

        Write-Host "[CLEANUP] Deleted share $ShareId" -ForegroundColor DarkGray
    }
    catch {
        Write-Host "[CLEANUP] Could not delete share $ShareId : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# -----------------------------
# Init
# -----------------------------

$script:BaseUrl = $BaseUrl.TrimEnd("/")
$script:TestResults = @()
$script:CreatedShares = @()
$script:AuthSession = New-PingvinWebSession

if (-not $Password) {
    $securePassword = Read-Host "Password for $Username" -AsSecureString
    $Password = ConvertFrom-SecureStringToPlainText -SecureString $securePassword
}

if (-not (Test-Path $WorkDir)) {
    New-Item -ItemType Directory -Path $WorkDir | Out-Null
}

Write-Host "Base URL        : $script:BaseUrl"
Write-Host "Username        : $Username"
Write-Host "WorkDir         : $WorkDir"

if ($RecipientEmail) {
    Write-Host "RecipientEmail  : $RecipientEmail"
}
else {
    Write-Host "RecipientEmail  : not set, recipient email workflow will be skipped"
}

# -----------------------------
# Test IDs and files
# -----------------------------

$basicShareId = New-TestShareId -Prefix $TestPrefix -Purpose "basic"
$multiShareId = New-TestShareId -Prefix $TestPrefix -Purpose "multi"
$protectedShareId = New-TestShareId -Prefix $TestPrefix -Purpose "protected"
$mailShareId = New-TestShareId -Prefix $TestPrefix -Purpose "mail"

$basicFileId1 = (New-Guid).ToString()
$basicFileId2 = (New-Guid).ToString()
$multiFileId = (New-Guid).ToString()
$protectedFileId = (New-Guid).ToString()
$mailFileId = (New-Guid).ToString()

$basicFileName1 = "test.txt"
$basicFileName2 = "second-file.txt"
$multiFileName = "multi chunk ae test.txt"
$protectedFileName = "protected.txt"
$mailFileName = "mail-test.txt"

$basicFilePath1 = Join-Path $WorkDir $basicFileName1
$basicFilePath2 = Join-Path $WorkDir $basicFileName2
$multiFilePath = Join-Path $WorkDir $multiFileName
$protectedFilePath = Join-Path $WorkDir $protectedFileName
$mailFilePath = Join-Path $WorkDir $mailFileName

[System.IO.File]::WriteAllText($basicFilePath1, "Hello from Pingvin API test.`n", [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($basicFilePath2, "Second file after reopening completed share.`n", [System.Text.Encoding]::UTF8)

# Multi-chunk test file:
# Use 6 MiB total with a 5 MiB first chunk.
# This is important for S3-backed Pingvin instances because S3 multipart uploads
# require every part except the last to be at least 5 MiB.
$multiTestSizeBytes = $MultiChunkSplitBytes + 1048576

$multiTestBytesForFile = New-Object byte[] $multiTestSizeBytes
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
try {
    $rng.GetBytes($multiTestBytesForFile)
}
finally {
    $rng.Dispose()
}

[System.IO.File]::WriteAllBytes($multiFilePath, $multiTestBytesForFile)

[System.IO.File]::WriteAllText($protectedFilePath, "This is a password protected test file.`n", [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($mailFilePath, "This file was created for the Pingvin recipient email test.`n", [System.Text.Encoding]::UTF8)

$basicFileBytes1 = [System.IO.File]::ReadAllBytes($basicFilePath1)
$basicFileBytes2 = [System.IO.File]::ReadAllBytes($basicFilePath2)
$multiFileBytes = [System.IO.File]::ReadAllBytes($multiFilePath)
$protectedFileBytes = [System.IO.File]::ReadAllBytes($protectedFilePath)
$mailFileBytes = [System.IO.File]::ReadAllBytes($mailFilePath)

$protectedPassword1 = "testpass123"
$protectedPassword2 = "newpass123"

try {
    # -----------------------------
    # Authentication
    # -----------------------------

    Invoke-TestStep "Sign in with cookie-based authentication" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/auth/signIn"

        [void](Invoke-PingvinRequest `
            -Method POST `
            -Url $url `
            -Session $script:AuthSession `
            -BodyObject @{
                username = $Username
                password = $Password
            } `
            -ExpectedStatus @(200, 201, 204))

        $cookies = $script:AuthSession.Cookies.GetCookies([uri]$script:BaseUrl)

        if ($cookies.Count -eq 0) {
            throw "Login succeeded but no cookies were stored in the web session."
        }

        Write-Host "Stored cookies: $($cookies.Count)"
    }

    # -----------------------------
    # Share ID availability
    # -----------------------------

    Invoke-TestStep "Check share ID availability before create" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/isShareIdAvailable/$basicShareId"

        $response = Invoke-PingvinRequest `
            -Method GET `
            -Url $url `
            -Session $script:AuthSession `
            -ExpectedStatus @(200)

        Write-Host "Availability response: $($response.Content)"
    }

    # -----------------------------
    # Basic share workflow
    # -----------------------------

    Invoke-TestStep "Create basic share" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares"

        [void](Invoke-PingvinRequest `
            -Method POST `
            -Url $url `
            -Session $script:AuthSession `
            -BodyObject @{
                id          = $basicShareId
                name        = "Automated API Test"
                expiration  = "1-day"
                description = "Created by automated PowerShell API test"
                recipients  = @()
                security    = @{}
                size        = $basicFileBytes1.Length
            } `
            -ExpectedStatus @(200, 201, 202))

        $script:CreatedShares += $basicShareId
    }

    Invoke-TestStep "Check share ID is no longer available after create" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/isShareIdAvailable/$basicShareId"

        $response = Invoke-PingvinRequest `
            -Method GET `
            -Url $url `
            -Session $script:AuthSession `
            -ExpectedStatus @(200)

        Write-Host "Availability response after create: $($response.Content)"
    }

    Invoke-TestStep "Upload one small file as single chunk" {
        $url = New-UploadUrl `
            -ShareId $basicShareId `
            -FileId $basicFileId1 `
            -FileName $basicFileName1 `
            -ChunkIndex 0 `
            -TotalChunks 1

        [void](Invoke-PingvinRequest `
            -Method POST `
            -Url $url `
            -Session $script:AuthSession `
            -BodyBytes $basicFileBytes1 `
            -ContentType "application/octet-stream" `
            -ExpectedStatus @(200, 201, 202, 204))
    }

    Invoke-TestStep "Complete basic share" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$basicShareId/complete"

        [void](Invoke-PingvinRequest `
            -Method POST `
            -Url $url `
            -Session $script:AuthSession `
            -ExpectedStatus @(202))
    }

    Invoke-TestStep "List my completed shares" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares"

        $response = Invoke-PingvinRequest `
            -Method GET `
            -Url $url `
            -Session $script:AuthSession `
            -ExpectedStatus @(200)

        if (-not $response.Content) {
            throw "List shares returned empty response."
        }

        Write-Host "List shares response length: $($response.Content.Length)"
    }

    Invoke-TestStep "Get one share via public API using share token" {
        $publicSession = New-ShareTokenSession -ShareId $basicShareId
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$basicShareId"

        $response = Invoke-PingvinRequest `
            -Method GET `
            -Url $url `
            -Session $publicSession `
            -ExpectedStatus @(200)

        if (-not $response.Content) {
            throw "Get public share returned empty response."
        }

        Write-Host "Public API access works with share token."
        Write-Host "Public browser share URL: $script:BaseUrl/s/$basicShareId"
    }

    Invoke-TestStep "Get owner view of one share" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$basicShareId/from-owner"

        $response = Invoke-PingvinRequest `
            -Method GET `
            -Url $url `
            -Session $script:AuthSession `
            -ExpectedStatus @(200)

        if (-not $response.Content) {
            throw "Owner view returned empty response."
        }
    }

    Invoke-TestStep "Download public file from unprotected basic share using share token" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$basicShareId/files/$basicFileId1"
        $outFile = Join-Path $WorkDir "download-basic-$basicFileName1"

        $downloadSession = New-ShareTokenSession -ShareId $basicShareId

        Invoke-DownloadWithRetry `
            -Url $url `
            -OutFile $outFile `
            -Session $downloadSession

        Write-Host "Downloaded to: $outFile"
    }

    Invoke-TestStep "Update basic share metadata and maxViews" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$basicShareId"

        [void](Invoke-PingvinRequest `
            -Method PATCH `
            -Url $url `
            -Session $script:AuthSession `
            -BodyObject @{
                name        = "Updated API Test"
                description = "Updated by automated PowerShell API test"
                expiration  = "2-days"
                security    = @{
                    maxViews = 25
                }
            } `
            -ExpectedStatus @(200, 201, 202, 204))
    }

    Invoke-TestStep "Reopen completed basic share" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$basicShareId/complete"

        [void](Invoke-PingvinRequest `
            -Method DELETE `
            -Url $url `
            -Session $script:AuthSession `
            -ExpectedStatus @(200, 201, 202, 204))
    }

    Invoke-TestStep "Upload replacement file after reopening share" {
        $url = New-UploadUrl `
            -ShareId $basicShareId `
            -FileId $basicFileId2 `
            -FileName $basicFileName2 `
            -ChunkIndex 0 `
            -TotalChunks 1

        [void](Invoke-PingvinRequest `
            -Method POST `
            -Url $url `
            -Session $script:AuthSession `
            -BodyBytes $basicFileBytes2 `
            -ContentType "application/octet-stream" `
            -ExpectedStatus @(200, 201, 202, 204))

        Write-Host "Uploaded replacement file ID: $basicFileId2"
    }

    Invoke-TestStep "Delete old file from reopened basic share" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$basicShareId/files/$basicFileId1"

        [void](Invoke-PingvinRequest `
            -Method DELETE `
            -Url $url `
            -Session $script:AuthSession `
            -ExpectedStatus @(200, 201, 202, 204))

        Write-Host "Deleted old file ID from reopened share: $basicFileId1"
    }

    Invoke-TestStep "Complete reopened basic share again" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$basicShareId/complete"

        [void](Invoke-PingvinRequest `
            -Method POST `
            -Url $url `
            -Session $script:AuthSession `
            -ExpectedStatus @(202))
    }

    Invoke-TestStep "Get owner view after completing replaced-file share" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$basicShareId/from-owner"

        $response = Invoke-PingvinRequest `
            -Method GET `
            -Url $url `
            -Session $script:AuthSession `
            -ExpectedStatus @(200)

        if (-not $response.Content) {
            throw "Owner view after completing replaced-file share returned empty response."
        }

        Write-Host "Owner view after completing replaced-file share response length: $($response.Content.Length)"
    }

    # -----------------------------
    # Multi-chunk workflow
    # -----------------------------

    Invoke-TestStep "Create multi-chunk share" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares"

        [void](Invoke-PingvinRequest `
            -Method POST `
            -Url $url `
            -Session $script:AuthSession `
            -BodyObject @{
                id          = $multiShareId
                name        = "Automated Multi Chunk API Test"
                expiration  = "1-day"
                description = "Created by automated PowerShell API test"
                recipients  = @()
                security    = @{}
                size        = $multiFileBytes.Length
            } `
            -ExpectedStatus @(200, 201, 202))

        $script:CreatedShares += $multiShareId
    }

    Invoke-TestStep "Upload file in two chunks with URL-encoded filename" {
        $splitIndex = $MultiChunkSplitBytes

        if ($multiFileBytes.Length -le $splitIndex) {
            throw "Multi-chunk test file is too small. File size: $($multiFileBytes.Length), split size: $splitIndex"
        }

        Write-Host "Multi-chunk file size : $($multiFileBytes.Length) bytes"
        Write-Host "Chunk 0 size          : $splitIndex bytes"
        Write-Host "Chunk 1 size          : $($multiFileBytes.Length - $splitIndex) bytes"

        $chunk1 = New-Object byte[] $splitIndex
        [Array]::Copy($multiFileBytes, 0, $chunk1, 0, $splitIndex)

        $chunk2Length = $multiFileBytes.Length - $splitIndex
        $chunk2 = New-Object byte[] $chunk2Length
        [Array]::Copy($multiFileBytes, $splitIndex, $chunk2, 0, $chunk2Length)

        $url1 = New-UploadUrl `
            -ShareId $multiShareId `
            -FileId $multiFileId `
            -FileName $multiFileName `
            -ChunkIndex 0 `
            -TotalChunks 2

        $url2 = New-UploadUrl `
            -ShareId $multiShareId `
            -FileId $multiFileId `
            -FileName $multiFileName `
            -ChunkIndex 1 `
            -TotalChunks 2

        [void](Invoke-PingvinRequest `
            -Method POST `
            -Url $url1 `
            -Session $script:AuthSession `
            -BodyBytes $chunk1 `
            -ContentType "application/octet-stream" `
            -ExpectedStatus @(200, 201, 202, 204))

        [void](Invoke-PingvinRequest `
            -Method POST `
            -Url $url2 `
            -Session $script:AuthSession `
            -BodyBytes $chunk2 `
            -ContentType "application/octet-stream" `
            -ExpectedStatus @(200, 201, 202, 204))
    }

    Invoke-TestStep "Complete multi-chunk share" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$multiShareId/complete"

        [void](Invoke-PingvinRequest `
            -Method POST `
            -Url $url `
            -Session $script:AuthSession `
            -ExpectedStatus @(202))
    }

    Invoke-TestStep "Download ZIP from multi-chunk share using share token" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$multiShareId/files/zip"
        $outFile = Join-Path $WorkDir "download-$multiShareId.zip"

        $zipSession = New-ShareTokenSession -ShareId $multiShareId

        Invoke-DownloadWithRetry `
            -Url $url `
            -OutFile $outFile `
            -Session $zipSession `
            -Retries 15 `
            -DelaySeconds 2

        Write-Host "Downloaded ZIP to: $outFile"
    }

    # -----------------------------
    # Password-protected share workflow
    # -----------------------------

    Invoke-TestStep "Create password-protected share" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares"

        [void](Invoke-PingvinRequest `
            -Method POST `
            -Url $url `
            -Session $script:AuthSession `
            -BodyObject @{
                id          = $protectedShareId
                name        = "Automated Protected API Test"
                expiration  = "1-day"
                description = "Created by automated PowerShell API test"
                recipients  = @()
                security    = @{
                    password = $protectedPassword1
                }
                size        = $protectedFileBytes.Length
            } `
            -ExpectedStatus @(200, 201, 202))

        $script:CreatedShares += $protectedShareId
    }

    Invoke-TestStep "Upload file to password-protected share" {
        $url = New-UploadUrl `
            -ShareId $protectedShareId `
            -FileId $protectedFileId `
            -FileName $protectedFileName `
            -ChunkIndex 0 `
            -TotalChunks 1

        [void](Invoke-PingvinRequest `
            -Method POST `
            -Url $url `
            -Session $script:AuthSession `
            -BodyBytes $protectedFileBytes `
            -ContentType "application/octet-stream" `
            -ExpectedStatus @(200, 201, 202, 204))
    }

    Invoke-TestStep "Complete password-protected share" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$protectedShareId/complete"

        [void](Invoke-PingvinRequest `
            -Method POST `
            -Url $url `
            -Session $script:AuthSession `
            -ExpectedStatus @(202))
    }

    $publicProtectedSession = New-PingvinWebSession

    Invoke-TestStep "Request share token using correct password" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$protectedShareId/token"

        $response = Invoke-PingvinRequest `
            -Method POST `
            -Url $url `
            -Session $publicProtectedSession `
            -BodyObject @{
                password = $protectedPassword1
            } `
            -ExpectedStatus @(200, 201, 202)

        if ($response.Content) {
            Write-Host "Token response length: $($response.Content.Length)"
        }
    }

    Invoke-TestStep "Download protected file using share token cookie" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$protectedShareId/files/$protectedFileId"
        $outFile = Join-Path $WorkDir "download-protected-$protectedFileName"

        Invoke-DownloadWithRetry `
            -Url $url `
            -OutFile $outFile `
            -Session $publicProtectedSession

        Write-Host "Downloaded protected file to: $outFile"
    }

    Invoke-TestStep "Replace protected share password via PATCH" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$protectedShareId"

        [void](Invoke-PingvinRequest `
            -Method PATCH `
            -Url $url `
            -Session $script:AuthSession `
            -BodyObject @{
                security = @{
                    password       = $protectedPassword2
                    removePassword = $false
                }
            } `
            -ExpectedStatus @(200, 201, 202, 204))
    }

    Invoke-TestStep "Request share token using replaced password" {
        $newPublicProtectedSession = New-PingvinWebSession
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$protectedShareId/token"

        [void](Invoke-PingvinRequest `
            -Method POST `
            -Url $url `
            -Session $newPublicProtectedSession `
            -BodyObject @{
                password = $protectedPassword2
            } `
            -ExpectedStatus @(200, 201, 202))
    }

    Invoke-TestStep "Remove password from protected share via PATCH" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$protectedShareId"

        [void](Invoke-PingvinRequest `
            -Method PATCH `
            -Url $url `
            -Session $script:AuthSession `
            -BodyObject @{
                security = @{
                    removePassword = $true
                }
            } `
            -ExpectedStatus @(200, 201, 202, 204))
    }

    Invoke-TestStep "Download formerly protected file without password using new share token" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$protectedShareId/files/$protectedFileId"
        $outFile = Join-Path $WorkDir "download-unprotected-after-remove-$protectedFileName"

        $unprotectedAfterRemovalSession = New-ShareTokenSession -ShareId $protectedShareId

        Invoke-DownloadWithRetry `
            -Url $url `
            -OutFile $outFile `
            -Session $unprotectedAfterRemovalSession

        Write-Host "Downloaded formerly protected file to: $outFile"
    }

    # -----------------------------
    # Optional recipient email workflow
    # -----------------------------

    if ($RecipientEmail) {
        Invoke-TestStep "Create share with recipient email" {
            $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares"

            [void](Invoke-PingvinRequest `
                -Method POST `
                -Url $url `
                -Session $script:AuthSession `
                -BodyObject @{
                    id          = $mailShareId
                    name        = "Recipient Email API Test"
                    expiration  = "1-day"
                    description = "Created by automated PowerShell API test to trigger recipient email"
                    recipients  = @($RecipientEmail)
                    security    = @{}
                    size        = $mailFileBytes.Length
                } `
                -ExpectedStatus @(200, 201, 202))

            $script:CreatedShares += $mailShareId
        }

        Invoke-TestStep "Upload file to recipient email share" {
            $url = New-UploadUrl `
                -ShareId $mailShareId `
                -FileId $mailFileId `
                -FileName $mailFileName `
                -ChunkIndex 0 `
                -TotalChunks 1

            [void](Invoke-PingvinRequest `
                -Method POST `
                -Url $url `
                -Session $script:AuthSession `
                -BodyBytes $mailFileBytes `
                -ContentType "application/octet-stream" `
                -ExpectedStatus @(200, 201, 202, 204))
        }

        Invoke-TestStep "Complete recipient email share and trigger notification email" {
            $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$mailShareId/complete"

            [void](Invoke-PingvinRequest `
                -Method POST `
                -Url $url `
                -Session $script:AuthSession `
                -ExpectedStatus @(202))

            Write-Host ""
            Write-Host "Recipient email should have been triggered for:" -ForegroundColor Yellow
            Write-Host "  Recipient : $RecipientEmail" -ForegroundColor Yellow
            Write-Host "  Share URL : $script:BaseUrl/s/$mailShareId" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Important: HTTP 202 confirms that the share was completed." -ForegroundColor Yellow
            Write-Host "It does not prove final mailbox delivery." -ForegroundColor Yellow
        }

        if ($RequireManualEmailConfirmation) {
            Invoke-TestStep "Manual confirmation of recipient email delivery" {
                Write-Host ""
                Write-Host "Please check the mailbox now:" -ForegroundColor Cyan
                Write-Host "  $RecipientEmail" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "Expected share link:" -ForegroundColor Cyan
                Write-Host "  $script:BaseUrl/s/$mailShareId" -ForegroundColor Cyan
                Write-Host ""

                $answer = Read-Host "Did the recipient email arrive and contain the expected share link? Type 'yes' to confirm"

                if ($answer -ne "yes") {
                    throw "Manual email delivery confirmation failed or was not confirmed."
                }
            }
        }
    }
    else {
        Write-Host ""
        Write-Host "[SKIP] Recipient email workflow skipped because -RecipientEmail was not provided." -ForegroundColor Yellow
    }

    # -----------------------------
    # Expire and delete workflows
    # -----------------------------

    Invoke-TestStep "Expire basic share immediately" {
        $url = Join-ApiUrl -Base $script:BaseUrl -Path "/api/shares/$basicShareId/expire"

        [void](Invoke-PingvinRequest `
            -Method POST `
            -Url $url `
            -Session $script:AuthSession `
            -ExpectedStatus @(200, 201, 202, 204))
    }

    Invoke-TestStep "Delete basic share" {
        Remove-TestShare -ShareId $basicShareId
        $script:CreatedShares = @($script:CreatedShares | Where-Object { $_ -ne $basicShareId })
    }

    Invoke-TestStep "Delete multi-chunk share" {
        Remove-TestShare -ShareId $multiShareId
        $script:CreatedShares = @($script:CreatedShares | Where-Object { $_ -ne $multiShareId })
    }

    Invoke-TestStep "Delete protected share" {
        Remove-TestShare -ShareId $protectedShareId
        $script:CreatedShares = @($script:CreatedShares | Where-Object { $_ -ne $protectedShareId })
    }

    if ($RecipientEmail) {
        Invoke-TestStep "Delete recipient email test share" {
            Remove-TestShare -ShareId $mailShareId
            $script:CreatedShares = @($script:CreatedShares | Where-Object { $_ -ne $mailShareId })
        }
    }
}
finally {
    foreach ($shareId in @($script:CreatedShares)) {
        Remove-TestShare -ShareId $shareId
    }

    Write-Host ""
    Write-Host "=============================="
    Write-Host "Test Summary"
    Write-Host "=============================="

    $script:TestResults | Format-Table -AutoSize

    $failed = @($script:TestResults | Where-Object { $_.Status -eq "FAIL" })

    if ($failed.Count -gt 0) {
        Write-Host ""
        Write-Host "One or more tests failed." -ForegroundColor Red
        exit 1
    }

    Write-Host ""
    Write-Host "All tests passed." -ForegroundColor Green
    exit 0
}