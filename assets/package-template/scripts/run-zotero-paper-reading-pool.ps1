param(
    [string]$ConfigFile,
    [string]$WorkerId = "worker-01",
    [switch]$QueueOnly,
    [switch]$QueueStatus,
    [switch]$Once
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$packageDir = Split-Path -Parent $scriptDir
if (-not $ConfigFile) { $ConfigFile = Join-Path $packageDir 'configs\paper-reading-pool-config.json' }
if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "Config file not found: $ConfigFile" }
$config = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json

function Resolve-ConfiguredPath {
    param([Parameter(Mandatory = $true)][string]$PathValue, [string]$BasePath = $packageDir)
    $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
    if ([System.IO.Path]::IsPathRooted($expanded)) { return $expanded }
    return (Join-Path $BasePath $expanded)
}

function Resolve-Python {
    $bundledPython = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    if (Test-Path $bundledPython) { return $bundledPython }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'python.exe not found.'
}

function Resolve-Node {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $codexBin = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $codexBin) {
        $node = Get-ChildItem -LiteralPath $codexBin -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'node.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if ($node) { return $node }
    }

    throw 'node.exe not found.'
}

$root = Resolve-ConfiguredPath ([string]$config.root)
$studyRoot = Resolve-ConfiguredPath ([string]$config.studyRoot) $root
$logRoot = Resolve-ConfiguredPath ([string]$config.logRoot) $root
$queueFile = Resolve-ConfiguredPath ([string]$config.queueFile) $root
$mutexName = if ($config.mutexName) { [string]$config.mutexName } else { 'Global\ZoteroPaperReadingPoolQueue' }
$maxAttempts = if ($config.maxAttempts) { [int]$config.maxAttempts } else { 3 }
$leaseHours = if ($config.leaseHours) { [int]$config.leaseHours } else { 8 }
$workerSleepSeconds = if ($config.workerSleepSeconds) { [int]$config.workerSleepSeconds } else { 30 }
$maxRunningPerCollection = if ($config.maxRunningPerCollection) { [int]$config.maxRunningPerCollection } else { 1 }

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
  await writeLog(`ERROR: chat completion helper crashed model=${model}\n${error?.stack || error?.message || String(error)}\n`);
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

function Resolve-ZoteroStyleCache {
    $candidates = @()
    if ($config.zoteroStyleCandidates) {
        foreach ($candidate in @($config.zoteroStyleCandidates)) {
            if ($candidate) { $candidates += Resolve-ConfiguredPath ([string]$candidate) $root }
        }
    }
    $candidates += @("$env:USERPROFILE\Zotero\zoterostyle.json")
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate) { return $candidate } }
    throw "No Zotero style cache found. Checked: $($candidates -join '; ')"
}

function Resolve-ZoteroHelper {
    $candidateRoot = Join-Path $env:USERPROFILE '.codex\plugins\cache\openai-curated\zotero'
    if (-not (Test-Path -LiteralPath $candidateRoot)) { return $null }
    $helper = Get-ChildItem -LiteralPath $candidateRoot -Recurse -Filter 'zotero.py' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -like '*\skills\zotero\scripts\zotero.py' } |
        Select-Object -First 1
    if ($helper) { return $helper.FullName }
    return $null
}

function Get-StyleRankSummary {
    param([string]$StyleCachePath, [string]$PublicationTitle)
    if (-not $PublicationTitle -or -not (Test-Path -LiteralPath $StyleCachePath)) { return 'not found' }
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
    try { return ([System.Uri]::new($FileUrl.Trim())).LocalPath } catch { return $null }
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
    $first = [string]$first
    if ($first.Contains(',')) {
        $name = $first.Split(',')[0].Trim()
    } else {
        $parts = $first -split '\s+'
        $name = $parts[$parts.Count - 1]
    }
    $name = $name -replace '[^A-Za-z0-9_-]', ''
    if ($name) { return $name }
    return 'Unknown'
}

function Get-TitleKeywordSlug {
    param([string]$Title)
    if (-not $Title) { return 'Untitled' }
    $stopWords = @(
        'the','and','for','with','from','into','onto','that','this','these','those','using','based',
        'study','effect','effects','method','methods','prepared','preparation','properties'
    )
    $words = [regex]::Matches($Title, '[A-Za-z0-9]+') |
        ForEach-Object { $_.Value } |
        Where-Object { $_.Length -gt 2 -and ($stopWords -notcontains $_.ToLowerInvariant()) } |
        Select-Object -First 6
    if (-not $words -or @($words).Count -eq 0) {
        $words = [regex]::Matches($Title, '[A-Za-z0-9]+') | ForEach-Object { $_.Value } | Select-Object -First 6
    }
    $slug = (@($words) -join '-')
    if ($slug) { return $slug }
    return 'Untitled'
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

function Export-PdfText {
    param([string]$PythonExe, [string]$PdfPath, [string]$OutputPath)
    if (-not $PdfPath -or -not (Test-Path -LiteralPath $PdfPath)) { return $false }
    $extractScript = [System.IO.Path]::ChangeExtension($OutputPath, '.extract.py')
    $extractCode = @'
import sys
pdf_path, out_path = sys.argv[1], sys.argv[2]
text = ""
try:
    from pdfminer.high_level import extract_text
    text = extract_text(pdf_path) or ""
except Exception:
    try:
        from PyPDF2 import PdfReader
        reader = PdfReader(pdf_path)
        text = "\n".join((page.extract_text() or "") for page in reader.pages)
    except Exception as exc:
        raise SystemExit(str(exc))
with open(out_path, "w", encoding="utf-8") as f:
    f.write(text)
print(len(text))
'@
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($extractScript, $extractCode, $utf8NoBom)
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $PythonExe $extractScript $PdfPath $OutputPath 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldEap
    }
    return ($exitCode -eq 0 -and (Test-Path -LiteralPath $OutputPath) -and ((Get-Item -LiteralPath $OutputPath).Length -gt 0))
}

$styleCacheFile = Resolve-ZoteroStyleCache
$zoteroDataDir = Split-Path -Parent $styleCacheFile
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
    $line = "$(Get-Date -Format s) [$WorkerId] $Message$([Environment]::NewLine)"
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
    $env:QUEUE_MODE = $Mode
    $env:CONFIG_FILE = $ConfigFile
    $env:QUEUE_FILE = $queueFile
    $env:SELECTION_FILE = $selectionFile
    $env:RESULT_FILE = $resultFile
    $env:WORKER_ID = $WorkerId
    $env:RUN_ID = $timestamp
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

while ($true) {
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
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
            if ($selection.allCompleted -or $Once) { return }
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
        $zoteroHelperText = if ($zoteroHelper) { $zoteroHelper } else { 'not found; use direct HTTP API at http://127.0.0.1:23119/api/users/0' }
        $styleRankSummary = Get-StyleRankSummary $styleCacheFile ([string]$target.publicationTitle)
        $generatedAt = Get-Date -Format 'yyyy/MM/dd HH:mm:ss'
        $pdfFilePath = $null
        $pdfTextFile = Join-Path $workerLogDir "codex_paper_fulltext_$timestamp.txt"
        if ($zoteroHelper) {
            $pdfUrlOutput = & $pythonExeForPrompt $zoteroHelper file-url $target.attachmentKey 2>&1
            if ($LASTEXITCODE -eq 0) { $pdfFilePath = Convert-FileUrlToPath (($pdfUrlOutput | Select-Object -First 1) -as [string]) }
        }
        $pdfTextReady = Export-PdfText $pythonExeForPrompt $pdfFilePath $pdfTextFile
        $pdfTextInstruction = if ($pdfTextReady) { $pdfTextFile } else { 'not pre-extracted; use the local PDF path or Zotero helper fallback' }
        $templateTextForPrompt = Get-TextForPrompt $templateFile 20000
        $instructionTextForPrompt = Get-TextForPrompt $instructionFile 30000
        $pdfTextForPrompt = if ($pdfTextReady) { Get-TextForPrompt $pdfTextFile 70000 } else { '' }
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
- Zotero Style journal cache: $styleCacheFile
- Windows Python executable: $pythonExeForPrompt
- Zotero helper script: $zoteroHelperText
- Local PDF file: $pdfFilePath
- Pre-extracted PDF text file: $pdfTextInstruction
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

Pre-extracted PDF text, possibly truncated by the worker:
<<<PDF_TEXT
$pdfTextForPrompt
PDF_TEXT

Workflow requirements:
1. Do not run shell commands, Python commands, MCP tools, or Zotero helper commands. The worker has already provided the metadata, template, instructions, journal quartile summary, and PDF text above.
2. Do not try to access Zotero again. Use only the provided target paper metadata and PDF text.
3. Do not print analysis steps such as "I will read more" or "Let me check metadata". Produce the final protocol directly.
4. Use the embedded template and field instructions above.
5. Fill every field in Chinese according to the instructions.
6. For the Basic Information Date row, use exactly this generated timestamp and no other date: $generatedAt
7. For Quartile, use the precomputed journal quartile summary above. Only read $styleCacheFile if the summary says lookup failed or not found. Never print the full Zotero Style cache to the console.
8. Use collection-local index $queueIndex as the filename sequence number. Do not compute sequence by scanning existing notes.
9. Do not add colors, HTML, CSS, badges, or decorative Markdown styles.
10. Keep terminal output brief. Do not echo large files such as PDF full text, Zotero Style JSON, or the completed note.
11. Do not write or modify any files. The worker script will write the Markdown note and result JSON after parsing your final response.
12. Return your final answer using exactly the output protocol below. Do not wrap the protocol in a Markdown code fence. The response is invalid unless it contains both BEGIN_READING_NOTE_METADATA_JSON and BEGIN_READING_NOTE_MARKDOWN blocks.

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
            $cmd = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin\codex.exe'
            if (-not (Test-Path $cmd)) { throw "codex.exe not found at $cmd" }
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
Your previous response did not contain the required BEGIN/END protocol markers. Do not run commands. Do not inspect files. Do not explain what you will do. Output the completed note now using exactly the required protocol blocks.
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
            $noteMarkdown = Get-DelimitedBlock $lastText 'BEGIN_READING_NOTE_MARKDOWN' 'END_READING_NOTE_MARKDOWN'
            if ($noteMarkdown) {
                $lastMessage = $attemptLastMessage
                break
            }
            Write-SchedulerLog "$($codexConfig.WireApi) attempt $codexAttempt missing protocol markers; retrying item=$($target.itemKey)"
        }
        if (-not $noteMarkdown) { throw "Model final response did not contain BEGIN/END_READING_NOTE_MARKDOWN markers after retry. See: $lastMessage" }
        if ($noteMarkdown.Length -lt 1000) { throw "Generated note is too short ($($noteMarkdown.Length) chars). See: $lastMessage" }
        if ($noteMarkdown -match '\{中文标题\}|\{English Title\}|\{作者列表\}|待填写|TODO_PLACEHOLDER') {
            throw "Generated note still appears to contain template placeholders. See: $lastMessage"
        }
        $metadata = $null
        if ($metadataText) {
            try { $metadata = $metadataText | ConvertFrom-Json } catch { throw "Metadata JSON parse failed: $($_.Exception.Message). See: $lastMessage" }
        }
        if ($metadata -and $metadata.itemKey -and ([string]$metadata.itemKey -ne [string]$target.itemKey)) {
            throw "Metadata itemKey mismatch: $($metadata.itemKey) != $($target.itemKey)"
        }
        $rawFileName = if ($metadata -and $metadata.fileName) { [string]$metadata.fileName } else { $defaultNoteFileName }
        $noteFileName = ConvertTo-SafeFileName $rawFileName
        if (-not $noteFileName.EndsWith('.md', [StringComparison]::OrdinalIgnoreCase)) { $noteFileName += '.md' }
        $desiredPrefix = "$queueIndex`_"
        if (-not $noteFileName.StartsWith($desiredPrefix)) {
            if ($noteFileName -match '^\d+_(.+)$') { $noteFileName = $desiredPrefix + $matches[1] } else { $noteFileName = $desiredPrefix + $noteFileName }
        }
        $outputFile = Join-Path $targetOutputDir $noteFileName
        [System.IO.File]::WriteAllText($outputFile, $noteMarkdown.Trim() + [Environment]::NewLine, $utf8NoBom)
        $result = [pscustomobject]@{
            status = 'completed'
            itemKey = [string]$target.itemKey
            attachmentKey = [string]$target.attachmentKey
            title = [string]$target.title
            outputFile = $outputFile
            quartileSource = if ($metadata -and $metadata.quartileSource) { [string]$metadata.quartileSource } else { "Zotero Style zoterostyle.json; $styleRankSummary" }
            generatedBy = 'worker parsed Codex final response'
        }
        $resultJson = $result | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($resultFile, $resultJson, $utf8NoBom)
        Invoke-WithQueueLock { Invoke-QueueManager -Mode 'finalize' } | Out-Null
        Write-SchedulerLog "completed item=$($target.itemKey) result=$resultFile"
    }
    catch {
        $env:QUEUE_ERROR = $_.Exception.Message
        try { Invoke-WithQueueLock { Invoke-QueueManager -Mode 'fail' } | Out-Null } catch {}
        Write-SchedulerLog "failed: $($_.Exception.Message)"
    }
    if ($Once) { return }
}
