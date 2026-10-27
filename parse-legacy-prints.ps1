<#
    parse-legacy-prints.ps1 - turns legacy Paywell's exported print spool (the
    <program>_<spool>_<yyyymmdd>_<hhmm>.CSV files written by the spool export)
    into two tables we can diff against pipro's own run outputs. READ-ONLY on the
    print folders; writes only to reports\ (gitignored - the prints name real
    employees).

    Usage:
      powershell -ExecutionPolicy Bypass -File parse-legacy-prints.ps1 -TenantSlug tau -PrintRoot C:\Paywell\tau_run_period_7
      powershell -ExecutionPolicy Bypass -File parse-legacy-prints.ps1 -TenantSlug tau   (default C:\Paywell\Print)

    One folder per CURRENT manifest row: <PrintRoot>\<source_db> (any case),
    holding one run's outputs: the spooled report exports, plus whatever else the
    run wrote - bank transfer files under "Bank Files\", GL extracts (GL_PWnn),
    interface files. Those are read too where a reader exists (bank, GL), and
    listed in the summary otherwise; an empty one is flagged.
    Not compared: PAY042 (program log, spooled only so it can be cleared) and
    PAY032 (audit listing, being redesigned).

    Every exported row is one printed section: fields 0-21 are the page header
    (program, release, licence, PAGE n, PAYROLL n, title, TIME, RUN-NO n, FILE,
    PERIOD n, SYSTEM-DATE, PERIOD-DATE, ADJ n), then the section's own fields,
    then "END OF REPORT <program>". Two body shapes occur:
      - label/value fields (PAY007, 045, 069, 098): one print item per field;
      - print-line text (PAY121, 182, 212): one fixed-width printed line per field.
    Legacy prints negatives with a leading minus in field reports and a TRAILING
    minus in print-line reports; both come out here as a leading minus.

    Output (reports\):
      <tenant>-prints-cells.csv   every body field of every row, separator rules
                                  dropped - the raw material, for any report
      <tenant>-prints-facts.csv   what the per-report interpreters understood:
                                  section / key / code / label / column / value
      <tenant>-prints-summary.txt one line per file: rows read, facts found
    A spooled report with no interpreter appears in cells only. PAY212 report-writer prints carry no column headings in the export, so
    their list columns are numbered col1..colN by print position; the headings
    live in the report definition (PW_Parm_GRW / settings_report*).
#>
param(
    [Parameter(Mandatory = $true)][string]$TenantSlug,
    [string]$PrintRoot = 'C:\Paywell\Print',
    [string]$ManifestPath
)
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\load-manifest.ps1"
Add-Type -AssemblyName Microsoft.VisualBasic

$rows = if ($ManifestPath) { Import-PiproManifest -Path $ManifestPath -TenantSlug $TenantSlug }
        else               { Import-PiproManifest -TenantSlug $TenantSlug }
$current = @($rows | Where-Object { $_.role -eq 'current' })

$reportDir = Join-Path $PSScriptRoot 'reports'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

# ---------------------------------------------------------------- helpers ---

function Q([string]$s) { '"' + ($s -replace '"', '""') + '"' }

# An AMOUNT has decimals (legacy prints every amount with them); a COUNT is a
# bare integer. Kept apart so a pay point "004" or cost code "17294" next to a
# label is never read as money. Returns the normalised text, or $null.
function ConvertTo-Amount([string]$s) {
    $t = $s.Trim()
    if ($t -match '^(-?)(\d+\.\d+)(-?)$') {
        if ($Matches[1] -or $Matches[3]) { return "-$($Matches[2])" }
        return $Matches[2]
    }
    return $null
}
function ConvertTo-Number([string]$s) {
    $a = ConvertTo-Amount $s
    if ($null -ne $a) { return $a }
    $t = $s.Trim()
    if ($t -match '^-?\d+$') { return $t }
    return $null
}
# A separator rule: dashes only, possibly several underlining columns.
function Test-Rule([string]$s) { $s -match '^[-\s]*$' }

$facts = New-Object System.Collections.Generic.List[string]
$cells = New-Object System.Collections.Generic.List[string]
$summary = New-Object System.Collections.Generic.List[string]
$facts.Add('payroll,source_db,file,program,spool,title,run_no,period,period_date,row,section,key,code,label,column,value')
$cells.Add('payroll,source_db,file,program,spool,row,field,text')

# Set per file; Add-Fact reads them.
$script:ctx = $null
$script:row = 0
$script:fileFacts = 0
function Add-Fact([string]$section, [string]$key, [string]$code, [string]$label, [string]$column, [string]$value) {
    $c = $script:ctx
    $facts.Add((@($c.payroll, $c.source_db, $c.file, $c.program, $c.spool, $c.title, $c.run_no, $c.period,
                  $c.period_date, $script:row, $section, $key, $code, $label.Trim(), $column, $value) |
                ForEach-Object { Q ([string]$_) }) -join ',')
    $script:fileFacts++
}

# ----------------------------------------------------------- interpreters ---
# Each takes one row: $raw = body fields (header and END OF REPORT removed),
# $clean = the same without blanks and separator rules, trimmed.

# PAY007 payroll register: one row per employee, amounts as label/code/amount.
function Read-Pay007($raw, $clean) {
    $i = [array]::IndexOf($clean, 'EMPLOYEE NO.')
    $key = if ($i -ge 0) { $clean[$i + 1] } else { 'totals' }
    for ($k = [Math]::Max(0, $i + 2); $k + 2 -lt $clean.Count; $k++) {
        $amount = ConvertTo-Amount $clean[$k + 2]
        if ($clean[$k + 1] -match '^\d+$' -and $null -ne $amount -and $null -eq (ConvertTo-Number $clean[$k])) {
            Add-Fact 'amount' $key $clean[$k + 1] $clean[$k] 'amount' $amount
            $k += 2
        }
    }
}

# PAY045 payment-method analysis: one row per method, 8 figures at the end.
function Read-Pay045($raw, $clean) {
    $cols = 'current_value','current_paid','current_zero_neg','discharged_value','discharged_paid',
            'discharged_zero_neg','total_value','total_count'
    if ($clean.Count -lt 9) { return }
    $tail = $clean[($clean.Count - 9)..($clean.Count - 1)]
    for ($j = 0; $j -lt 8; $j++) {
        $v = ConvertTo-Number $tail[$j + 1]
        if ($null -eq $v) { return }
    }
    for ($j = 0; $j -lt 8; $j++) { Add-Fact 'method' $tail[0] '' $tail[0] $cols[$j] (ConvertTo-Number $tail[$j + 1]) }
}

# PAY069 tax/SDL/UIF/ETI: one row per pay point; a figure belongs to the label
# printed before it, under the last ALL-CAPS heading.
function Read-Pay069($raw, $clean) {
    $p = [array]::IndexOf($clean, 'Pay point')
    $key = if ($p -ge 0) { $clean[$p + 1] } else { '' }
    $section = ''
    for ($k = 0; $k -lt $clean.Count; $k++) {
        if ($k -eq $p -or $k -eq $p + 1) { continue }
        $c = $clean[$k]
        $v = ConvertTo-Number $c
        if ($null -ne $v) {
            if ($k -gt 0 -and $null -eq (ConvertTo-Number $clean[$k - 1])) {
                # "Levy payable = 322509.40 x 0.01" -> "Levy payable"
                Add-Fact $section $key '' ($clean[$k - 1] -replace '\s*=.*$', '') 'value' $v
            }
        } elseif (($c -cmatch '[A-Z]' -and $c -cnotmatch '[a-z]') -or
                  ($k + 1 -lt $clean.Count -and $null -eq (ConvertTo-Number $clean[$k + 1]) -and
                   $c.Length -lt 40 -and $c -notmatch '[.:,!]$')) {
            # ALL-CAPS, or a short phrase with no figure of its own
            # ("Employee Tax Incentive (ETI)"); notes end in punctuation.
            $section = $c
        }
    }
}

# PAY098 master/run file amount totals: code, interpretation, amount at the end.
function Read-Pay098($raw, $clean) {
    if ($clean.Count -lt 3) { return }
    $code, $label, $amt = $clean[($clean.Count - 3)..($clean.Count - 1)]
    $amount = ConvertTo-Amount $amt
    if ($code -match '^\d+$' -and $null -ne $amount) { Add-Fact 'total' '' $code $label 'amount' $amount }
}

# PAY121 payroll control: print lines - run settings ("Label   value") and
# code lines holding two "nnn interpretation calculated manual total" entries.
function Read-Pay121($raw, $clean) {
    foreach ($line in $clean) {
        if ($line -match 'Interpretation\s+Calculated') { continue }
        # The interpretation is a fixed 15 characters and may itself hold figures
        # ("O/T 1.3"), so it is cut by width, not by spacing.
        $m = [regex]::Matches($line, '(\d{3}) (.{15})\s*(\S+)\s+(\S+)\s+(\S+)')
        $hit = $false
        foreach ($x in $m) {
            $vals = @(3, 4, 5 | ForEach-Object { ConvertTo-Amount $x.Groups[$_].Value })
            if ($vals -contains $null) { continue }
            $hit = $true
            Add-Fact 'amount' '' $x.Groups[1].Value $x.Groups[2].Value 'calculated' $vals[0]
            Add-Fact 'amount' '' $x.Groups[1].Value $x.Groups[2].Value 'manual'     $vals[1]
            Add-Fact 'amount' '' $x.Groups[1].Value $x.Groups[2].Value 'total'      $vals[2]
        }
        if ($hit) { continue }
        # Run messages print against an employee ("605 <name> *** CONTRACT ENDS ...").
        if ($line -match '^\s*(\d+)\s+(\S.*?)\s*$') {
            Add-Fact 'message' $Matches[1] '' ($Matches[2] -replace '\s{2,}', '  ') 'text' ''
        } elseif ($line -match '^\s*(.+?)\s{2,}(\S.*?)\s*$') {
            $v = ConvertTo-Number $Matches[2]
            Add-Fact 'setting' '' '' $Matches[1] 'value' $(if ($null -ne $v) { $v } else { $Matches[2] })
        }
    }
}

# PAY182 bank transfer control: error lines, then "Label: value" totals.
function Read-Pay182($raw, $clean) {
    foreach ($line in $clean) {
        if ($line -match 'Error Message' -or $line -eq 'Control Totals') { continue }
        if ($line -match '^(.+?):\s*(\S+)$') {
            $v = ConvertTo-Number $Matches[2]
            Add-Fact 'control' '' '' $Matches[1] 'value' $(if ($null -ne $v) { $v } else { $Matches[2] })
        } else {
            Add-Fact 'error' '' '' $line 'text' $line
        }
    }
}

# PAY212 report writer: one printed line per row, so the whole FILE is read
# before interpreting - list columns are found by where their figures end.
#   journal layout (a line starts "EMPLOYEE NO.", "COST CODE" or "FINAL TOTALS"): the key area
#     on the left, then label / figure / figure entries;
#   list layout: employee number first, then figures in fixed columns.
function Read-Pay212File($lines) {
    $numRe = '(?<!\S)-?\d+\.\d+-?(?!\S)'
    $keyRe = '^(\s*(?:(EMPLOYEE NO\.|COST CODE)\s+(\S+)|(FINAL TOTALS))\s+)'
    # A journal keys its blocks on EMPLOYEE NO. / COST CODE lines followed by a
    # label, or (a summary journal) has no employee lines at all. A list is one
    # employee per line, starting with the employee number; its COST CODE /
    # COST CENTRE / FINAL TOTALS subtotal lines go straight to figures.
    $hasKeyLines = $null -ne ($lines | Where-Object { $_.text -match '^\s*(EMPLOYEE NO\.|COST CODE)\s+\S+\s+[A-Za-z*]' } | Select-Object -First 1)
    $hasEmpLines = $null -ne ($lines | Where-Object { $_.text -match "^\s*\d+\s.*$numRe" } | Select-Object -First 1)
    $journal = $hasKeyLines -or -not $hasEmpLines

    if ($journal) {
        $first = ($lines | Where-Object { $_.text -match $keyRe } | Select-Object -First 1).text
        $null = $first -match $keyRe
        $keyWidth = $Matches[1].Length
        $key = ''
        foreach ($l in $lines) {
            $script:row = $l.row
            $t = $l.text
            if ($t -match $keyRe) {
                $key = if ($Matches[4]) { 'final' }
                       elseif ($Matches[2] -eq 'COST CODE') { "cost:$($Matches[3])" }
                       else { "emp:$($Matches[3])" }
            }
            if ($t.Length -le $keyWidth) { continue }
            $label = ''
            $col = 0
            foreach ($tok in ($t.Substring($keyWidth) -split '\s{2,}' | Where-Object { $_ })) {
                $v = ConvertTo-Amount $tok
                if ($null -eq $v) { $label = $tok; $col = 0; continue }
                $col++
                Add-Fact 'journal' $key '' $label "col$col" $v
            }
        }
        return
    }

    # List layout. Right-aligned figures in one column end at the same position
    # - their last DIGIT does; a trailing minus overhangs the column.
    function Get-End($x) { $x.Index + $x.Length - $(if ($x.Value.EndsWith('-')) { 1 } else { 0 }) }
    $ends = @($lines | ForEach-Object { [regex]::Matches($_.text, $numRe) } |
              ForEach-Object { Get-End $_ } | Sort-Object -Unique)
    foreach ($l in $lines) {
        $script:row = $l.row
        $m = [regex]::Matches($l.text, $numRe)
        if ($m.Count -eq 0) { continue }
        $lead = $l.text.Substring(0, $m[0].Index).Trim()
        # A line with no leading text is usually a column total under a rule.
        $key = if ($lead -match '^(\d+)\s') { $Matches[1] } elseif ($lead) { $lead -replace '\s{2,}', ' ' } else { '(unlabelled)' }
        foreach ($x in $m) {
            $ord = [array]::IndexOf($ends, (Get-End $x)) + 1
            Add-Fact 'list' $key '' '' "col$ord" (ConvertTo-Amount $x.Value)
        }
    }
}

# Bank transfer file (Pay182's output, under "Bank Files\"): a few header lines,
# a column-heading line starting RECIPIENT NAME, then one line per transfer.
# The header lines' meaning is the bank's, so they are kept by position.
function Read-BankFile([string]$path) {
    $lines = @(Get-Content $path -Encoding Default)
    $h = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^RECIPIENT NAME,') { $h = $i; break } }
    if ($h -lt 0) { return $false }
    for ($i = 0; $i -lt $h; $i++) {
        $script:row = $i + 1
        $n = 0
        foreach ($v in ($lines[$i] -split ',')) {
            $n++
            if ($v.Trim()) { Add-Fact 'header' '' '' "line$($i + 1)" "field$n" $v.Trim() }
        }
    }
    $cols = @($lines[$h] -split ',' | ForEach-Object { $_.Trim().ToLower() -replace '\s+', '_' })
    $ref = [array]::IndexOf($cols, 'own_reference')
    $amt = [array]::IndexOf($cols, 'amount')
    $count = 0
    $sum = [decimal]0
    for ($i = $h + 1; $i -lt $lines.Count; $i++) {
        $script:row = $i + 1
        $v = $lines[$i] -split ','
        if (-not $v[0].Trim()) { continue }
        $count++
        $key = if ($ref -ge 0) { $v[$ref].Trim() } else { "$count" }
        for ($j = 1; $j -lt [Math]::Min($v.Count, $cols.Count); $j++) {
            if (-not $v[$j].Trim() -or $j -eq $ref) { continue }
            $val = if ($j -eq $amt) { ConvertTo-Amount $v[$j] } else { $v[$j].Trim() }
            Add-Fact 'transfer' $key '' '' $cols[$j] $val
        }
        if ($amt -ge 0) { $sum += [decimal](ConvertTo-Amount $v[$amt]) }
    }
    # Same labels as Pay182's control totals, so the two can be laid side by side.
    Add-Fact 'control' '' '' 'Total Number of transfers' 'value' "$count"
    Add-Fact 'control' '' '' 'Total Amount of transfers' 'value' $sum.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
    return $true
}

# GL extract ("GL_PWnn"): "cost code","account",amount with a trailing minus
# for credits. Lines carrying only a cost code are counted, not kept.
function Read-GlFile([string]$path) {
    $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($path, [Text.Encoding]::Default)
    $parser.SetDelimiters(',')
    $parser.HasFieldsEnclosedInQuotes = $true
    $script:glBlank = 0
    $i = 0
    try {
        while (-not $parser.EndOfData) {
            $v = $parser.ReadFields()
            $i++
            $script:row = $i
            if ($v.Count -lt 3) { $script:glBlank++; continue }
            Add-Fact 'gl' $v[0].Trim() '' $v[1] 'amount' (ConvertTo-Amount $v[2])
        }
    } finally { $parser.Close() }
}

$perRow = @{ 7 = 'Read-Pay007'; 45 = 'Read-Pay045'; 69 = 'Read-Pay069'; 98 = 'Read-Pay098';
             121 = 'Read-Pay121'; 182 = 'Read-Pay182' }
# Spooled, but not run outputs anyone compares: the LOGF is spooled for its
# "clear after printing" option, and the audit is being redesigned.
$notCompared = @{ 32 = 'audit file listing'; 42 = 'program log (LOGF)' }

# ------------------------------------------------------------------- main ---

foreach ($r in $current) {
    $dir = Join-Path $PrintRoot $r.source_db
    if (-not (Test-Path $dir)) {
        Write-Host "==> payroll $($r.legacy_payroll_number): no print folder $dir - skipped" -ForegroundColor Yellow
        $summary.Add("payroll $($r.legacy_payroll_number) $($r.source_db): no folder $dir")
        continue
    }
    $spoolRe = '^(\d+)_(\d+)_\d{8}_\d{4}\.csv$'
    $all = @(Get-ChildItem $dir -File -Recurse)
    $files = @($all | Where-Object { $_.Name -match $spoolRe } | Sort-Object { [int](($_.Name -split '_')[0]) }, Name)
    $others = @($all | Where-Object { $_.Name -notmatch $spoolRe -and $_.Extension -ne '.rpt' } | Sort-Object FullName)
    Write-Host "==> payroll $($r.legacy_payroll_number) ($($r.source_db)): $($files.Count) spooled report(s), $($others.Count) other file(s)" -ForegroundColor Cyan

    foreach ($f in $files) {
        $null = $f.Name -match $spoolRe
        $progNo = [int]$Matches[1]
        $spool = $Matches[2]
        if ($notCompared.ContainsKey($progNo)) {
            $line = "payroll {0} {1,-28} not compared: {2}" -f $r.legacy_payroll_number, $f.Name, $notCompared[$progNo]
            $summary.Add($line)
            Write-Host "    $line"
            continue
        }

        $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($f.FullName, [Text.Encoding]::Default)
        $parser.SetDelimiters(',')
        $parser.HasFieldsEnclosedInQuotes = $true
        # Print lines are fixed-width: leading spaces ARE the column positions.
        $parser.TrimWhiteSpace = $false
        $records = New-Object System.Collections.Generic.List[object]
        try { while (-not $parser.EndOfData) { $records.Add($parser.ReadFields()) } }
        finally { $parser.Close() }
        if ($records.Count -eq 0) { $summary.Add("payroll $($r.legacy_payroll_number) $($f.Name): empty"); continue }

        $h = $records[0]
        $headerOk = $h.Count -gt 22 -and $h[3] -eq 'PAGE' -and $h[5] -eq 'PAYROLL' -and $h[10] -eq 'RUN-NO' -and
                    $h[14] -eq 'PERIOD' -and $h[18] -eq 'PERIOD-DATE'
        $script:ctx = [pscustomobject]@{
            payroll = $r.legacy_payroll_number; source_db = $r.source_db; file = $f.Name
            program = $(if ($headerOk) { $h[0].TrimEnd('/') } else { "PAY{0:000}" -f $progNo }); spool = $spool
            title = $(if ($headerOk) { ($h[7] -replace '^\*+\s*|\s*\*+$', '').Trim() } else { '' })
            run_no = $(if ($headerOk) { $h[11] } else { '' }); period = $(if ($headerOk) { $h[15] } else { '' })
            period_date = $(if ($headerOk) { $h[19] } else { '' })
        }
        if ($headerOk -and $h[6] -ne $r.legacy_payroll_number) {
            Write-Host "    $($f.Name): prints PAYROLL $($h[6]), manifest says $($r.legacy_payroll_number)" -ForegroundColor Yellow
        }
        $script:fileFacts = 0
        $grwLines = New-Object System.Collections.Generic.List[object]

        for ($i = 0; $i -lt $records.Count; $i++) {
            $script:row = $i + 1
            $rec = $records[$i]
            $start = if ($headerOk) { 22 } else { 0 }
            $end = $rec.Count - 1
            if ($end -ge $start -and $rec[$end] -match '^END OF REPORT') { $end-- }
            $raw = if ($end -ge $start) { [string[]]$rec[$start..$end] } else { [string[]]@() }
            for ($j = 0; $j -lt $raw.Count; $j++) {
                if ($raw[$j].Trim().Length -gt 0 -and -not (Test-Rule $raw[$j])) {
                    $cells.Add((@($ctx.payroll, $ctx.source_db, $ctx.file, $ctx.program, $spool, $script:row,
                                  ($start + $j), $raw[$j].TrimEnd()) | ForEach-Object { Q ([string]$_) }) -join ',')
                }
            }
            $clean = [string[]]@($raw | Where-Object { $_.Trim().Length -gt 0 -and -not (Test-Rule $_) } |
                                 ForEach-Object { $_.Trim() })
            if ($progNo -eq 212) {
                $text = ($raw | Where-Object { $_.Trim().Length -gt 0 -and -not (Test-Rule $_) }) -join ' '
                if ($text.Trim()) { $grwLines.Add([pscustomobject]@{ row = $script:row; text = $text.TrimEnd() }) }
            } elseif ($perRow.ContainsKey($progNo)) {
                & $perRow[$progNo] $raw $clean
            }
        }
        if ($progNo -eq 212 -and $grwLines.Count -gt 0) { Read-Pay212File $grwLines }

        $how = if ($progNo -eq 212 -or $perRow.ContainsKey($progNo)) { "$($script:fileFacts) facts" } else { 'cells only (no interpreter)' }
        $line = "payroll {0} {1,-28} {2,-7} {3,-48} rows {4,5}  {5}" -f $r.legacy_payroll_number, $f.Name,
                $ctx.program, $ctx.title, $records.Count, $how
        $summary.Add($line)
        Write-Host "    $line"
    }

    # Files the run wrote that are not spooled prints: bank transfer files, GL
    # extracts, interface files. An EMPTY one is reported loudly - an interface
    # that wrote nothing is a failed output, not an absent one.
    foreach ($f in $others) {
        $rel = $f.FullName.Substring($dir.TrimEnd('\').Length + 1)
        $script:ctx = [pscustomobject]@{
            payroll = $r.legacy_payroll_number; source_db = $r.source_db; file = $rel
            program = ''; spool = ''; title = $f.Name; run_no = ''; period = ''; period_date = ''
        }
        $script:fileFacts = 0
        if ($f.Length -eq 0) {
            $how = 'EMPTY FILE'
        } elseif ($f.Directory.Name -eq 'Bank Files') {
            $ctx.program = 'BANKFILE'
            $how = if (Read-BankFile $f.FullName) { "$($script:fileFacts) facts" } else { 'no RECIPIENT NAME heading - not read' }
        } elseif ($f.Name -match '^GL_') {
            $ctx.program = 'GL'
            Read-GlFile $f.FullName
            $how = "$($script:fileFacts) facts" + $(if ($script:glBlank) { ", $($script:glBlank) line(s) with only a cost code" } else { '' })
        } else {
            $how = 'not interpreted'
        }
        $line = "payroll {0} {1,-40} {2,-8} {3,8} bytes  {4}" -f $r.legacy_payroll_number, $rel, $ctx.program, $f.Length, $how
        $summary.Add($line)
        Write-Host "    $line" -ForegroundColor $(if ($how -eq 'EMPTY FILE') { 'Yellow' } else { 'Gray' })
    }
}

$factsPath   = Join-Path $reportDir "$TenantSlug-prints-facts.csv"
$cellsPath   = Join-Path $reportDir "$TenantSlug-prints-cells.csv"
$summaryPath = Join-Path $reportDir "$TenantSlug-prints-summary.txt"
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllLines($factsPath, $facts, $utf8)
[IO.File]::WriteAllLines($cellsPath, $cells, $utf8)
[IO.File]::WriteAllLines($summaryPath, $summary, $utf8)
Write-Host ""
Write-Host "==> $($facts.Count - 1) facts  -> $factsPath" -ForegroundColor Green
Write-Host "==> $($cells.Count - 1) cells  -> $cellsPath" -ForegroundColor Green
Write-Host "==> summary  -> $summaryPath" -ForegroundColor Green
