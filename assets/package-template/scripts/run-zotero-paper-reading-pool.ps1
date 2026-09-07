param(
    [string]$ConfigFile,
    [string]$WorkerId = "worker-01",
    [switch]$QueueOnly,
    [switch]$QueueStatus,
    [switch]$Once,
    [string]$RunId,
    [int]$MaxRunningPerCollectionOverride = 0
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$packageDir = Split-Path -Parent $scriptDir
if (-not $ConfigFile) { $ConfigFile = Join-Path $packageDir 'configs\paper-reading-pool-config.json' }
if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "Config file not found: $ConfigFile" }
$ConfigFile = (Resolve-Path -LiteralPath $ConfigFile).Path
$config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
$runtimeCommon = Join-Path $scriptDir 'pool-runtime-common.ps1'
if (-not (Test-Path -LiteralPath $runtimeCommon)) { throw "Runtime helper not found: $runtimeCommon" }
. $runtimeCommon
$defaults = Get-PoolDefaults -PackageDir $packageDir
$identity = Get-PoolProjectIdentity -Config $config -PackageDir $packageDir

function Resolve-ConfiguredPath {
    param([Parameter(Mandatory = $true)][string]$PathValue, [string]$BasePath = $packageDir)
    $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
    if ([System.IO.Path]::IsPathRooted($expanded)) { return $expanded }
    return (Join-Path $BasePath $expanded)
}

function Resolve-Executable {
    param(
        [string]$ConfiguredValue,
        [string[]]$CommandNames = @(),
        [string[]]$FallbackPaths = @(),
        [string]$DisplayName = 'executable'
    )

    if ($ConfiguredValue) {
        $expanded = [Environment]::ExpandEnvironmentVariables($ConfiguredValue.Trim())
        $looksLikePath = [System.IO.Path]::IsPathRooted($expanded) -or $expanded.Contains('\') -or $expanded.Contains('/')
        if ($looksLikePath) {
            $candidatePath = if ([System.IO.Path]::IsPathRooted($expanded)) { $expanded } else { Join-Path $root $expanded }
            if (Test-Path -LiteralPath $candidatePath) { return (Resolve-Path -LiteralPath $candidatePath).Path }
            throw "$DisplayName configured at '$candidatePath' was not found. Remove the setting or correct the path."
        }
        $configuredCommand = Get-Command $expanded -ErrorAction SilentlyContinue
        if ($configuredCommand) { return $configuredCommand.Source }
        throw "$DisplayName command '$expanded' was not found. Remove the setting or install it."
    }

    foreach ($commandName in $CommandNames) {
        $command = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($command) { return $command.Source }
    }
    foreach ($fallbackPath in $FallbackPaths) {
        if ($fallbackPath -and (Test-Path -LiteralPath $fallbackPath)) { return (Resolve-Path -LiteralPath $fallbackPath).Path }
    }
    throw "$DisplayName not found. Set the corresponding executable path in the config or add it to PATH."
}

function Resolve-Python {
    $configured = if ($config.pythonExecutable) { [string]$config.pythonExecutable } else { $null }
    $bundledPython = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    return Resolve-Executable -ConfiguredValue $configured -CommandNames @('python', 'py') -FallbackPaths @($bundledPython) -DisplayName 'python.exe'
}

function Resolve-Node {
    $configured = if ($config.nodeExecutable) { [string]$config.nodeExecutable } else { $null }
    $codexBin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    $fallbackNodes = @()
    if (Test-Path -LiteralPath $codexBin) {
        $fallbackNodes = @(Get-ChildItem -LiteralPath $codexBin -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'node.exe' } |
            Where-Object { Test-Path -LiteralPath $_ })
    }
    return Resolve-Executable -ConfiguredValue $configured -CommandNames @('node') -FallbackPaths $fallbackNodes -DisplayName 'node.exe'
}

function Resolve-Codex {
    $configured = if ($config.codexExecutable) { [string]$config.codexExecutable } else { $null }
    $fallback = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\codex.exe'
    return Resolve-Executable -ConfiguredValue $configured -CommandNames @('codex') -FallbackPaths @($fallback) -DisplayName 'codex.exe'
}

$root = $identity.Root
$studyRoot = Resolve-ConfiguredPath ([string](Get-PoolConfigValue -Config $config -Defaults $defaults -Name 'studyRoot' -Fallback 'study-paper')) $root
$logRoot = Resolve-ConfiguredPath ([string](Get-PoolConfigValue -Config $config -Defaults $defaults -Name 'logRoot' -Fallback 'logs')) $root
$queueFile = Resolve-ConfiguredPath ([string](Get-PoolConfigValue -Config $config -Defaults $defaults -Name 'queueFile' -Fallback 'queue\paper-reading-pool-queue.json')) $root
$dataRoot = Resolve-ConfiguredPath ([string](Get-PoolConfigValue -Config $config -Defaults $defaults -Name 'outputDataRoot' -Fallback 'study-data')) $root
$mutexName = Get-PoolQueueMutexName -Config $config -Identity $identity
$maxAttempts = Get-PoolConfigInt -Config $config -Defaults $defaults -Name 'maxAttempts' -Fallback 3
$leaseHours = Get-PoolConfigInt -Config $config -Defaults $defaults -Name 'leaseHours' -Fallback 3
$workerSleepSeconds = Get-PoolConfigInt -Config $config -Defaults $defaults -Name 'workerSleepSeconds' -Fallback 30
$maxRunningPerCollection = if ($MaxRunningPerCollectionOverride -gt 0) { $MaxRunningPerCollectionOverride } else { Get-PoolConfigInt -Config $config -Defaults $defaults -Name 'maxRunningPerCollection' -Fallback 1 }
$pdfChunkingEnabled = Get-PoolConfigBool -Config $config -Defaults $defaults -Name 'pdfChunkingEnabled' -Fallback $true
$pdfMaxCharsPerChunk = Get-PoolConfigInt -Config $config -Defaults $defaults -Name 'pdfMaxCharsPerChunk' -Fallback 18000
$pdfChunkOverlapChars = Get-PoolConfigInt -Config $config -Defaults $defaults -Name 'pdfChunkOverlapChars' -Fallback 1200
$pdfMaxPagesPerChunk = Get-PoolConfigInt -Config $config -Defaults $defaults -Name 'pdfMaxPagesPerChunk' -Fallback 4
$pdfMaxPromptChars = Get-PoolConfigInt -Config $config -Defaults $defaults -Name 'pdfMaxPromptChars' -Fallback 180000
$requestedRunId = [string]$RunId
$runId = Get-PoolRunId -RequestedRunId $RunId

function Resolve-CodexWireApi {
    param(
        [Parameter(Mandatory = $true)][string]$Model,
        [string]$ConfiguredWireApi = 'auto'
    )

    $wireApi = if ($ConfiguredWireApi) { $ConfiguredWireApi.Trim().ToLowerInvariant() } else { 'auto' }
    if ($wireApi -eq 'response') { $wireApi = 'responses' }
    if ($wireApi -in @('responses', 'chat')) { return $wireApi }

    if ($Model -match '^(?i:gpt)') { return 'responses' }
    return 'chat'
}

function Get-CodexRuntimeConfig {
    $currentConfig = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $extraArgs = @()
    if ($currentConfig.codexExtraArgs) {
        foreach ($arg in @($currentConfig.codexExtraArgs)) {
            if ($null -ne $arg -and [string]$arg -ne '') { $extraArgs += [string]$arg }
        }
    }
    $model = if ($currentConfig.codexModel) { [string]$currentConfig.codexModel } else { 'mimo-v2.5' }
    $configuredWireApi = if ($currentConfig.PSObject.Properties.Name -contains 'codexWireApi') { [string]$currentConfig.codexWireApi } else { 'auto' }
    $wireApi = Resolve-CodexWireApi -Model $model -ConfiguredWireApi $configuredWireApi
    [pscustomobject]@{
        Model = $model
        ModelProvider = if ($currentConfig.codexModelProvider) { [string]$currentConfig.codexModelProvider } else { 'custom' }
        ReasoningEffort = if ($currentConfig.codexReasoningEffort) { [string]$currentConfig.codexReasoningEffort } else { 'xhigh' }
        WireApi = $wireApi
        ConfiguredWireApi = $configuredWireApi
        AskForApproval = if ($currentConfig.codexAskForApproval) { [string]$currentConfig.codexAskForApproval } else { 'never' }
        Sandbox = if ($currentConfig.codexSandbox) { [string]$currentConfig.codexSandbox } else { 'workspace-write' }
        EnableSearch = if ($null -ne $currentConfig.codexEnableSearch) { [bool]$currentConfig.codexEnableSearch } else { $true }
        ChatApiBaseUrl = if ($currentConfig.chatApiBaseUrl) { [string]$currentConfig.chatApiBaseUrl } else { $null }
        ChatCompletionsUrl = if ($currentConfig.chatCompletionsUrl) { [string]$currentConfig.chatCompletionsUrl } else { $null }
        ChatApiKeyEnv = if ($currentConfig.chatApiKeyEnv) { [string]$currentConfig.chatApiKeyEnv } else { 'OPENAI_API_KEY' }
        ChatApiKey = if ($currentConfig.chatApiKey) { [string]$currentConfig.chatApiKey } else { $null }
        ChatTimeoutSeconds = if ($currentConfig.chatTimeoutSeconds) { [int]$currentConfig.chatTimeoutSeconds } else { 900 }
        ChatTemperature = if ($null -ne $currentConfig.chatTemperature -and [string]$currentConfig.chatTemperature -ne '') { [double]$currentConfig.chatTemperature } else { $null }
        ExtraArgs = $extraArgs
    }
}

function Get-TomlStringValue {
    param([string]$Text, [string]$Name)

    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match "^\s*$([regex]::Escape($Name))\s*=\s*[""'](?<value>[^""']+)[""']") {
            return $matches.value
        }
    }
    return $null
}

function Get-CodexProviderSection {
    param([Parameter(Mandatory = $true)][string]$ProviderName)

    $codexConfigPath = Join-Path $env:USERPROFILE '.codex\config.toml'
    if (-not (Test-Path -LiteralPath $codexConfigPath)) { return $null }

    $text = Get-Content -LiteralPath $codexConfigPath -Raw -Encoding UTF8
    $escapedProvider = [regex]::Escape($ProviderName)
    $match = [regex]::Match($text, "(?ms)^\[model_providers\.$escapedProvider\]\s*(?<body>.*?)(?=^\[|\z)")
    if ($match.Success) { return $match.Groups['body'].Value }
    return $null
}

function Get-ChatCompletionProviderConfig {
    param([Parameter(Mandatory = $true)]$CodexConfig)

    $baseUrl = $CodexConfig.ChatApiBaseUrl
    $apiKey = $null
    if ($CodexConfig.ChatApiKeyEnv) {
        $apiKey = [Environment]::GetEnvironmentVariable([string]$CodexConfig.ChatApiKeyEnv)
    }
    if (-not $apiKey -and $CodexConfig.ChatApiKey) { $apiKey = [string]$CodexConfig.ChatApiKey }

    $providerSection = Get-CodexProviderSection -ProviderName $CodexConfig.ModelProvider
    if ($providerSection) {
        if (-not $baseUrl) { $baseUrl = Get-TomlStringValue -Text $providerSection -Name 'base_url' }
        if (-not $apiKey) { $apiKey = Get-TomlStringValue -Text $providerSection -Name 'experimental_bearer_token' }
    }

    if (-not $baseUrl -and $CodexConfig.ChatCompletionsUrl) {
        $uri = [Uri]$CodexConfig.ChatCompletionsUrl
        $baseUrl = $uri.GetLeftPart([UriPartial]::Authority)
    }
    if (-not $baseUrl -and $env:OPENAI_BASE_URL) { $baseUrl = $env:OPENAI_BASE_URL }
    if (-not $apiKey) { throw "Chat API key not found. Set $($CodexConfig.ChatApiKeyEnv) or experimental_bearer_token in ~/.codex/config.toml." }
    if (-not $baseUrl -and -not $CodexConfig.ChatCompletionsUrl) { throw "Chat API base URL not found. Set chatApiBaseUrl in config or base_url in ~/.codex/config.toml." }

    $endpoint = if ($CodexConfig.ChatCompletionsUrl) {
        [string]$CodexConfig.ChatCompletionsUrl
    } else {
        $baseUrl.TrimEnd('/') + '/chat/completions'
    }

    [pscustomobject]@{
        Endpoint = $endpoint
        ApiKey = $apiKey
    }
}

function Invoke-ChatCompletionForPrompt {
    param(
        [Parameter(Mandatory = $true)]$CodexConfig,
        [Parameter(Mandatory = $true)][string]$PromptFile,
        [Parameter(Mandatory = $true)][string]$LastMessageFile,
        [Parameter(Mandatory = $true)][string]$StdoutLogFile,
        [Parameter(Mandatory = $true)]$Utf8NoBom
    )

    try {
        $provider = Get-ChatCompletionProviderConfig -CodexConfig $CodexConfig
        $node = Resolve-Node
        $helperFile = "$StdoutLogFile.chat.mjs"
        $nodeScript = @'
import fs from "node:fs/promises";

const endpoint = process.env.CHAT_ENDPOINT;
const apiKey = process.env.CHAT_API_KEY;
const model = process.env.CHAT_MODEL;
const promptFile = process.env.CHAT_PROMPT_FILE;
const lastMessageFile = process.env.CHAT_LAST_MESSAGE_FILE;
const stdoutLogFile = process.env.CHAT_STDOUT_LOG_FILE;
const timeoutMs = Number(process.env.CHAT_TIMEOUT_SECONDS || "900") * 1000;
const temperature = process.env.CHAT_TEMPERATURE;

async function writeLog(text) {
  await fs.writeFile(stdoutLogFile, text, "utf8");
}

async function main() {
  const prompt = await fs.readFile(promptFile, "utf8");
  const started = Date.now();
  const startLine = `CHAT_COMPLETIONS START endpoint=${endpoint} model=${model} prompt_chars=${prompt.length}`;
  await writeLog(`${startLine}\n`);

  const body = {
    model,
    messages: [{ role: "user", content: prompt }],
    stream: false,
  };
  if (temperature !== undefined && temperature !== "") {
    body.temperature = Number(temperature);
  }

  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(timeoutMs),
  });

  const responseText = await response.text();
  if (!response.ok) {
    await writeLog(`${startLine}\nERROR: HTTP ${response.status} ${response.statusText}\n${responseText}\n`);
    return 1;
  }

  const parsed = JSON.parse(responseText);
  const first = parsed.choices?.[0];
  const message = first?.message?.content ?? first?.text;
  if (!message) {
    await writeLog(`${startLine}\nERROR: chat completion response did not contain choices[0].message.content.\n${responseText}\n`);
    return 1;
  }

  await fs.writeFile(lastMessageFile, message, "utf8");
  const elapsed = Math.round((Date.now() - started) / 100) / 10;
  await writeLog(`${startLine}\nCHAT_COMPLETIONS OK status=${response.status} elapsed_seconds=${elapsed}\n${message}`);
  return 0;
}

try {
  process.exitCode = await main();
} catch (error) {
  await fs.appendFile(stdoutLogFile, `ERROR: chat completion helper crashed endpoint=${endpoint} model=${model}\n${error?.stack || error?.message || String(error)}\nCAUSE=${error?.cause?.code || ''} ${error?.cause?.message || ''}\n`, 'utf8');
  process.exitCode = 1;
}
'@
        [System.IO.File]::WriteAllText($helperFile, $nodeScript, $Utf8NoBom)

        $previousEnv = @{
            CHAT_ENDPOINT = $env:CHAT_ENDPOINT
            CHAT_API_KEY = $env:CHAT_API_KEY
            CHAT_MODEL = $env:CHAT_MODEL
            CHAT_PROMPT_FILE = $env:CHAT_PROMPT_FILE
            CHAT_LAST_MESSAGE_FILE = $env:CHAT_LAST_MESSAGE_FILE
            CHAT_STDOUT_LOG_FILE = $env:CHAT_STDOUT_LOG_FILE
            CHAT_TIMEOUT_SECONDS = $env:CHAT_TIMEOUT_SECONDS
            CHAT_TEMPERATURE = $env:CHAT_TEMPERATURE
        }
        try {
            $env:CHAT_ENDPOINT = $provider.Endpoint
            $env:CHAT_API_KEY = $provider.ApiKey
            $env:CHAT_MODEL = $CodexConfig.Model
            $env:CHAT_PROMPT_FILE = $PromptFile
            $env:CHAT_LAST_MESSAGE_FILE = $LastMessageFile
            $env:CHAT_STDOUT_LOG_FILE = $StdoutLogFile
            $env:CHAT_TIMEOUT_SECONDS = [string]$CodexConfig.ChatTimeoutSeconds
            $env:CHAT_TEMPERATURE = if ($null -ne $CodexConfig.ChatTemperature) { [string]$CodexConfig.ChatTemperature } else { '' }

            $oldEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $helperOutput = & $node $helperFile 2>&1
                $helperExitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $oldEap
            }

            if ($helperOutput) {
                Add-Content -LiteralPath $StdoutLogFile -Encoding UTF8 -Value (($helperOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
            }
            return $helperExitCode
        } finally {
            foreach ($name in $previousEnv.Keys) {
                [Environment]::SetEnvironmentVariable($name, $previousEnv[$name], 'Process')
            }
        }
    } catch {
        $responseBody = ''
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $responseBody = $_.ErrorDetails.Message }
        try {
            if ($_.Exception.Response) {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $responseBody = $reader.ReadToEnd()
                }
            }
        } catch {}
        $errorText = "ERROR: chat completion failed endpoint=chat model=$($CodexConfig.Model)" + [Environment]::NewLine + $_.Exception.Message
        if ($responseBody) { $errorText += [Environment]::NewLine + $responseBody }
        [System.IO.File]::WriteAllText($StdoutLogFile, $errorText, $Utf8NoBom)
        return 1
    }
}

function Get-ZoteroLocalApiBaseUrl {
    $configured = if ($config.zoteroLocalApiBaseUrl) { [string]$config.zoteroLocalApiBaseUrl } else { [string]$env:ZOTERO_LOCAL_BASE_URL }
    if (-not $configured) { $configured = 'http://127.0.0.1:23119' }
    $configured = $configured.TrimEnd('/')
    if ($configured.EndsWith('/api/users/0', [StringComparison]::OrdinalIgnoreCase)) {
        $configured = $configured.Substring(0, $configured.Length - '/api/users/0'.Length).TrimEnd('/')
    }
    return $configured
}

function Invoke-ZoteroLocalApiText {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $baseUrl = Get-ZoteroLocalApiBaseUrl
    $relative = if ($RelativePath.StartsWith('/')) { $RelativePath } else { '/' + $RelativePath }
    $uri = $baseUrl + '/api/users/0' + $relative
    $request = [System.Net.HttpWebRequest]::Create($uri)
    $request.Method = 'GET'
    $request.Proxy = $null
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000
    $request.Headers['Zotero-API-Version'] = '3'
    $response = $null
    $stream = $null
    $reader = $null
    try {
        $response = $request.GetResponse()
        $stream = $response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        return $reader.ReadToEnd().Trim()
    } catch {
        $detail = $_.Exception.Message
        try {
            if ($_.Exception.Response) {
                $errorStream = $_.Exception.Response.GetResponseStream()
                if ($errorStream) {
                    $errorReader = New-Object System.IO.StreamReader($errorStream)
                    $errorBody = $errorReader.ReadToEnd()
                    if ($errorBody) { $detail += ': ' + $errorBody.Trim() }
                    $errorReader.Dispose()
                    $errorStream.Dispose()
                }
            }
        } catch {}
        throw "Zotero local API request failed ($uri): $detail"
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Resolve-ZoteroStyleCache {
    $candidates = @()
    if ($config.zoteroStyleCandidates) {
        foreach ($candidate in @($config.zoteroStyleCandidates)) {
            if ($candidate) { $candidates += Resolve-ConfiguredPath ([string]$candidate) $root }
        }
    }
    $candidates += (Join-Path $env:USERPROFILE 'Zotero\zoterostyle.json')
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate) { return $candidate } }
    return $null
}

function Resolve-ZoteroHelper {
    $configured = if ($config.zoteroHelperPath) { [string]$config.zoteroHelperPath } else { [string]$env:ZOTERO_HELPER_PATH }
    if ($configured) {
        $expanded = [Environment]::ExpandEnvironmentVariables($configured.Trim())
        $candidatePath = if ([System.IO.Path]::IsPathRooted($expanded)) { $expanded } else { Join-Path $root $expanded }
        if (Test-Path -LiteralPath $candidatePath) { return (Resolve-Path -LiteralPath $candidatePath).Path }
        throw "Configured Zotero helper was not found: $candidatePath"
    }
    $candidateRoot = Join-Path $env:USERPROFILE '.codex\plugins\cache\openai-curated\zotero'
    if (-not (Test-Path -LiteralPath $candidateRoot)) { return $null }
    $helper = Get-ChildItem -LiteralPath $candidateRoot -Recurse -Filter 'zotero.py' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like '*\skills\zotero\scripts\zotero.py' } |
        Select-Object -First 1
    if ($helper) { return $helper.FullName }
    return $null
}

function Resolve-ZoteroAttachmentFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$AttachmentKey,
        [Parameter(Mandatory = $true)][string]$PythonExe,
        [string]$OptionalHelper
    )

    $directError = $null
    try {
        $escapedKey = [Uri]::EscapeDataString($AttachmentKey)
        $raw = Invoke-ZoteroLocalApiText -RelativePath "/items/$escapedKey/file/view/url"
        if ($raw) {
            $fileUrl = $raw
            try {
                $decoded = $raw | ConvertFrom-Json
                if ($decoded -is [string]) { $fileUrl = [string]$decoded }
                elseif ($decoded.url) { $fileUrl = [string]$decoded.url }
                elseif ($decoded.path) { $fileUrl = [string]$decoded.path }
            } catch {}
            $path = Convert-FileUrlToPath $fileUrl
            if ($path) { return $path }
            $directError = "Zotero returned a non-local file URL: $fileUrl"
        } else {
            $directError = 'Zotero returned an empty file URL.'
        }
    } catch {
        $directError = $_.Exception.Message
    }

    if ($OptionalHelper) {
        try {
            $helperOutput = & $PythonExe $OptionalHelper file-url $AttachmentKey 2>&1
            if ($LASTEXITCODE -eq 0) {
                $path = Convert-FileUrlToPath (($helperOutput | Select-Object -First 1) -as [string])
                if ($path) { return $path }
            }
        } catch {}
    }

    if ($directError) { Write-SchedulerLog "attachment file path lookup failed for ${AttachmentKey}: $directError" }
    return $null
}

function Get-StyleRankSummary {
    param([string]$StyleCachePath, [string]$PublicationTitle)
    if ([string]::IsNullOrWhiteSpace($PublicationTitle)) { return 'not found' }
    if ([string]::IsNullOrWhiteSpace($StyleCachePath) -or -not (Test-Path -LiteralPath $StyleCachePath)) { return 'not configured; journal quartile lookup skipped' }
    try {
        $style = Get-Content -LiteralPath $StyleCachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $property = $style.PSObject.Properties | Where-Object { $_.Name -eq $PublicationTitle } | Select-Object -First 1
        if (-not $property -or -not $property.Value.rank) { return "not found for $PublicationTitle" }
        $rank = $property.Value.rank
        return "Journal=$PublicationTitle; IF=$($rank.sciif); SCI=$($rank.sci); CAS major=$($rank.sciUp); CAS minor=$($rank.sciUpSmall); EI=$($rank.eii)"
    } catch {
        return "lookup failed: $($_.Exception.Message)"
    }
}

function Convert-FileUrlToPath {
    param([string]$FileUrl)
    if (-not $FileUrl) { return $null }
    $value = $FileUrl.Trim()
    if (Test-Path -LiteralPath $value) { return (Resolve-Path -LiteralPath $value).Path }
    try {
        $uri = [System.Uri]::new($value)
        if ($uri.IsFile) { return $uri.LocalPath }
    } catch {}
    if ([System.IO.Path]::IsPathRooted($value) -and (Test-Path -LiteralPath $value)) {
        return (Resolve-Path -LiteralPath $value).Path
    }
    return $null
}

function Get-DelimitedBlock {
    param([string]$Text, [string]$StartMarker, [string]$EndMarker)
    if (-not $Text) { return $null }
    $pattern = "(?s)$([regex]::Escape($StartMarker))\s*(.*?)\s*$([regex]::Escape($EndMarker))"
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value.Trim()
}

function Repair-ReadingNoteDate {
    param([Parameter(Mandatory = $true)][string]$Markdown, [Parameter(Mandatory = $true)][string]$GeneratedAt)

    $escapedGeneratedAt = [regex]::Escape($GeneratedAt)
    $dateRowPattern = '(?m)^(\|\s*\*\*[^|]*Date\*\*\s*\|\s*)(.*?)(\s*\|\s*)$'
    $dateRowWithExpectedValue = '(?m)^\|\s*\*\*[^|]*Date\*\*\s*\|\s*' + $escapedGeneratedAt + '\s*\|\s*$'

    if ([regex]::IsMatch($Markdown, $dateRowWithExpectedValue)) {
        return $Markdown
    }
    if ([regex]::IsMatch($Markdown, $dateRowPattern)) {
        return [regex]::Replace($Markdown, $dateRowPattern, '${1}' + $GeneratedAt + '${3}', 1)
    }

    throw "Generated note is missing the Basic Information Date row."
}

function Get-FirstAuthorLastName {
    param($Creators)
    $first = @($Creators) | Where-Object { $_ } | Select-Object -First 1
    if (-not $first) { return 'Unknown' }
    $first = ([string]$first).Trim()
    if ($first.Contains(',')) { $name = $first.Split(',')[0].Trim() }
    elseif ($first -match '^([\p{IsCJKUnifiedIdeographs}]{2,8})') { $name = $matches[1] }
    else {
        $parts = $first -split '\s+'
        $name = $parts[$parts.Count - 1]
    }
    $name = [regex]::Replace($name, '[^\p{L}\p{N}_-]', '')
    if (-not $name) { return 'Unknown' }
    if ($name.Length -gt 24) { $name = $name.Substring(0, 24) }
    return $name
}

function Get-TitleKeywordSlug {
    param([string]$Title)
    if (-not $Title) { return 'Untitled' }
    $stopWords = @('the','and','for','with','from','into','onto','that','this','these','those','using','based','study','effect','effects','method','methods','prepared','preparation','properties')
    $tokens = [regex]::Matches($Title, '[\p{IsCJKUnifiedIdeographs}]{2,10}|[A-Za-z0-9]{3,}') | ForEach-Object { $_.Value } |
        Where-Object { $stopWords -notcontains $_.ToLowerInvariant() } | Select-Object -First 6
    if (-not $tokens -or @($tokens).Count -eq 0) { $tokens = [regex]::Matches($Title, '[\p{IsCJKUnifiedIdeographs}]{2,10}|[A-Za-z0-9]{3,}') | ForEach-Object { $_.Value } | Select-Object -First 6 }
    $slug = (@($tokens) -join '-')
    if (-not $slug) { return 'Untitled' }
    return $slug
}

function ConvertTo-SafeFileName {
    param([string]$Value)
    $leaf = Split-Path -Leaf $Value
    $safe = $leaf -replace '[\\/:*?"<>|]', '_'
    $safe = ($safe -replace '\s+', ' ').Trim()
    if (-not $safe) { $safe = 'reading-note.md' }
    if ($safe.Length -gt 180) {
        $extension = [System.IO.Path]::GetExtension($safe)
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($safe)
        $safe = $stem.Substring(0, [Math]::Min(170, $stem.Length)).Trim() + $extension
    }
    return $safe
}

function Export-PdfChunks {
    param([string]$PythonExe, [string]$PdfPath, [string]$OutputPath)
    if (-not $PdfPath) { return [pscustomobject]@{ Ok = $false; Code = 'file_missing'; Detail = 'No local PDF path was resolved.' } }
    if (-not (Test-Path -LiteralPath $PdfPath)) { return [pscustomobject]@{ Ok = $false; Code = 'file_missing'; Detail = "PDF file does not exist: $PdfPath" } }
    if (-not $pdfChunkingEnabled) { return [pscustomobject]@{ Ok = $false; Code = 'pdf_extract_failed'; Detail = 'PDF chunking is disabled.' } }
    $extractor = Join-Path $scriptDir 'extract-pdf-chunks.py'
    if (-not (Test-Path -LiteralPath $extractor)) { return [pscustomobject]@{ Ok = $false; Code = 'pdf_extract_failed'; Detail = "Chunk extractor not found: $extractor" } }
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $PythonExe $extractor $PdfPath $OutputPath '--max-chars' ([string]$pdfMaxCharsPerChunk) '--overlap-chars' ([string]$pdfChunkOverlapChars) '--max-pages' ([string]$pdfMaxPagesPerChunk) 2>&1
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldEap }
    if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
        $detail = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
        return [pscustomobject]@{ Ok = $false; Code = 'pdf_extract_failed'; Detail = $detail }
    }
    try {
        $document = Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $document.chunks -or @($document.chunks).Count -eq 0) { return [pscustomobject]@{ Ok = $false; Code = 'pdf_extract_failed'; Detail = 'PDF extractor returned zero chunks.' } }
        return [pscustomobject]@{ Ok = $true; Code = 'pdf_ready'; Detail = "pages=$($document.pageCount) chunks=$(@($document.chunks).Count)"; Document = $document }
    } catch {
        return [pscustomobject]@{ Ok = $false; Code = 'pdf_extract_failed'; Detail = "Chunk JSON could not be parsed: $($_.Exception.Message)" }
    }
}

if (-not $requestedRunId) {
    Invoke-PoolProjectMutex -Config $config -Identity $identity -Body {
        if (Test-PoolRunReservation -Config $config -Identity $identity -ExcludeRunId $runId) {
            throw "Another run is already reserved for project '$($identity.ProjectId)'. Stop it or wait for its reservation to expire."
        }
        $active = @(Get-PoolActiveWorkerStates -Config $config -Identity $identity)
        if ($active.Count -gt 0) {
            $activeText = ($active | ForEach-Object { "$($_.workerId) pid=$($_.pid) run=$($_.runId)" }) -join '; '
            throw "Active workers already exist for project '$($identity.ProjectId)': $activeText"
        }
        New-PoolRunState -Config $config -Identity $identity -RunId $runId -WorkerIds @($WorkerId) | Out-Null
    }
}

$styleCacheFile = Resolve-ZoteroStyleCache
$zoteroDataDir = if ($styleCacheFile) { Split-Path -Parent $styleCacheFile } else { $root }
New-Item -ItemType Directory -Force -Path $studyRoot | Out-Null
New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
$schedulerLog = Join-Path $logRoot 'scheduler.log'
$queueManagerFile = Join-Path $scriptDir 'pool-queue-manager.py'

$env:NO_PROXY = 'localhost,127.0.0.1'
$env:no_proxy = 'localhost,127.0.0.1'
$env:PYTHONUTF8 = '1'
$env:PYTHONIOENCODING = 'utf-8'
$env:FASTMCP_SHOW_SERVER_BANNER = 'false'
$env:ZOTERO_MCP_LOG_LEVEL = 'ERROR'
$env:FASTMCP_LOG_LEVEL = 'ERROR'

function Write-SchedulerLog {
    param([string]$Message)
    $safeMessage = if (Get-PoolConfigBool -Config $config -Defaults $defaults -Name 'redactSensitivePaths' -Fallback $true) { ConvertTo-PoolPrivacySafeText -Text $Message -RootPath $root -AdditionalPaths @($zoteroDataDir) } else { $Message }
    $line = "$(Get-Date -Format s) [$WorkerId] $safeMessage$([Environment]::NewLine)"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    for ($attempt = 1; $attempt -le 8; $attempt++) {
        try {
            [System.IO.File]::AppendAllText($schedulerLog, $line, $utf8NoBom)
            return
        } catch {
            Start-Sleep -Milliseconds (150 * $attempt)
        }
    }
    # Logging must never fail the paper task.
}
function ConvertTo-SafePathPart { param([string]$Value) $safe = $Value -replace '[\\/:*?"<>|]', '_' ; if (-not $safe) { return '_' } ; return $safe.Trim() }

function Get-TextForPrompt {
    param([string]$Path, [int]$MaxChars = 60000)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return '' }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ($text.Length -le $MaxChars) { return $text }
    $headChars = [Math]::Min([int]($MaxChars * 0.65), $text.Length)
    $tailChars = [Math]::Min($MaxChars - $headChars, $text.Length - $headChars)
    return $text.Substring(0, $headChars) + "`n`n[... PDF text truncated by worker ...]`n`n" + $text.Substring($text.Length - $tailChars)
}

function Get-ChunksForPrompt {
    param([Parameter(Mandatory = $true)]$Document, [int]$MaxChars = 180000)
    $builder = New-Object System.Text.StringBuilder
    $chunks = @($Document.chunks)
    $omitted = 0
    $nl = [Environment]::NewLine
    foreach ($chunk in $chunks) {
        $block = "<<<PDF_CHUNK id=$($chunk.chunkId) pages=$($chunk.pageStart)-$($chunk.pageEnd) section=$($chunk.section)>>>" + $nl + [string]$chunk.text + $nl + "<<<END_PDF_CHUNK>>>" + $nl + $nl
        if (($builder.Length + $block.Length) -le $MaxChars) { [void]$builder.Append($block) } else { $omitted++ }
    }
    if ($omitted -gt 0) { [void]$builder.Append("[PDF_CHUNKS_OMITTED=$omitted DUE_TO_PROMPT_LIMIT; DO NOT INVENT EVIDENCE FOR OMITTED CHUNKS]" + $nl) }
    return $builder.ToString().Trim()
}

function Invoke-StudyDataWriter {
    param([Parameter(Mandatory = $true)][string]$PythonExe, [Parameter(Mandatory = $true)][string]$RecordFile)
    $writer = Join-Path $scriptDir 'write-study-data.py'
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $PythonExe $writer '--record-file' $RecordFile '--data-root' $dataRoot 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldEap }
    if ($code -ne 0) { throw "Study JSONL writer failed: $output" }
}

function Invoke-WithQueueLock {
    param([scriptblock]$Body)
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $hasLock = $false
    try {
        $hasLock = $mutex.WaitOne([TimeSpan]::FromMinutes(10))
        if (-not $hasLock) { throw "Could not acquire queue lock: $mutexName" }
        return & $Body
    }
    finally {
        if ($hasLock) { $mutex.ReleaseMutex() | Out-Null }
        $mutex.Dispose()
    }
}

function Invoke-QueueManager {
    param([Parameter(Mandatory = $true)][ValidateSet('init','status','prepare','finalize','fail')][string]$Mode)
    $python = Resolve-Python
    $runtimeConfig = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($runtimeConfig.zoteroLocalApiBaseUrl) { $env:ZOTERO_LOCAL_BASE_URL = [string]$runtimeConfig.zoteroLocalApiBaseUrl }
    $env:QUEUE_MODE = $Mode
    $env:CONFIG_FILE = $ConfigFile
    $env:QUEUE_FILE = $queueFile
    $env:SELECTION_FILE = $selectionFile
    $env:RESULT_FILE = $resultFile
    $env:WORKER_ID = $WorkerId
    $env:RUN_ID = $runId
    $env:LEASE_HOURS = [string]$leaseHours
    $env:MAX_ATTEMPTS = [string]$maxAttempts
    $env:MAX_RUNNING_PER_COLLECTION = [string]$maxRunningPerCollection
    $env:REBUILD_QUEUE = if ($QueueOnly) { '1' } else { '0' }
    $output = & $python $queueManagerFile 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Queue manager failed in mode ${Mode}: $output" }
    return ($output | Select-Object -Last 1)
}

if ($QueueOnly) {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $selectionFile = Join-Path $logRoot "pool_queue_init_$timestamp.json"
    $resultFile = Join-Path $logRoot "pool_queue_init_result_$timestamp.json"
    Invoke-WithQueueLock { Invoke-QueueManager -Mode 'init' } | Out-Null
    Write-SchedulerLog "queue initialized: $queueFile"
    return
}

if ($QueueStatus) {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $selectionFile = Join-Path $logRoot "pool_queue_status_$timestamp.json"
    $resultFile = Join-Path $logRoot "pool_queue_status_result_$timestamp.json"
    Invoke-WithQueueLock { Invoke-QueueManager -Mode 'status' } | Out-Null
    Get-Content -LiteralPath $selectionFile -Raw -Encoding UTF8
    return
}

$workerScriptPath = $MyInvocation.MyCommand.Path
Invoke-PoolLogCleanup -Config $config -Defaults $defaults -RootPath $root
Invoke-PoolStateMutex -Config $config -Identity $identity -Body {
    $sameWorker = @(Get-PoolActiveWorkerStates -Config $config -Identity $identity | Where-Object { $_.workerId -eq $WorkerId })
    if ($sameWorker.Count -gt 0) { throw "WorkerId '$WorkerId' is already active for project '$($identity.ProjectId)'." }
    New-PoolWorkerState -Config $config -Identity $identity -RunId $runId -WorkerId $WorkerId -ProcessId $PID -WorkerScript $workerScriptPath -ConfigFile $ConfigFile | Out-Null
}
Write-SchedulerLog "worker started runId=$runId pid=$PID project=$($identity.ProjectId)"

function Set-StandaloneRunStatus {
    param([Parameter(Mandatory = $true)][string]$Status)
    if (-not $requestedRunId) { try { Set-PoolRunStatus -Config $config -Identity $identity -RunId $runId -Status $Status } catch {} }
}

while ($true) {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    Update-PoolWorkerState -Config $config -Identity $identity -RunId $runId -WorkerId $WorkerId -Status 'running'
    $workerLogDir = Join-Path $logRoot $WorkerId
    New-Item -ItemType Directory -Force -Path $workerLogDir | Out-Null
    $stdoutLog = Join-Path $workerLogDir "codex_paper_run_$timestamp.log"
    $lastMessage = Join-Path $workerLogDir "codex_paper_last_message_$timestamp.txt"
    $selectionFile = Join-Path $workerLogDir "codex_paper_selection_$timestamp.json"
    $resultFile = Join-Path $workerLogDir "codex_paper_result_$timestamp.json"
    $promptFile = Join-Path $workerLogDir "codex_paper_prompt_$timestamp.txt"
    try {
        Invoke-WithQueueLock { Invoke-QueueManager -Mode 'prepare' } | Out-Null
        $selection = Get-Content -LiteralPath $selectionFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $selection.selected) {
            Write-SchedulerLog "no pending item"
            if ($selection.allCompleted -or $Once) { Update-PoolWorkerState -Config $config -Identity $identity -RunId $runId -WorkerId $WorkerId -Status $(if ($Once) { 'completed' } else { 'idle' }); Set-StandaloneRunStatus -Status 'completed'; return }
            Start-Sleep -Seconds $workerSleepSeconds
            continue
        }
        $target = $selection.selected
        $targetOutputDir = $studyRoot
        foreach ($part in @($target.pathParts)) { $targetOutputDir = Join-Path $targetOutputDir (ConvertTo-SafePathPart ([string]$part)) }
        New-Item -ItemType Directory -Force -Path $targetOutputDir | Out-Null
        Copy-Item (Join-Path $packageDir 'study-paper-template\reading-note-template.md') (Join-Path $targetOutputDir 'reading-note-template.md') -Force
        Copy-Item (Join-Path $packageDir 'study-paper-template\fill-instructions.md') (Join-Path $targetOutputDir 'fill-instructions.md') -Force
        $queueIndex = '{0:D3}' -f [int]$target.collectionIndex
        $creatorText = ($target.creators -join '; ')
        $collectionPath = ($target.pathParts -join ' / ')
        $templateFile = Join-Path $targetOutputDir 'reading-note-template.md'
        $instructionFile = Join-Path $targetOutputDir 'fill-instructions.md'
        $pythonExeForPrompt = Resolve-Python
        $zoteroHelper = Resolve-ZoteroHelper
        $zoteroApiBaseUrl = Get-ZoteroLocalApiBaseUrl
        $zoteroHelperText = if ($zoteroHelper) { $zoteroHelper } else { "not configured; worker uses direct Zotero local API at $zoteroApiBaseUrl" }
        $styleRankSummary = Get-StyleRankSummary $styleCacheFile ([string]$target.publicationTitle)
        $styleCacheInstruction = if ($styleCacheFile) { $styleCacheFile } else { 'not configured; journal quartile lookup is optional and skipped' }
        $generatedAt = Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
        $pdfChunksFile = Join-Path $workerLogDir "codex_paper_pdf_chunks_$timestamp.json"
        $pdfFilePath = Resolve-ZoteroAttachmentFilePath -AttachmentKey ([string]$target.attachmentKey) -PythonExe $pythonExeForPrompt -OptionalHelper $zoteroHelper
        $pdfExtraction = Export-PdfChunks $pythonExeForPrompt $pdfFilePath $pdfChunksFile
        if (-not $pdfExtraction.Ok) { throw "$($pdfExtraction.Code): $($pdfExtraction.Detail)" }
        $pdfDocument = $pdfExtraction.Document
        $pdfTextInstruction = $pdfChunksFile
        $templateTextForPrompt = Get-TextForPrompt $templateFile 20000
        $instructionTextForPrompt = Get-TextForPrompt $instructionFile 30000
        $pdfTextForPrompt = Get-ChunksForPrompt -Document $pdfDocument -MaxChars $pdfMaxPromptChars
        $defaultAuthor = Get-FirstAuthorLastName $target.creators
        $defaultYear = if ($target.year) { [string]$target.year } else { 'unknown-year' }
        $defaultTitleSlug = Get-TitleKeywordSlug ([string]$target.title)
        $defaultNoteFileName = ConvertTo-SafeFileName "$queueIndex`_$defaultAuthor`_$defaultYear`_$defaultTitleSlug`_reading-note.md"
        $prompt = @"
You are an academic paper reading assistant working with Zotero.

Process exactly ONE paper from the fixed global reading queue. Do not choose another paper.

Target paper:
- Zotero item key: $($target.itemKey)
- PDF attachment key: $($target.attachmentKey)
- Queue global index: $($target.globalIndex)
- Collection-local index: $queueIndex
- Title: $($target.title)
- Creators: $creatorText
- Year: $($target.year)
- DOI: $($target.DOI)
- Collection path: $collectionPath
- Collection key: $($target.collectionKey)

Required inputs:
- Template file: $templateFile
- Field instructions: $instructionFile
- Zotero Style journal cache: $styleCacheInstruction
- Windows Python executable: $pythonExeForPrompt
- Zotero helper script: $zoteroHelperText
- Local PDF file: $pdfFilePath
- Pre-extracted PDF chunk JSON file: $pdfTextInstruction
- Precomputed journal quartile summary: $styleRankSummary
- GeneratedAt timestamp for the Basic Information Date row: $generatedAt
- Default output filename if you cannot make a better one: $defaultNoteFileName

Template content:
<<<READING_NOTE_TEMPLATE
$templateTextForPrompt
READING_NOTE_TEMPLATE

Field instructions content:
<<<FILL_INSTRUCTIONS
$instructionTextForPrompt
FILL_INSTRUCTIONS

Page-aware PDF chunks, possibly limited by the worker prompt budget:
<<<PDF_CHUNKS
$pdfTextForPrompt
PDF_CHUNKS

Workflow requirements:
1. Do not run shell commands, Python commands, MCP tools, or Zotero helper commands. The worker has already provided the metadata, template, instructions, journal quartile summary, and page-aware PDF chunks above.
2. Do not try to access Zotero again. Use only the provided target paper metadata and page-aware PDF chunks.
3. Do not print analysis steps such as "I will read more" or "Let me check metadata". Produce the final protocol directly.
4. Use the embedded template and field instructions above.
5. Fill every field in Chinese according to the instructions.
6. For the Basic Information Date row, use exactly this generated timestamp and no other date: $generatedAt
7. For Quartile, use the precomputed journal quartile summary above. If it says not configured or not found, write that the quartile is unavailable; do not invent a value or print the full Zotero Style cache.
8. Use collection-local index $queueIndex as the filename sequence number. Do not compute sequence by scanning existing notes.
9. Do not add colors, HTML, CSS, badges, or decorative Markdown styles.
10. Keep terminal output brief. Do not echo large files such as PDF full text, Zotero Style JSON, or the completed note.
11. Do not write or modify any files. The worker script will write the Markdown note and result JSON after parsing your final response.
12. Every material claim, result, method, or conclusion must be traceable to one or more PDF chunk IDs. Use the chunk pageStart/pageEnd and section values for evidence anchors; never invent page numbers.
13. Return your final answer using exactly the output protocol below. Do not wrap the protocol in a Markdown code fence. The response is invalid unless it contains BEGIN_READING_NOTE_METADATA_JSON, BEGIN_READING_NOTE_STRUCTURED_JSON, and BEGIN_READING_NOTE_MARKDOWN blocks.

Final output protocol:
BEGIN_READING_NOTE_METADATA_JSON
{
  "status": "completed",
  "itemKey": "$($target.itemKey)",
  "attachmentKey": "$($target.attachmentKey)",
  "title": "$($target.title)",
  "fileName": "$defaultNoteFileName",
  "quartileSource": "Zotero Style zoterostyle.json or other source"
}
END_READING_NOTE_METADATA_JSON
BEGIN_READING_NOTE_STRUCTURED_JSON
{
  "schemaVersion": 1,
  "itemKey": "$($target.itemKey)",
  "attachmentKey": "$($target.attachmentKey)",
  "title": "$($target.title)",
  "generatedAt": "$generatedAt",
  "chunks": [{"chunkId": "chunk-0001-p0001-p0004", "pageStart": 1, "pageEnd": 4, "section": "Introduction", "summary": "..."}],
  "evidence": [{"evidenceId": "e1", "claim": "...", "quote": "...", "chunkIds": ["chunk-0001-p0001-p0004"], "pageStart": 1, "pageEnd": 4, "section": "Introduction"}]
}
END_READING_NOTE_STRUCTURED_JSON
BEGIN_READING_NOTE_MARKDOWN
# 完整的中文精读笔记 Markdown
END_READING_NOTE_MARKDOWN

If you cannot complete the note, do not output the markers. Explain the blocker in your final message instead.
"@
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        $codexConfig = Get-CodexRuntimeConfig
        $args = @()
        $cmd = $null
        if ($codexConfig.WireApi -eq 'responses') {
            $cmd = Resolve-Codex
            if ($codexConfig.EnableSearch) { $args += '--search' }
            $args += @('--ask-for-approval', $codexConfig.AskForApproval, 'exec', '--model', $codexConfig.Model, '--config', "model_reasoning_effort=`"$($codexConfig.ReasoningEffort)`"", '--config', "model_providers.custom.wire_api=`"responses`"", '--skip-git-repo-check', '--cd', $root, '--add-dir', $zoteroDataDir, '--sandbox', $codexConfig.Sandbox, '--output-last-message', $lastMessage)
            if ($codexConfig.ExtraArgs.Count -gt 0) { $args += $codexConfig.ExtraArgs }
            $args += '-'
        } else {
            if ($codexConfig.EnableSearch) {
                Write-SchedulerLog "search disabled for item=$($target.itemKey) because wire_api=$($codexConfig.WireApi) uses direct chat completions"
            }
        }
        Write-SchedulerLog "started item=$($target.itemKey) collection=$collectionPath model=$($codexConfig.Model) effort=$($codexConfig.ReasoningEffort) wire_api=$($codexConfig.WireApi)"
        $lastText = ''
        $metadataText = $null
        $structuredText = $null
        $noteMarkdown = $null
        for ($codexAttempt = 1; $codexAttempt -le 2; $codexAttempt++) {
            $attemptPromptFile = if ($codexAttempt -eq 1) { $promptFile } else { Join-Path $workerLogDir "codex_paper_prompt_$($timestamp)_retry$codexAttempt.txt" }
            $attemptStdoutLog = if ($codexAttempt -eq 1) { $stdoutLog } else { Join-Path $workerLogDir "codex_paper_run_$($timestamp)_retry$codexAttempt.log" }
            $attemptLastMessage = if ($codexAttempt -eq 1) { $lastMessage } else { Join-Path $workerLogDir "codex_paper_last_message_$($timestamp)_retry$codexAttempt.txt" }
            $attemptPrompt = $prompt
            if ($codexAttempt -gt 1) {
                $attemptPrompt = @"
$prompt

IMPORTANT RETRY INSTRUCTION:
Your previous response did not contain the required Markdown and structured JSON BEGIN/END protocol markers. Do not run commands. Do not inspect files. Do not explain what you will do. Output the completed note now using exactly the required protocol blocks.
"@
            }
            [System.IO.File]::WriteAllText($attemptPromptFile, $attemptPrompt, $utf8NoBom)
            if ($codexConfig.WireApi -eq 'chat') {
                $codexExitCode = Invoke-ChatCompletionForPrompt -CodexConfig $codexConfig -PromptFile $attemptPromptFile -LastMessageFile $attemptLastMessage -StdoutLogFile $attemptStdoutLog -Utf8NoBom $utf8NoBom
            } else {
                $attemptArgs = @($args)
                $outputIndex = [Array]::IndexOf($attemptArgs, '--output-last-message')
                if ($outputIndex -ge 0 -and ($outputIndex + 1) -lt $attemptArgs.Count) {
                    $attemptArgs[$outputIndex + 1] = $attemptLastMessage
                }
                $oldEap = $ErrorActionPreference
                $ErrorActionPreference = 'Continue'
                try {
                    $codexOutput = Get-Content -Raw -Encoding UTF8 -LiteralPath $attemptPromptFile | & $cmd @attemptArgs *>&1
                    $codexExitCode = $LASTEXITCODE
                    [System.IO.File]::WriteAllText($attemptStdoutLog, (($codexOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine), $utf8NoBom)
                }
                finally { $ErrorActionPreference = $oldEap }
            }
            if ($codexExitCode -ne 0) {
                if ($codexAttempt -ge 2) { throw "$($codexConfig.WireApi) model call failed with exit code $codexExitCode" }
                Write-SchedulerLog "$($codexConfig.WireApi) attempt $codexAttempt failed with exit code $codexExitCode; retrying item=$($target.itemKey)"
                continue
            }
            if (-not (Test-Path -LiteralPath $attemptLastMessage)) { throw "Model last message file missing: $attemptLastMessage" }
            $lastText = Get-Content -LiteralPath $attemptLastMessage -Raw -Encoding UTF8
            $metadataText = Get-DelimitedBlock $lastText 'BEGIN_READING_NOTE_METADATA_JSON' 'END_READING_NOTE_METADATA_JSON'
            $structuredText = Get-DelimitedBlock $lastText 'BEGIN_READING_NOTE_STRUCTURED_JSON' 'END_READING_NOTE_STRUCTURED_JSON'
            $noteMarkdown = Get-DelimitedBlock $lastText 'BEGIN_READING_NOTE_MARKDOWN' 'END_READING_NOTE_MARKDOWN'
            if ($metadataText -and $noteMarkdown -and $structuredText) {
                $lastMessage = $attemptLastMessage
                break
            }
            Write-SchedulerLog "$($codexConfig.WireApi) attempt $codexAttempt missing protocol markers; retrying item=$($target.itemKey)"
        }
        if (-not $metadataText -or -not $noteMarkdown -or -not $structuredText) { throw "Model final response did not contain the required metadata, Markdown, and structured JSON protocol markers after retry. See: $lastMessage" }
        if ($noteMarkdown.Length -lt 1000) { throw "Generated note is too short ($($noteMarkdown.Length) chars). See: $lastMessage" }
        if ($noteMarkdown -match '\{中文标题\}|\{English Title\}|\{作者列表\}|待填写|TODO_PLACEHOLDER') {
            throw "Generated note still appears to contain template placeholders. See: $lastMessage"
        }
        $metadata = $null
        try { $metadata = $metadataText | ConvertFrom-Json } catch { throw "Metadata JSON parse failed: $($_.Exception.Message). See: $lastMessage" }
        if ($metadata -and $metadata.itemKey -and ([string]$metadata.itemKey -ne [string]$target.itemKey)) {
            throw "Metadata itemKey mismatch: $($metadata.itemKey) != $($target.itemKey)"
        }
        $structured = $null
        try { $structured = $structuredText | ConvertFrom-Json } catch { throw "Structured reading note JSON parse failed: $($_.Exception.Message). See: $lastMessage" }
        if ($null -eq $structured -or [int]$structured.schemaVersion -ne 1) { throw "Structured reading note schemaVersion must be 1. See: $lastMessage" }
        if ([string]$structured.itemKey -ne [string]$target.itemKey -or [string]$structured.attachmentKey -ne [string]$target.attachmentKey) { throw "Structured reading note item or attachment key mismatch. See: $lastMessage" }
        $knownChunkIds = @($pdfDocument.chunks | ForEach-Object { [string]$_.chunkId })
        $knownChunkSections = @{}
        foreach ($sourceChunk in @($pdfDocument.chunks)) { $knownChunkSections[[string]$sourceChunk.chunkId] = $sourceChunk.section }
        $structuredChunks = @($structured.chunks)
        if ($structuredChunks.Count -eq 0) { throw "Structured reading note contains no chunk summaries. See: $lastMessage" }
        $structuredEvidence = @($structured.evidence)
        if ($structuredEvidence.Count -eq 0) { throw "Structured reading note contains no evidence anchors. See: $lastMessage" }
        foreach ($chunk in $structuredChunks) {
            if ($knownChunkIds -notcontains [string]$chunk.chunkId) { throw "Structured note references unknown chunk: $($chunk.chunkId)" }
            if (-not ($chunk.PSObject.Properties.Name -contains 'section')) { $chunk | Add-Member -NotePropertyName section -NotePropertyValue $knownChunkSections[[string]$chunk.chunkId] }
            if ([int]$chunk.pageStart -lt 1 -or [int]$chunk.pageEnd -lt [int]$chunk.pageStart) { throw "Invalid structured chunk page range: $($chunk.chunkId)" }
        }
        foreach ($evidence in $structuredEvidence) {
            if (-not $evidence.chunkIds -or @($evidence.chunkIds).Count -eq 0) { throw "Evidence item has no chunkIds." }
            foreach ($chunkId in @($evidence.chunkIds)) { if ($knownChunkIds -notcontains [string]$chunkId) { throw "Evidence references unknown chunk: $chunkId" } }
            if (-not ($evidence.PSObject.Properties.Name -contains 'section')) { $evidence | Add-Member -NotePropertyName section -NotePropertyValue $knownChunkSections[[string]@($evidence.chunkIds)[0]] }
            if ([int]$evidence.pageStart -lt 1 -or [int]$evidence.pageEnd -lt [int]$evidence.pageStart) { throw "Invalid evidence page range: $($evidence.evidenceId)" }
        }
        foreach ($propertyName in @('noteFile', 'collectionKey', 'collectionPath', 'title', 'generatedAt')) {
            if (-not ($structured.PSObject.Properties.Name -contains $propertyName)) {
                $structured | Add-Member -NotePropertyName $propertyName -NotePropertyValue $null
            }
        }
        $structured.schemaVersion = 1
        $structured.generatedAt = $generatedAt

        $rawFileName = if ($metadata -and $metadata.fileName) { [string]$metadata.fileName } else { $defaultNoteFileName }
        $noteFileName = ConvertTo-SafeFileName $rawFileName
        if (-not $noteFileName.EndsWith('.md', [StringComparison]::OrdinalIgnoreCase)) { $noteFileName += '.md' }
        $desiredPrefix = "$queueIndex`_"
        if (-not $noteFileName.StartsWith($desiredPrefix)) {
            if ($noteFileName -match '^\d+_(.+)$') { $noteFileName = $desiredPrefix + $matches[1] } else { $noteFileName = $desiredPrefix + $noteFileName }
        }
        $noteMarkdown = Repair-ReadingNoteDate -Markdown $noteMarkdown -GeneratedAt $generatedAt
        $outputFile = Join-Path $targetOutputDir $noteFileName
        [System.IO.File]::WriteAllText($outputFile, $noteMarkdown.Trim() + [Environment]::NewLine, $utf8NoBom)
        $noteFileRelative = $outputFile
        if ($outputFile.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $noteFileRelative = $outputFile.Substring($root.Length).TrimStart('\', '/') }
        $structured.noteFile = $noteFileRelative
        $structured.collectionKey = [string]$target.collectionKey
        $structured.collectionPath = $collectionPath
        $structured.title = [string]$target.title
        $structured.generatedAt = $generatedAt
        $structuredFile = [System.IO.Path]::ChangeExtension($outputFile, '.json')
        [System.IO.File]::WriteAllText($structuredFile, ($structured | ConvertTo-Json -Depth 40) + [Environment]::NewLine, $utf8NoBom)
        $validator = Join-Path $scriptDir 'validate-reading-note.py'
        $validationOutput = & $pythonExeForPrompt $validator $structuredFile 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Reading note schema validation failed: $validationOutput" }
        $renderer = Join-Path $scriptDir 'render-reading-note.py'
        $renderOutput = & $pythonExeForPrompt $renderer '--markdown' $outputFile '--record' $structuredFile '--output' $outputFile 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Reading note evidence rendering failed: $renderOutput" }
        $result = [pscustomobject]@{

            status = 'completed'
            itemKey = [string]$target.itemKey
            attachmentKey = [string]$target.attachmentKey
            title = [string]$target.title
            runId = [string]$runId
            workerId = [string]$WorkerId
            outputFile = $outputFile
            structuredFile = $structuredFile
            quartileSource = if ($metadata -and $metadata.quartileSource) { [string]$metadata.quartileSource } else { "Zotero Style cache; $styleRankSummary" }
            generatedBy = 'worker parsed Codex final response'
        }
        $resultJson = $result | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($resultFile, $resultJson, $utf8NoBom)
        Invoke-WithQueueLock { Invoke-StudyDataWriter -PythonExe $pythonExeForPrompt -RecordFile $structuredFile; Invoke-QueueManager -Mode 'finalize' } | Out-Null
        Write-SchedulerLog "completed item=$($target.itemKey) result=$resultFile"
    }
    catch {
        $failureMessage = $_.Exception.Message
        $safeFailureMessage = if (Get-PoolConfigBool -Config $config -Defaults $defaults -Name 'redactSensitivePaths' -Fallback $true) { ConvertTo-PoolPrivacySafeText -Text $failureMessage -RootPath $root -AdditionalPaths @($zoteroDataDir) } else { $failureMessage }
        $env:QUEUE_ERROR = $safeFailureMessage
        $env:QUEUE_ERROR_CODE = if ($failureMessage -match '(?i)pdf_extract_failed') { 'pdf_extract_failed' } elseif ($failureMessage -match '(?i)file does not exist|local PDF') { 'file_missing' } elseif ($failureMessage -match '(?i)protocol markers|structured') { 'model_protocol_invalid' } else { 'worker_failed' }
        try { Invoke-WithQueueLock { Invoke-QueueManager -Mode 'fail' } | Out-Null } catch {}
        Write-SchedulerLog "failed: $failureMessage"
        Invoke-PoolArtifactCleanup -Config $config -Defaults $defaults -WorkerLogDir $workerLogDir -Succeeded $false -RootPath $root
        Update-PoolWorkerState -Config $config -Identity $identity -RunId $runId -WorkerId $WorkerId -Status $(if ($Once) { 'failed' } else { 'idle' }) -ExitCode $(if ($Once) { 1 } else { $null })
        if ($Once) { Set-StandaloneRunStatus -Status 'failed' }
        if ($Once) { throw $failureMessage }
    }
    Invoke-PoolArtifactCleanup -Config $config -Defaults $defaults -WorkerLogDir $workerLogDir -Succeeded $true -RootPath $root
    if ($Once) { Update-PoolWorkerState -Config $config -Identity $identity -RunId $runId -WorkerId $WorkerId -Status 'completed' -ExitCode 0; Set-StandaloneRunStatus -Status 'completed'; return }
    Update-PoolWorkerState -Config $config -Identity $identity -RunId $runId -WorkerId $WorkerId -Status 'idle'
}
