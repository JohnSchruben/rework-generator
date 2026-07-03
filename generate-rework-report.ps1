[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [string]$CurrentRef = "HEAD",
    [string]$BaselineBranch = "Development",
    [string]$BaselineRef = "",
    [int]$Weeks = 14,
    [int]$Top = 25,
    [string]$OutputPath = ".rework-report\index.html",
    [int]$MinAdded = 15,
    [int]$MinDeleted = 15,
    [int]$ContextLines = 0,
    [int]$ProgressInterval = 25
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$startedAt = Get-Date
$script:LocationPushed = $false

trap {
    if ($script:LocationPushed) {
        Pop-Location
        $script:LocationPushed = $false
    }

    throw
}

function Write-Step {
    param([string]$Message)

    $elapsed = (Get-Date) - $script:StartedAt
    Write-Host ("[{0:hh\:mm\:ss}] {1}" -f $elapsed, $Message)
}

function Invoke-Git {
    param(
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $ErrorActionPreference = "Continue"
    if ($AllowFailure) {
        $output = & git @Arguments 2>$null
    }
    else {
        $output = & git @Arguments 2>&1
    }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git $($Arguments -join ' ') failed with exit code $exitCode`n$($output -join "`n")"
    }

    return @($output)
}

function Resolve-Commit {
    param([string]$Ref)

    $resolved = @(Invoke-Git -Arguments @("rev-parse", "--verify", "$Ref^{commit}") -AllowFailure)
    if ($LASTEXITCODE -ne 0 -or $resolved.Count -eq 0) {
        return $null
    }

    return [string]$resolved[0]
}

function Get-ComparableFiles {
    param([string]$Commit)

    $files = @(Invoke-Git -Arguments @("ls-tree", "-r", "--name-only", $Commit))
    return @($files | Where-Object {
        ($_ -match "\.(cs|xaml)$") -and ($_ -notmatch "(?i)test")
    })
}

function Get-ProjectFiles {
    param([string]$Commit)

    return @(Invoke-Git -Arguments @("ls-tree", "-r", "--name-only", $Commit) | Where-Object {
        ($_ -match "\.csproj$") -and ($_ -notmatch "(?i)test")
    })
}

function Get-FileName {
    param([string]$Path)

    $parts = $Path -split "[/\\]"
    return [string]$parts[-1]
}

function Get-ProjectName {
    param(
        [string]$Path,
        [string[]]$ProjectFiles
    )

    $bestProject = $null
    $bestLength = -1
    foreach ($projectFile in $ProjectFiles) {
        $projectDirectory = ""
        $lastSlash = $projectFile.LastIndexOf("/")
        if ($lastSlash -ge 0) {
            $projectDirectory = $projectFile.Substring(0, $lastSlash + 1)
        }

        if ($Path.StartsWith($projectDirectory) -and $projectDirectory.Length -gt $bestLength) {
            $bestProject = $projectFile
            $bestLength = $projectDirectory.Length
        }
    }

    if ($null -eq $bestProject) {
        return "(No project)"
    }

    return [System.IO.Path]::GetFileNameWithoutExtension((Get-FileName -Path $bestProject))
}

function Count-LinesAtCommit {
    param(
        [string]$Commit,
        [string]$Path
    )

    $content = @(Invoke-Git -Arguments @("show", "$Commit`:$Path"))
    return @($content).Count
}

function HtmlEncode {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ""
    }

    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Format-Number {
    param([double]$Value)

    return $Value.ToString("N1", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-RawNumber {
    param([double]$Value)

    return $Value.ToString("0.############", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-WholeNumber {
    param([long]$Value)

    return $Value.ToString("N0", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Convert-Numstat {
    param([string[]]$Lines)

    if ($Lines.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$Lines[0])) {
        return [pscustomobject]@{
            Added = 0
            Deleted = 0
            IsBinary = $false
            HasChanges = $false
        }
    }

    $parts = ([string]$Lines[0]) -split "`t"
    if ($parts.Count -lt 3 -or $parts[0] -eq "-" -or $parts[1] -eq "-") {
        return [pscustomobject]@{
            Added = 0
            Deleted = 0
            IsBinary = $true
            HasChanges = $true
        }
    }

    return [pscustomobject]@{
        Added = [int]$parts[0]
        Deleted = [int]$parts[1]
        IsBinary = $false
        HasChanges = $true
    }
}

function Format-DiffHtml {
    param([string[]]$Lines)

    $htmlLines = New-Object System.Collections.Generic.List[string]
    $oldLine = $null
    $newLine = $null

    foreach ($line in $Lines) {
        $class = "meta"
        $oldNumber = ""
        $newNumber = ""

        if ($line -match "^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@") {
            $class = "hunk"
            $oldLine = [int]$Matches[1]
            $newLine = [int]$Matches[2]
            continue
        }
        elseif ($line -match "^\+\+\+") {
            continue
        }
        elseif ($line -match "^---") {
            continue
        }
        elseif ($line -match "^\+") {
            $class = "add"
            if ($null -ne $newLine) {
                $newNumber = [string]$newLine
                $newLine += 1
            }
        }
        elseif ($line -match "^-") {
            $class = "del"
            if ($null -ne $oldLine) {
                $oldNumber = [string]$oldLine
                $oldLine += 1
            }
        }
        elseif ($line -match "^ ") {
            $class = "context"
            if ($null -ne $oldLine) {
                $oldNumber = [string]$oldLine
                $oldLine += 1
            }
            if ($null -ne $newLine) {
                $newNumber = [string]$newLine
                $newLine += 1
            }
        }

        elseif ($line -match "^(diff --git|index )") {
            continue
        }

        $htmlLines.Add("<div class=""diff-line $class""><span class=""ln old"">$oldNumber</span><span class=""ln new"">$newNumber</span><code>$(HtmlEncode $line)</code></div>")
    }

    return ($htmlLines -join "")
}

function Resolve-BaselineSource {
    $warnings = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($BaselineRef)) {
        $commit = Resolve-Commit -Ref $BaselineRef
        if ($null -eq $commit) {
            throw "Could not resolve baseline ref '$BaselineRef'."
        }

        return @{
            Ref = $BaselineRef
            Commit = $commit
            Warnings = $warnings
            UsesExplicitRef = $true
        }
    }

    $candidateRefs = @($BaselineBranch, "origin/$BaselineBranch")
    foreach ($candidate in $candidateRefs) {
        $commit = Resolve-Commit -Ref $candidate
        if ($null -ne $commit) {
            return @{
                Ref = $candidate
                Commit = $commit
                Warnings = $warnings
                UsesExplicitRef = $false
            }
        }
    }

    $fallback = $CurrentRef
    $fallbackCommit = Resolve-Commit -Ref $fallback
    if ($null -eq $fallbackCommit) {
        throw "Could not resolve current ref '$CurrentRef'."
    }

    $warnings.Add("Could not find '$BaselineBranch' or 'origin/$BaselineBranch'; using '$fallback' as the baseline branch source.")
    return @{
        Ref = $fallback
        Commit = $fallbackCommit
        Warnings = $warnings
        UsesExplicitRef = $false
    }
}

$script:StartedAt = $startedAt
Write-Step "Starting rework report generation."

$script:GitRepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
Push-Location -LiteralPath $script:GitRepoRoot
$script:LocationPushed = $true
Write-Step "Resolving repository root from $($script:GitRepoRoot)."
$repoTop = @(Invoke-Git -Arguments @("rev-parse", "--show-toplevel"))
$script:GitRepoRoot = [System.IO.Path]::GetFullPath([string]$repoTop[0])
Set-Location -LiteralPath $script:GitRepoRoot
Write-Step "Using repository root $($script:GitRepoRoot)."

$warnings = New-Object System.Collections.Generic.List[string]
Write-Step "Resolving current ref '$CurrentRef'."
$currentCommit = Resolve-Commit -Ref $CurrentRef
if ($null -eq $currentCommit) {
    throw "Could not resolve current ref '$CurrentRef'."
}
Write-Step "Current commit is $($currentCommit.Substring(0, 12))."

Write-Step "Resolving baseline source."
$baselineSource = Resolve-BaselineSource
foreach ($warning in $baselineSource.Warnings) {
    $warnings.Add($warning)
    Write-Step "Note: $warning"
}

$cutoff = (Get-Date).AddDays(-7 * $Weeks)
if ($baselineSource.UsesExplicitRef) {
    $baselineCommit = $baselineSource.Commit
    Write-Step "Using explicit baseline ref '$BaselineRef'."
}
else {
    Write-Step "Looking for '$($baselineSource.Ref)' as of $($cutoff.ToString("MMMM d, yyyy", [System.Globalization.CultureInfo]::InvariantCulture))."
    $cutoffIso = $cutoff.ToString("yyyy-MM-ddTHH:mm:ssK", [System.Globalization.CultureInfo]::InvariantCulture)
    $baselineAtDate = @(Invoke-Git -Arguments @("rev-list", "-n", "1", "--before=$cutoffIso", [string]$baselineSource.Ref) -AllowFailure)
    if ($baselineAtDate.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$baselineAtDate[0])) {
        $baselineCommit = [string]$baselineAtDate[0]
    }
    else {
        $oldest = @(Invoke-Git -Arguments @("rev-list", "--max-parents=0", [string]$baselineSource.Ref))
        if ($oldest.Count -eq 0) {
            throw "Could not find a historical commit for '$($baselineSource.Ref)'."
        }

        $baselineCommit = [string]$oldest[-1]
        $warnings.Add("No commit existed on '$($baselineSource.Ref)' at or before $($cutoff.ToString("yyyy-MM-dd")); using the oldest available commit $($baselineCommit.Substring(0, 8)).")
        Write-Step "Note: $($warnings[$warnings.Count - 1])"
    }
}
Write-Step "Baseline commit is $($baselineCommit.Substring(0, 12))."

$dateFormat = "--date=format:%B %d, %Y"
$baselineDate = (@(Invoke-Git -Arguments @("show", "-s", $dateFormat, "--format=%cd", $baselineCommit)))[0]
$currentDate = (@(Invoke-Git -Arguments @("show", "-s", $dateFormat, "--format=%cd", $currentCommit)))[0]

Write-Step "Finding comparable .cs and .xaml files."
$baselineFiles = Get-ComparableFiles -Commit $baselineCommit
$currentFiles = Get-ComparableFiles -Commit $currentCommit
$currentProjectFiles = Get-ProjectFiles -Commit $currentCommit
Write-Step "Found $($baselineFiles.Count) baseline production files, $($currentFiles.Count) current production files, and $($currentProjectFiles.Count) current production projects."

$currentFileSet = @{}
foreach ($path in $currentFiles) {
    $currentFileSet[$path] = $true
}

$commonFiles = @($baselineFiles | Where-Object { $currentFileSet.ContainsKey($_) } | Sort-Object)
Write-Step "Scanning $($commonFiles.Count) files that exist in both revisions."
$allCurrentLines = 0
$qualified = New-Object System.Collections.Generic.List[object]

$scanned = 0
foreach ($path in $commonFiles) {
    $scanned += 1
    if ($scanned -eq 1 -or ($ProgressInterval -gt 0 -and $scanned % $ProgressInterval -eq 0) -or $scanned -eq $commonFiles.Count) {
        Write-Step "Scanning file $scanned of $($commonFiles.Count): $path"
    }

    $currentLineCount = Count-LinesAtCommit -Commit $currentCommit -Path $path
    $allCurrentLines += $currentLineCount

    $numstat = Convert-Numstat -Lines @(Invoke-Git -Arguments @("diff", "--numstat", $baselineCommit, $currentCommit, "--", $path))
    if (-not $numstat.HasChanges) {
        continue
    }

    if ($numstat.IsBinary) {
        continue
    }

    $added = $numstat.Added
    $deleted = $numstat.Deleted
    if ($added -lt $MinAdded -or $deleted -lt $MinDeleted) {
        continue
    }

    Write-Step "Hotspot found: $path (+$added -$deleted)."

    $whitespaceNumstat = Convert-Numstat -Lines @(Invoke-Git -Arguments @("diff", "--numstat", "-w", $baselineCommit, $currentCommit, "--", $path))
    $whitespaceAdded = $whitespaceNumstat.Added
    $whitespaceDeleted = $whitespaceNumstat.Deleted
    $whitespaceReworkLines = [Math]::Min($whitespaceAdded, $whitespaceDeleted)
    $whitespaceChurnLines = $whitespaceAdded + $whitespaceDeleted

    $diff = @(Invoke-Git -Arguments @("diff", "--no-ext-diff", "--unified=$ContextLines", "--src-prefix=baseline/", "--dst-prefix=current/", $baselineCommit, $currentCommit, "--", $path))
    $reworkLines = [Math]::Min($added, $deleted)
    $churnLines = $added + $deleted
    $denominator = [Math]::Max($currentLineCount, 1)

    $qualified.Add([pscustomobject]@{
        Path = $path
        FileName = (Get-FileName -Path $path)
        Project = (Get-ProjectName -Path $path -ProjectFiles $currentProjectFiles)
        Added = $added
        Deleted = $deleted
        ChurnLines = $churnLines
        ReworkLines = $reworkLines
        WhitespaceIgnoredAdded = $whitespaceAdded
        WhitespaceIgnoredDeleted = $whitespaceDeleted
        WhitespaceIgnoredChurnLines = $whitespaceChurnLines
        WhitespaceIgnoredReworkLines = $whitespaceReworkLines
        CurrentLines = $currentLineCount
        ReworkPercent = (100.0 * $reworkLines / $denominator)
        ChurnPercent = (100.0 * $churnLines / $denominator)
        WhitespaceIgnoredReworkPercent = (100.0 * $whitespaceReworkLines / $denominator)
        DiffHtml = (Format-DiffHtml -Lines $diff)
    })
}
Write-Step "Finished scanning. $($qualified.Count) files met the hotspot rule."

$hotspots = @($qualified | Sort-Object -Property @{ Expression = "ChurnLines"; Descending = $true }, @{ Expression = "ReworkLines"; Descending = $true }, Path)
Write-Step "Calculating summary metrics."
$totalAdded = [long]0
$totalDeleted = [long]0
$totalChurn = [long]0
$totalRework = [long]0
$totalWhitespaceIgnoredChurn = [long]0
$totalWhitespaceIgnoredRework = [long]0
foreach ($file in $hotspots) {
    $totalAdded += $file.Added
    $totalDeleted += $file.Deleted
    $totalChurn += $file.ChurnLines
    $totalRework += $file.ReworkLines
    $totalWhitespaceIgnoredChurn += $file.WhitespaceIgnoredChurnLines
    $totalWhitespaceIgnoredRework += $file.WhitespaceIgnoredReworkLines
}

$repoReworkPercent = 0.0
if ($allCurrentLines -gt 0) {
    $repoReworkPercent = 100.0 * $totalRework / $allCurrentLines
}

$repoChurnPercent = 0.0
if ($allCurrentLines -gt 0) {
    $repoChurnPercent = 100.0 * $totalChurn / $allCurrentLines
}

$whitespaceIgnoredReworkPercent = 0.0
if ($allCurrentLines -gt 0) {
    $whitespaceIgnoredReworkPercent = 100.0 * $totalWhitespaceIgnoredRework / $allCurrentLines
}

$reworkShareOfChurn = 0.0
if ($totalChurn -gt 0) {
    $reworkShareOfChurn = 100.0 * $totalRework / $totalChurn
}

if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    $fullOutputPath = $OutputPath
}
else {
    $fullOutputPath = Join-Path $script:GitRepoRoot $OutputPath
}

$outputDirectory = Split-Path -Parent $fullOutputPath
if (-not (Test-Path $outputDirectory)) {
    Write-Step "Creating output directory $outputDirectory."
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

$generatedAt = (Get-Date).ToString("MMMM d, yyyy", [System.Globalization.CultureInfo]::InvariantCulture)
$branchLabel = HtmlEncode $CurrentRef
$baselineLabel = HtmlEncode $baselineSource.Ref
$baselineSha = $baselineCommit.Substring(0, 12)
$currentSha = $currentCommit.Substring(0, 12)
$barWidth = [Math]::Min([Math]::Max($repoReworkPercent, 0), 100).ToString("0.###", [System.Globalization.CultureInfo]::InvariantCulture)
$defaultTop = [Math]::Max(1, $Top)
$warningHtml = ""
if ($warnings.Count -gt 0) {
    $warningItems = @($warnings | ForEach-Object { "<li>$(HtmlEncode $_)</li>" })
    $warningHtml = "<section class=""notice""><h2>Notes</h2><ul>$($warningItems -join '')</ul></section>"
}

$rows = New-Object System.Collections.Generic.List[string]
$panels = New-Object System.Collections.Generic.List[string]
$projectOptions = New-Object System.Collections.Generic.List[string]
$projectOptions.Add('<option value="all">All projects</option>')
foreach ($project in @($hotspots | Select-Object -ExpandProperty Project -Unique | Sort-Object)) {
    $projectHtml = HtmlEncode $project
    $projectOptions.Add("<option value=""$projectHtml"">$projectHtml</option>")
}

$rank = 0
foreach ($file in $hotspots) {
    $rank += 1
    $pathHtml = HtmlEncode $file.Path
    $fileNameHtml = HtmlEncode $file.FileName
    $projectHtml = HtmlEncode $file.Project
    $searchTextHtml = HtmlEncode "$($file.FileName) $($file.Project) $($file.Path)"
    $reworkPercentSort = Format-RawNumber $file.ReworkPercent
    $churnPercentSort = Format-RawNumber $file.ChurnPercent
    $rows.Add(@"
<tr data-rank="$rank" data-project="$projectHtml" data-search="$searchTextHtml" data-sort-file="$fileNameHtml" data-sort-project="$projectHtml" data-sort-added="$($file.Added)" data-sort-deleted="$($file.Deleted)" data-sort-rework="$($file.ReworkLines)" data-sort-rework-percent="$reworkPercentSort" data-sort-churn="$($file.ChurnLines)" data-sort-churn-percent="$churnPercentSort" data-panel="file-$rank" tabindex="0" title="$pathHtml">
  <td class="path"><button type="button">$fileNameHtml</button></td>
  <td class="project">$projectHtml</td>
  <td class="number">$(Format-WholeNumber $file.Added)</td>
  <td class="number">$(Format-WholeNumber $file.Deleted)</td>
  <td class="number">$(Format-Number $file.ReworkPercent)%</td>
  <td class="number">$(Format-Number $file.ChurnPercent)%</td>
</tr>
"@)

    $panels.Add(@"
<article class="diff-panel" id="file-$rank" hidden>
  <header>
    <p class="eyebrow">Hotspot #$rank</p>
    <h2>$pathHtml</h2>
    <p class="file-meta">$projectHtml</p>
    <dl>
      <div><dt>Added</dt><dd>$(Format-WholeNumber $file.Added)</dd></div>
      <div><dt>Deleted</dt><dd>$(Format-WholeNumber $file.Deleted)</dd></div>
      <div><dt>Rework</dt><dd>$(Format-WholeNumber $file.ReworkLines) lines</dd></div>
      <div><dt>Churn</dt><dd>$(Format-WholeNumber $file.ChurnLines) lines</dd></div>
    </dl>
  </header>
  <pre class="diff">$($file.DiffHtml)</pre>
</article>
"@)
}

$emptyState = ""
if ($hotspots.Count -eq 0) {
    $emptyState = "<div class=""empty"">No files met the hotspot rule of at least $MinAdded added lines and at least $MinDeleted deleted lines.</div>"
}

$html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Rework Report</title>
  <style>
    :root {
      --bg: #f4f6f8;
      --panel: #ffffff;
      --ink: #1f2933;
      --muted: #657485;
      --line: #d8dee6;
      --green: #27864f;
      --green-soft: #dff3e8;
      --amber: #b36b00;
      --amber-soft: #fff2d4;
      --red: #b42318;
      --red-soft: #ffe4e0;
      --blue: #245f9f;
      --blue-soft: #e2efff;
      --shadow: 0 10px 28px rgba(15, 23, 42, 0.08);
    }

    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--ink);
      font-family: "Segoe UI", Arial, sans-serif;
      font-size: 14px;
      line-height: 1.45;
    }

    header.hero {
      background: #25313d;
      color: white;
      padding: 24px 32px 22px;
      border-bottom: 5px solid var(--green);
    }

    .hero h1 {
      margin: 0 0 6px;
      font-size: 30px;
      font-weight: 600;
      letter-spacing: 0;
    }

    .hero p {
      margin: 0;
      color: #cfdae5;
    }

    main {
      width: min(1480px, calc(100vw - 32px));
      margin: 24px auto 48px;
    }

    .summary {
      display: grid;
      grid-template-columns: minmax(280px, 1.2fr) repeat(4, minmax(160px, 1fr));
      gap: 14px;
      margin-bottom: 18px;
    }

    .metric, .notice, .table-wrap, .details {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 6px;
      box-shadow: var(--shadow);
    }

    .metric {
      padding: 16px;
      min-width: 0;
    }

    .metric.primary {
      grid-row: span 2;
    }

    .metric .label, .eyebrow {
      margin: 0 0 7px;
      color: var(--muted);
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }

    .metric .value {
      margin: 0;
      font-size: 30px;
      font-weight: 700;
    }

    .metric.primary .value {
      font-size: 52px;
      line-height: 1;
    }

    .meter {
      width: 100%;
      height: 14px;
      margin: 16px 0 10px;
      overflow: hidden;
      border: 1px solid #b9c8b9;
      border-radius: 999px;
      background: #e9eef2;
    }

    .meter span {
      display: block;
      width: $barWidth%;
      height: 100%;
      background: linear-gradient(90deg, #42a66a, var(--green));
    }

    .hint {
      margin: 8px 0 0;
      color: var(--muted);
      font-size: 13px;
    }

    .notice {
      margin-bottom: 18px;
      padding: 14px 18px;
      border-left: 5px solid var(--amber);
      background: var(--amber-soft);
    }

    .notice h2 {
      margin: 0 0 8px;
      font-size: 16px;
    }

    .notice ul {
      margin: 0;
      padding-left: 18px;
    }

    .layout {
      display: grid;
      grid-template-columns: minmax(620px, 1fr) minmax(520px, 1fr);
      gap: 18px;
      align-items: start;
    }

    .table-wrap {
      overflow-x: hidden;
      overflow-y: hidden;
    }

    .toolbar {
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: flex-start;
      gap: 10px;
      padding: 14px 16px;
      border-bottom: 1px solid var(--line);
      background: #fbfcfd;
    }

    .toolbar-title {
      align-self: flex-start;
    }

    .toolbar-controls {
      display: flex;
      flex-wrap: nowrap;
      justify-content: flex-start;
      align-items: center;
      gap: 10px;
      width: 100%;
      min-width: 0;
      overflow-x: auto;
      white-space: nowrap;
    }

    .toolbar label {
      display: inline-flex;
      align-items: center;
      flex: 0 0 auto;
      gap: 8px;
      color: var(--muted);
      font-weight: 600;
    }

    .toolbar input,
    .toolbar select {
      padding: 7px 9px;
      border: 1px solid #b8c2cc;
      border-radius: 4px;
      font: inherit;
    }

    .toolbar input {
      width: 88px;
    }

    .toolbar input[type="search"] {
      width: 150px;
      max-width: 150px;
    }

    .toolbar select {
      width: 145px;
      max-width: 145px;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      table-layout: fixed;
    }

    th, td {
      padding: 9px 8px;
      border-bottom: 1px solid var(--line);
      text-align: right;
      vertical-align: middle;
      white-space: nowrap;
    }

    th {
      position: relative;
      background: #edf1f5;
      color: #334155;
      font-size: 12px;
      font-weight: 700;
      text-transform: uppercase;
    }

    th.sortable {
      padding: 0;
    }

    .sort-button {
      display: flex;
      align-items: center;
      justify-content: flex-end;
      gap: 2px;
      width: 100%;
      min-height: 38px;
      padding: 9px 14px 9px 8px;
      border: 0;
      background: transparent;
      color: inherit;
      cursor: pointer;
      font: inherit;
      font-size: inherit;
      font-weight: inherit;
      letter-spacing: inherit;
      text-align: right;
      text-transform: inherit;
      white-space: nowrap;
    }

    th.path-head .sort-button,
    th.project-head .sort-button {
      justify-content: flex-start;
      text-align: left;
    }

    .sort-button::after {
      content: "";
      display: inline-block;
      width: 8px;
      color: var(--muted);
      font-size: 10px;
    }

    th.sort-asc .sort-button::after {
      content: "^";
    }

    th.sort-desc .sort-button::after {
      content: "v";
    }

    .resize-handle {
      position: absolute;
      top: 0;
      right: -3px;
      z-index: 2;
      width: 7px;
      height: 100%;
      cursor: col-resize;
      touch-action: none;
    }

    .resize-handle::after {
      content: "";
      position: absolute;
      top: 7px;
      right: 3px;
      width: 1px;
      height: calc(100% - 14px);
      background: rgba(51, 65, 85, 0.22);
    }

    th.path-head, td.path, th.project-head, td.project {
      text-align: left;
      white-space: nowrap;
    }

    td.path button {
      display: block;
      width: 100%;
      padding: 0;
      border: 0;
      background: transparent;
      color: var(--blue);
      font: inherit;
      font-weight: 600;
      text-align: left;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
      cursor: pointer;
    }

    td.project {
      color: var(--muted);
      font-weight: 600;
      overflow: hidden;
      text-overflow: ellipsis;
      white-space: nowrap;
    }

    th.number-head, td.number {
      font-variant-numeric: tabular-nums;
    }

    th.number-head {
      font-size: 11px;
    }

    tbody tr {
      cursor: pointer;
    }

    tbody tr:hover, tbody tr.active {
      background: var(--blue-soft);
    }

    .details {
      position: sticky;
      top: 16px;
      max-height: calc(100vh - 32px);
      overflow: auto;
    }

    .details > .placeholder {
      padding: 22px;
      color: var(--muted);
    }

    .diff-panel header {
      padding: 16px 18px;
      border-bottom: 1px solid var(--line);
      background: #fbfcfd;
    }

    .diff-panel h2 {
      margin: 0 0 4px;
      font-size: 18px;
      overflow-wrap: anywhere;
    }

    .file-meta {
      margin: 0 0 12px;
      color: var(--muted);
      font-weight: 600;
    }

    dl {
      display: grid;
      grid-template-columns: repeat(4, minmax(90px, 1fr));
      gap: 8px;
      margin: 0;
    }

    dt {
      color: var(--muted);
      font-size: 12px;
      font-weight: 700;
      text-transform: uppercase;
    }

    dd {
      margin: 2px 0 0;
      font-weight: 700;
    }

    .diff {
      margin: 0;
      padding: 0;
      overflow: auto;
      background: #111827;
      color: #d9e2ec;
      font-family: Consolas, "Courier New", monospace;
      font-size: 12px;
      line-height: 1.2;
      tab-size: 4;
    }

    .diff-line {
      display: grid;
      grid-template-columns: 54px 54px max-content;
      width: max-content;
      min-width: 100%;
      padding: 0 14px 0 0;
    }

    .diff-line + .diff-line {
      margin-top: 3px;
    }

    .diff-line code {
      font: inherit;
      white-space: pre;
    }

    .ln {
      padding: 0 8px;
      color: #93a4b8;
      text-align: right;
      user-select: none;
    }

    .diff-line code {
      padding-left: 12px;
    }

    .diff-line.add { background: rgba(35, 134, 54, 0.23); color: #c9f5d8; }
    .diff-line.del { background: rgba(180, 35, 24, 0.22); color: #ffd4ce; }
    .diff-line.hunk { background: transparent; color: #93a4b8; }
    .diff-line.file { background: transparent; color: #c8d2df; }
    .diff-line.meta { color: #b7c4d3; }

    .empty {
      padding: 24px;
      color: var(--muted);
    }

    @media (max-width: 1180px) {
      .summary, .layout {
        grid-template-columns: 1fr;
      }

      .metric.primary {
        grid-row: auto;
      }

      .details {
        position: static;
        max-height: none;
      }
    }

    @media (max-width: 760px) {
      header.hero {
        padding: 20px;
      }

      main {
        width: min(100vw - 18px, 1480px);
        margin-top: 12px;
      }

      .toolbar {
        align-items: flex-start;
        flex-direction: column;
      }

      .toolbar-controls {
        justify-content: flex-start;
        width: 100%;
      }

      th, td {
        padding: 8px;
        font-size: 12px;
      }

      dl {
        grid-template-columns: repeat(2, minmax(90px, 1fr));
      }
    }
  </style>
</head>
<body>
  <header class="hero">
    <h1>Rework Report</h1>
    <p>$branchLabel at $currentSha compared with $baselineLabel from $Weeks weeks ago at $baselineSha</p>
  </header>

  <main>
    <section class="summary" aria-label="Summary">
      <article class="metric primary">
        <p class="label">Total Rework</p>
        <p class="value">$(Format-Number $repoReworkPercent)%</p>
        <div class="meter" aria-hidden="true"><span></span></div>
        <p class="hint">Rework percentage is replacement lines, min(added, deleted), divided by current comparable production lines.</p>
      </article>
      <article class="metric"><p class="label">Hotspot Files</p><p class="value">$(Format-WholeNumber $hotspots.Count)</p></article>
      <article class="metric"><p class="label">Comparable Files</p><p class="value">$(Format-WholeNumber $commonFiles.Count)</p><p class="hint">Files existing in both revisions, excluding paths containing test.</p></article>
      <article class="metric"><p class="label">Comparable Lines</p><p class="value">$(Format-WholeNumber $allCurrentLines)</p><p class="hint">Current lines in comparable production files.</p></article>
      <article class="metric"><p class="label">Churn</p><p class="value">$(Format-Number $repoChurnPercent)%</p><p class="hint">Added plus deleted hotspot lines divided by comparable lines.</p></article>
      <article class="metric"><p class="label">Added / Deleted</p><p class="value">$(Format-WholeNumber $totalAdded) / $(Format-WholeNumber $totalDeleted)</p><p class="hint">Line changes in hotspot files.</p></article>
      <article class="metric"><p class="label">Whitespace-Ignored Rework</p><p class="value">$(Format-Number $whitespaceIgnoredReworkPercent)%</p><p class="hint">Rework after ignoring whitespace-only changes.</p></article>
      <article class="metric"><p class="label">Generated</p><p class="value">$generatedAt</p><p class="hint">Baseline date: $(HtmlEncode $baselineDate)<br>Current date: $(HtmlEncode $currentDate)</p></article>
      <article class="metric"><p class="label">Rework Share</p><p class="value">$(Format-Number $reworkShareOfChurn)%</p><p class="hint">Replacement lines divided by hotspot churn lines.</p></article>
    </section>

    $warningHtml

    <section class="layout">
      <div class="table-wrap">
        <div class="toolbar">
          <strong class="toolbar-title">Hotspot Files</strong>
          <div class="toolbar-controls">
            <label for="projectFilter">Project <select id="projectFilter">$($projectOptions -join "`n")</select></label>
            <label for="textFilter">Text <input id="textFilter" type="search" placeholder="File, path, project"></label>
            <label for="topN">Show top <input id="topN" type="number" min="1" step="1" value="$defaultTop"></label>
          </div>
        </div>
        $emptyState
        <table aria-label="Hotspot files">
          <colgroup>
            <col data-col="file">
            <col data-col="project">
            <col data-col="added">
            <col data-col="deleted">
            <col data-col="rework-percent">
            <col data-col="churn-percent">
          </colgroup>
          <thead>
            <tr>
              <th class="path-head sortable" data-sort-key="file" data-col="file" aria-sort="none"><button type="button" class="sort-button">File</button><span class="resize-handle" aria-hidden="true"></span></th>
              <th class="project-head sortable" data-sort-key="project" data-col="project" aria-sort="none"><button type="button" class="sort-button">Project</button><span class="resize-handle" aria-hidden="true"></span></th>
              <th class="number-head sortable" data-sort-key="added" data-col="added" aria-sort="none"><button type="button" class="sort-button">Added</button><span class="resize-handle" aria-hidden="true"></span></th>
              <th class="number-head sortable" data-sort-key="deleted" data-col="deleted" aria-sort="none"><button type="button" class="sort-button">Deleted</button><span class="resize-handle" aria-hidden="true"></span></th>
              <th class="number-head sortable" data-sort-key="rework-percent" data-col="rework-percent" aria-sort="none"><button type="button" class="sort-button">Rework %</button><span class="resize-handle" aria-hidden="true"></span></th>
              <th class="number-head sortable" data-sort-key="churn-percent" data-col="churn-percent" aria-sort="none"><button type="button" class="sort-button">Churn %</button></th>
            </tr>
          </thead>
          <tbody>
            $($rows -join "`n")
          </tbody>
        </table>
      </div>

      <aside class="details" aria-live="polite">
        <div class="placeholder">Select a file to inspect the unified diff.</div>
        $($panels -join "`n")
      </aside>
    </section>
  </main>

  <script>
    const topInput = document.getElementById('topN');
    const projectFilter = document.getElementById('projectFilter');
    const textFilter = document.getElementById('textFilter');
    const tableBody = document.querySelector('tbody');
    const table = tableBody.closest('table');
    const tableWrap = table.closest('.table-wrap');
    const sortHeaders = Array.from(document.querySelectorAll('th[data-sort-key]'));
    const columnKeys = ['file', 'project', 'added', 'deleted', 'rework-percent', 'churn-percent'];
    const columns = new Map(Array.from(document.querySelectorAll('col[data-col]')).map(col => [col.dataset.col, col]));
    const minColumnWidths = {
      file: 150,
      project: 90,
      added: 58,
      deleted: 64,
      'rework-percent': 82,
      'churn-percent': 78
    };
    let rows = Array.from(document.querySelectorAll('tbody tr[data-rank]'));
    let sortState = { key: null, direction: 'asc' };
    let userSizedColumns = false;
    const numericSortKeys = new Set(['added', 'deleted', 'rework', 'rework-percent', 'churn', 'churn-percent']);
    const placeholder = document.querySelector('.details .placeholder');
    const panels = Array.from(document.querySelectorAll('.diff-panel'));

    function measureText(text, sampleElement) {
      const canvas = measureText.canvas || (measureText.canvas = document.createElement('canvas'));
      const context = canvas.getContext('2d');
      context.font = getComputedStyle(sampleElement || table).font;
      return Math.ceil(context.measureText(text || '').width);
    }

    function getColumnWidth(key) {
      const col = columns.get(key);
      if (!col) {
        return minColumnWidths[key];
      }

      const explicitWidth = Number.parseFloat(col.style.width);
      if (Number.isFinite(explicitWidth)) {
        return Math.round(explicitWidth);
      }

      return Math.round(col.getBoundingClientRect().width) || minColumnWidths[key];
    }

    function setColumnWidths(widths) {
      let total = 0;
      columnKeys.forEach(key => {
        const width = Math.max(minColumnWidths[key], Math.round(widths[key] || minColumnWidths[key]));
        const col = columns.get(key);
        if (col) {
          col.style.width = width + 'px';
        }
        total += width;
      });
      table.style.width = total + 'px';
      table.style.maxWidth = '100%';
    }

    function measureDesiredColumn(key) {
      const header = document.querySelector('th[data-col="' + key + '"] .sort-button');
      let maxWidth = measureText(header ? header.textContent : key, header) + 32;
      rows.forEach(row => {
        let value = row.getAttribute('data-sort-' + key) || '';
        if (numericSortKeys.has(key)) {
          const index = { added: 2, deleted: 3, 'rework-percent': 4, 'churn-percent': 5 }[key];
          value = row.children[index] ? row.children[index].textContent : value;
        }
        maxWidth = Math.max(maxWidth, measureText(value, row) + 18);
      });
      return Math.max(minColumnWidths[key], maxWidth);
    }

    function autoSizeColumns() {
      const available = Math.max(420, Math.floor(tableWrap.clientWidth));
      const widths = {};
      const nonFileKeys = columnKeys.filter(key => key !== 'file');
      let otherTotal = 0;

      nonFileKeys.forEach(key => {
        widths[key] = measureDesiredColumn(key);
        otherTotal += widths[key];
      });

      const desiredFileWidth = measureDesiredColumn('file');
      widths.file = Math.max(minColumnWidths.file, available - otherTotal);
      if (desiredFileWidth > widths.file && desiredFileWidth + otherTotal <= available) {
        widths.file = desiredFileWidth;
      }

      let total = columnKeys.reduce((sum, key) => sum + widths[key], 0);
      if (total > available) {
        widths.file = Math.max(minColumnWidths.file, widths.file - (total - available));
        total = columnKeys.reduce((sum, key) => sum + widths[key], 0);
      }
      if (total < available) {
        widths.file += available - total;
      }

      setColumnWidths(widths);
    }

    function installColumnResizers() {
      document.querySelectorAll('.resize-handle').forEach(handle => {
        handle.addEventListener('mousedown', event => {
          event.preventDefault();
          event.stopPropagation();

          const header = handle.closest('th[data-col]');
          const key = header.dataset.col;
          const index = columnKeys.indexOf(key);
          const nextKey = columnKeys[index + 1];
          if (!nextKey) {
            return;
          }

          userSizedColumns = true;
          const startX = event.clientX;
          const startWidth = getColumnWidth(key);
          const nextStartWidth = getColumnWidth(nextKey);

          function onMove(moveEvent) {
            const delta = moveEvent.clientX - startX;
            const currentWidth = Math.max(minColumnWidths[key], startWidth + delta);
            const nextWidth = Math.max(minColumnWidths[nextKey], nextStartWidth - (currentWidth - startWidth));
            const appliedDelta = nextStartWidth - nextWidth;
            const widths = {};
            columnKeys.forEach(columnKey => widths[columnKey] = getColumnWidth(columnKey));
            widths[key] = startWidth + appliedDelta;
            widths[nextKey] = nextWidth;
            setColumnWidths(widths);
          }

          function onUp() {
            document.removeEventListener('mousemove', onMove);
            document.removeEventListener('mouseup', onUp);
          }

          document.addEventListener('mousemove', onMove);
          document.addEventListener('mouseup', onUp);
        });
      });
    }

    function updateSortIndicators() {
      sortHeaders.forEach(header => {
        const active = header.dataset.sortKey === sortState.key;
        header.classList.toggle('sort-asc', active && sortState.direction === 'asc');
        header.classList.toggle('sort-desc', active && sortState.direction === 'desc');
        header.setAttribute('aria-sort', active ? (sortState.direction === 'asc' ? 'ascending' : 'descending') : 'none');
      });
    }

    function getSortValue(row, key) {
      if (key === 'rank') {
        return Number.parseInt(row.dataset.rank || '0', 10);
      }

      const value = row.getAttribute('data-sort-' + key) || '';
      if (numericSortKeys.has(key)) {
        return Number.parseFloat(value) || 0;
      }

      return value.toLowerCase();
    }

    function sortRows(key) {
      const isSameKey = sortState.key === key;
      const defaultDirection = numericSortKeys.has(key) ? 'desc' : 'asc';
      const direction = isSameKey ? (sortState.direction === 'asc' ? 'desc' : 'asc') : defaultDirection;
      sortState = { key, direction };

      rows.sort((left, right) => {
        const leftValue = getSortValue(left, key);
        const rightValue = getSortValue(right, key);
        let comparison = 0;

        if (numericSortKeys.has(key) || key === 'rank') {
          comparison = leftValue - rightValue;
        } else {
          comparison = String(leftValue).localeCompare(String(rightValue), undefined, { sensitivity: 'base' });
        }

        return direction === 'asc' ? comparison : -comparison;
      });

      rows.forEach(row => tableBody.appendChild(row));
      updateSortIndicators();
      applyFilters();
    }

    function setActive(row) {
      rows.forEach(item => item.classList.toggle('active', item === row));
      panels.forEach(panel => panel.hidden = true);
      const panel = document.getElementById(row.dataset.panel);
      if (panel) {
        placeholder.hidden = true;
        panel.hidden = false;
      }
    }

    function applyFilters() {
      const limit = Math.max(1, Number.parseInt(topInput.value || '$defaultTop', 10));
      const selectedProject = projectFilter ? projectFilter.value : 'all';
      const text = textFilter ? textFilter.value.trim().toLowerCase() : '';
      let shown = 0;
      rows.forEach(row => {
        const projectMatches = selectedProject === 'all' || row.dataset.project === selectedProject;
        const textMatches = text === '' || (row.dataset.search || '').toLowerCase().includes(text);
        const visible = projectMatches && textMatches && shown < limit;
        row.hidden = !visible;
        if (visible) {
          shown += 1;
        }
      });

      const active = rows.find(row => row.classList.contains('active'));
      if (active && active.hidden) {
        active.classList.remove('active');
        panels.forEach(panel => panel.hidden = true);
        placeholder.hidden = false;
      }
    }

    rows.forEach(row => {
      row.addEventListener('click', () => setActive(row));
      row.addEventListener('keydown', event => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          setActive(row);
        }
      });
    });

    sortHeaders.forEach(header => {
      const button = header.querySelector('button');
      if (button) {
        button.addEventListener('click', () => sortRows(header.dataset.sortKey));
      }
    });

    topInput.addEventListener('input', applyFilters);
    if (textFilter) {
      textFilter.addEventListener('input', () => {
        applyFilters();
        const firstVisible = rows.find(row => !row.hidden);
        if (firstVisible) {
          setActive(firstVisible);
        }
      });
    }
    if (projectFilter) {
      projectFilter.addEventListener('change', () => {
        applyFilters();
        const firstVisible = rows.find(row => !row.hidden);
        if (firstVisible) {
          setActive(firstVisible);
        }
      });
    }
    installColumnResizers();
    autoSizeColumns();
    window.addEventListener('resize', () => {
      if (!userSizedColumns) {
        autoSizeColumns();
      }
    });
    updateSortIndicators();
    applyFilters();
    const firstVisible = rows.find(row => !row.hidden);
    if (firstVisible) {
      setActive(firstVisible);
    }
  </script>
</body>
</html>
"@

$encoding = New-Object System.Text.UTF8Encoding $false
Write-Step "Writing report HTML to $fullOutputPath."
[System.IO.File]::WriteAllText($fullOutputPath, $html, $encoding)

Write-Step "Done."
Write-Host ""
Write-Host "Rework report generated: $fullOutputPath"
Write-Host "Current:  $CurrentRef ($currentSha)"
Write-Host "Baseline: $($baselineSource.Ref) ($baselineSha)"
Write-Host "Scanned:  $($commonFiles.Count) comparable files"
Write-Host "Hotspots: $($hotspots.Count)"
Write-Host "Rework:   $(Format-Number $repoReworkPercent)%"
Write-Host "Rework -w: $(Format-Number $whitespaceIgnoredReworkPercent)%"
Write-Host "Share:    $(Format-Number $reworkShareOfChurn)% of hotspot churn"

if ($script:LocationPushed) {
    Pop-Location
    $script:LocationPushed = $false
}
